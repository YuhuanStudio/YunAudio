#include "YunAudioIncidentTelemetry.h"

#include <limits.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(
    ATOMIC_LONG_LOCK_FREE == 2 && ATOMIC_LLONG_LOCK_FREE == 2,
    "incident telemetry requires lock-free 64-bit callback atomics");

struct YunRTIncidentCallbackTelemetry {
    _Atomic uint64_t buckets[kYunRTIncidentBucketCount];
    _Atomic uint64_t samples;
    _Atomic uint64_t overflowSamples;
    _Atomic uint64_t missedDeadlines;
    _Atomic uint64_t callbackOverlaps;
    _Atomic uint64_t allocationViolations;
    _Atomic uint64_t maximumNanoseconds;
    _Atomic uint64_t maximumUpdateContentions;
    _Atomic uint64_t deadlineNanoseconds;
    _Atomic uint64_t graphGenerations;
};

static void RecordConservativeMaximum(
    YunRTIncidentCallbackTelemetry *telemetry,
    uint64_t elapsedNanoseconds) {
    uint64_t observed = atomic_load_explicit(
        &telemetry->maximumNanoseconds, memory_order_relaxed);
    for (unsigned attempt = 0; attempt < 8; ++attempt) {
        if (elapsedNanoseconds <= observed) return;
        if (atomic_compare_exchange_weak_explicit(
                &telemetry->maximumNanoseconds,
                &observed,
                elapsedNanoseconds,
                memory_order_relaxed,
                memory_order_relaxed)) {
            return;
        }
    }

    // Eight contending writers are already a contract failure. Saturating is
    // conservative: an incident may look worse, but it can never be hidden by
    // under-reporting a maximum which lost the bounded compare/exchange race.
    atomic_store_explicit(
        &telemetry->maximumNanoseconds, UINT64_MAX, memory_order_relaxed);
    atomic_fetch_add_explicit(
        &telemetry->maximumUpdateContentions, 1, memory_order_relaxed);
}

static void RecordDeadline(
    YunRTIncidentCallbackTelemetry *telemetry,
    uint64_t deadlineNanoseconds) {
    if (deadlineNanoseconds == 0) return;
    uint64_t observed = atomic_load_explicit(
        &telemetry->deadlineNanoseconds, memory_order_relaxed);
    if (observed == UINT64_MAX || observed == deadlineNanoseconds) return;
    if (observed == 0) {
        if (atomic_compare_exchange_strong_explicit(
                &telemetry->deadlineNanoseconds,
                &observed,
                deadlineNanoseconds,
                memory_order_relaxed,
                memory_order_relaxed)) {
            return;
        }
        if (observed == deadlineNanoseconds) return;
    }

    // A route whose deadline changed cannot be graded against one convenient
    // denominator. UINT64_MAX is the fixed unknown marker and therefore makes
    // the resulting bundle indeterminate rather than optimistic.
    atomic_store_explicit(
        &telemetry->deadlineNanoseconds, UINT64_MAX, memory_order_relaxed);
}

static uint64_t QuantileUpperBound(
    const uint64_t *buckets,
    uint64_t overflowSamples,
    uint64_t maximumNanoseconds,
    uint64_t numerator,
    uint64_t denominator) {
    uint64_t total = overflowSamples;
    for (unsigned index = 0; index < kYunRTIncidentBucketCount; ++index) {
        if (UINT64_MAX - total < buckets[index]) {
            total = UINT64_MAX;
            break;
        }
        total += buckets[index];
    }
    if (total == 0) return 0;

    __uint128_t scaled = (__uint128_t)total * numerator;
    uint64_t target = (uint64_t)((scaled + denominator - 1) / denominator);
    uint64_t cumulative = 0;
    for (unsigned index = 0; index < kYunRTIncidentBucketCount; ++index) {
        if (UINT64_MAX - cumulative < buckets[index]) {
            cumulative = UINT64_MAX;
        } else {
            cumulative += buckets[index];
        }
        if (cumulative >= target) {
            uint64_t bucketUpperBound =
                ((uint64_t)index + 1) * kYunRTIncidentBucketWidthNanoseconds - 1;
            return bucketUpperBound < maximumNanoseconds
                ? bucketUpperBound
                : maximumNanoseconds;
        }
    }

    // The requested quantile landed in overflow. The exact maximum is a safe
    // upper bound; UINT64_MAX means bounded max publication saw heavy overlap.
    return maximumNanoseconds;
}

YunRTIncidentCallbackTelemetry *yun_rt_incident_callback_create(void) {
    YunRTIncidentCallbackTelemetry *telemetry =
        malloc(sizeof(YunRTIncidentCallbackTelemetry));
    if (telemetry == NULL) return NULL;
    for (unsigned index = 0; index < kYunRTIncidentBucketCount; ++index) {
        atomic_init(&telemetry->buckets[index], 0);
    }
    atomic_init(&telemetry->samples, 0);
    atomic_init(&telemetry->overflowSamples, 0);
    atomic_init(&telemetry->missedDeadlines, 0);
    atomic_init(&telemetry->callbackOverlaps, 0);
    atomic_init(&telemetry->allocationViolations, 0);
    atomic_init(&telemetry->maximumNanoseconds, 0);
    atomic_init(&telemetry->maximumUpdateContentions, 0);
    atomic_init(&telemetry->deadlineNanoseconds, 0);
    atomic_init(&telemetry->graphGenerations, 1);
    return telemetry;
}

void yun_rt_incident_callback_free(YunRTIncidentCallbackTelemetry *telemetry) {
    free(telemetry);
}

