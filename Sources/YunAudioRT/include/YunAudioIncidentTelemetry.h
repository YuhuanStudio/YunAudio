#ifndef YUN_AUDIO_INCIDENT_TELEMETRY_H
#define YUN_AUDIO_INCIDENT_TELEMETRY_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Resolution and fixed storage cost of one route's callback distribution.
///
/// The final regular bucket ends at 4,095,999 ns. Longer callbacks are counted
/// separately and retain a conservative maximum, so a missed deadline can
/// never be hidden inside an apparently ordinary final bucket.
enum {
    kYunRTIncidentBucketWidthNanoseconds = 4000,
    kYunRTIncidentBucketCount = 1024,
    kYunRTIncidentHistogramBytes =
        kYunRTIncidentBucketCount * (int)sizeof(uint64_t),
};

typedef struct YunRTIncidentCallbackTelemetry YunRTIncidentCallbackTelemetry;

/// A control-thread reading of the fixed callback distribution.
///
/// `isCoherent` is true only when the caller declared that every callback was
/// fenced and the bucket total agreed with the committed sample count. A live
/// reading is deliberately labelled best-effort even when two adjacent atomic
/// reads happen to match; matching reads are not a callback-lifetime proof.
typedef struct YunRTIncidentCallbackSnapshot {
    uint64_t samples;
    uint64_t p50Nanoseconds;
    uint64_t p999Nanoseconds;
    uint64_t p99999Nanoseconds;
    uint64_t maximumNanoseconds;
    uint64_t deadlineNanoseconds;
    uint64_t overflowSamples;
    uint64_t missedDeadlines;
    uint64_t callbackOverlaps;
    uint64_t allocationViolations;
    uint64_t maximumUpdateContentions;
    bool isCoherent;
} YunRTIncidentCallbackSnapshot;

/// Allocates the fixed route-lifetime storage. Never call from a callback.
YunRTIncidentCallbackTelemetry *_Nullable yun_rt_incident_callback_create(void);

/// Frees storage after every writer has been fenced. Never call from a callback.
void yun_rt_incident_callback_free(
    YunRTIncidentCallbackTelemetry *_Nullable telemetry);

/// Adds one admitted callback in constant time without locks or allocation.
///
/// `allocationViolations` is the delta observed during this callback, not the
/// process-lifetime total. A zero deadline means the owner did not have a valid
/// deadline measurement; it is never counted as a miss.
void yun_rt_incident_callback_observe(
    YunRTIncidentCallbackTelemetry *_Nonnull telemetry,
    uint64_t elapsedNanoseconds,
    uint64_t deadlineNanoseconds,
    uint64_t allocationViolations);

/// Counts a callback refused because another writer was already active.
///
/// The refusal is not an admitted sample and therefore does not alter the
/// latency distribution. Any allocation delta still belongs to this run.
void yun_rt_incident_callback_refuse_overlap(
    YunRTIncidentCallbackTelemetry *_Nonnull telemetry,
    uint64_t allocationViolations);

/// Records one immutable graph generation published into this route lifetime.
void yun_rt_incident_graph_published(
    YunRTIncidentCallbackTelemetry *_Nonnull telemetry);

/// Number of graph generations in this route, including the initial one.
uint64_t yun_rt_incident_graph_generations(
    const YunRTIncidentCallbackTelemetry *_Nonnull telemetry);

/// Reads a bounded summary on a control thread.
///
/// Passing `callbacksAreFenced` is a lifetime assertion by the owner, not a
/// request to stop callbacks. The function never waits for a writer.
void yun_rt_incident_callback_snapshot(
    const YunRTIncidentCallbackTelemetry *_Nonnull telemetry,
    bool callbacksAreFenced,
    YunRTIncidentCallbackSnapshot *_Nonnull outSnapshot);

#ifdef __cplusplus
}
#endif

#endif /* YUN_AUDIO_INCIDENT_TELEMETRY_H */