void yun_rt_incident_callback_observe(
    YunRTIncidentCallbackTelemetry *telemetry,
    uint64_t elapsedNanoseconds,
    uint64_t deadlineNanoseconds,
    uint64_t allocationViolations) {
    if (telemetry == NULL) return;

    const uint64_t coveredNanoseconds =
        (uint64_t)kYunRTIncidentBucketCount * kYunRTIncidentBucketWidthNanoseconds;
    if (elapsedNanoseconds >= coveredNanoseconds) {
        atomic_fetch_add_explicit(
            &telemetry->overflowSamples, 1, memory_order_relaxed);
    } else {
        uint64_t index = elapsedNanoseconds / kYunRTIncidentBucketWidthNanoseconds;
        atomic_fetch_add_explicit(
            &telemetry->buckets[index], 1, memory_order_relaxed);
    }
    if (deadlineNanoseconds > 0 && elapsedNanoseconds > deadlineNanoseconds) {
        atomic_fetch_add_explicit(
            &telemetry->missedDeadlines, 1, memory_order_relaxed);
    }
    if (allocationViolations > 0) {
        atomic_fetch_add_explicit(
            &telemetry->allocationViolations,
            allocationViolations,
            memory_order_relaxed);
    }
    RecordDeadline(telemetry, deadlineNanoseconds);
    RecordConservativeMaximum(telemetry, elapsedNanoseconds);

    // This commit comes last. A post-fence snapshot can therefore reject a
    // partial writer by comparing the distribution total with this count.
    atomic_fetch_add_explicit(&telemetry->samples, 1, memory_order_release);
}

void yun_rt_incident_callback_refuse_overlap(
    YunRTIncidentCallbackTelemetry *telemetry,
    uint64_t allocationViolations) {
    if (telemetry == NULL) return;
    atomic_fetch_add_explicit(
        &telemetry->callbackOverlaps, 1, memory_order_relaxed);
    if (allocationViolations > 0) {
        atomic_fetch_add_explicit(
            &telemetry->allocationViolations,
            allocationViolations,
            memory_order_relaxed);
    }
}

void yun_rt_incident_graph_published(
    YunRTIncidentCallbackTelemetry *telemetry) {
    if (telemetry == NULL) return;
    uint64_t generation = atomic_load_explicit(
        &telemetry->graphGenerations, memory_order_relaxed);
    while (generation != UINT64_MAX &&
           !atomic_compare_exchange_weak_explicit(
               &telemetry->graphGenerations,
               &generation,
               generation + 1,
               memory_order_relaxed,
               memory_order_relaxed)) {}
}

uint64_t yun_rt_incident_graph_generations(
    const YunRTIncidentCallbackTelemetry *telemetry) {
    if (telemetry == NULL) return 0;
    return atomic_load_explicit(
        &telemetry->graphGenerations, memory_order_acquire);
}

void yun_rt_incident_callback_snapshot(
    const YunRTIncidentCallbackTelemetry *telemetry,
    bool callbacksAreFenced,
    YunRTIncidentCallbackSnapshot *outSnapshot) {
    if (outSnapshot == NULL) return;
    memset(outSnapshot, 0, sizeof(*outSnapshot));
    if (telemetry == NULL) return;

    uint64_t buckets[kYunRTIncidentBucketCount];
    uint64_t distributionSamples = 0;
    for (unsigned index = 0; index < kYunRTIncidentBucketCount; ++index) {
        buckets[index] = atomic_load_explicit(
            &telemetry->buckets[index], memory_order_acquire);
        if (UINT64_MAX - distributionSamples < buckets[index]) {
            distributionSamples = UINT64_MAX;
        } else {
            distributionSamples += buckets[index];
        }
    }

    uint64_t overflowSamples = atomic_load_explicit(
        &telemetry->overflowSamples, memory_order_acquire);
    if (UINT64_MAX - distributionSamples < overflowSamples) {
        distributionSamples = UINT64_MAX;
    } else {
        distributionSamples += overflowSamples;
    }
    uint64_t maximumNanoseconds = atomic_load_explicit(
        &telemetry->maximumNanoseconds, memory_order_acquire);
    uint64_t committedSamples = atomic_load_explicit(
        &telemetry->samples, memory_order_acquire);

    outSnapshot->samples = committedSamples;
    outSnapshot->p50Nanoseconds = QuantileUpperBound(
        buckets, overflowSamples, maximumNanoseconds, 50000, 100000);
    outSnapshot->p999Nanoseconds = QuantileUpperBound(
        buckets, overflowSamples, maximumNanoseconds, 99900, 100000);
    outSnapshot->p99999Nanoseconds = QuantileUpperBound(
        buckets, overflowSamples, maximumNanoseconds, 99999, 100000);
    outSnapshot->maximumNanoseconds = maximumNanoseconds;
    outSnapshot->deadlineNanoseconds = atomic_load_explicit(
        &telemetry->deadlineNanoseconds, memory_order_acquire);
    outSnapshot->overflowSamples = overflowSamples;
    outSnapshot->missedDeadlines = atomic_load_explicit(
        &telemetry->missedDeadlines, memory_order_acquire);
    outSnapshot->callbackOverlaps = atomic_load_explicit(
        &telemetry->callbackOverlaps, memory_order_acquire);
    outSnapshot->allocationViolations = atomic_load_explicit(
        &telemetry->allocationViolations, memory_order_acquire);
    outSnapshot->maximumUpdateContentions = atomic_load_explicit(
        &telemetry->maximumUpdateContentions, memory_order_acquire);
    outSnapshot->isCoherent = callbacksAreFenced
        && distributionSamples == committedSamples;
}
