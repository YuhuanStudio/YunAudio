//
//  YunAudioRT.c
//

#include "include/YunAudioRT.h"

#include <AudioToolbox/AudioWorkInterval.h>
#include <os/object.h>
#include <pthread.h>
#include <os/workgroup.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(sizeof(os_workgroup_join_token_s) <= sizeof(((YunRTJoinToken *)0)->storage),
               "YunRTJoinToken.storage is too small for os_workgroup_join_token_s");

struct YunRTWorkgroup {
    os_workgroup_t workgroup;
    /// Non-NULL only for handles built by AudioWorkIntervalCreate. Kept as its
    /// own field because os_workgroup_interval_t and os_workgroup_t are
    /// distinct struct pointers outside of ObjC.
    os_workgroup_interval_t interval;
};

static YunRTWorkgroup *yun_rt_wrap(os_workgroup_t workgroup,
                                   os_workgroup_interval_t interval) {
    YunRTWorkgroup *handle = calloc(1, sizeof(YunRTWorkgroup));
    if (handle == NULL) {
        if (workgroup != NULL) {
            os_release(workgroup);
        }
        return NULL;
    }
    handle->workgroup = workgroup;
    handle->interval = interval;
    return handle;
}

YunRTWorkgroup *yun_rt_workgroup_for_device(AudioObjectID device) {
    if (device == kAudioObjectUnknown) {
        return NULL;
    }

    AudioObjectPropertyAddress address = {
        .mSelector = kAudioDevicePropertyIOThreadOSWorkgroup,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };

    if (!AudioObjectHasProperty(device, &address)) {
        return NULL;
    }

    os_workgroup_t workgroup = NULL;
    UInt32 size = (UInt32)sizeof(os_workgroup_t);
    // The property is documented as +1: "The caller is responsible for
    // releasing the returned object."
    OSStatus status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &workgroup);
    if (status != noErr || workgroup == NULL) {
        return NULL;
    }

    return yun_rt_wrap(workgroup, NULL);
}

YunRTWorkgroup *yun_rt_workgroup_create_interval(const char *name) {
    os_workgroup_interval_t interval =
        AudioWorkIntervalCreate(name, OS_CLOCK_MACH_ABSOLUTE_TIME, NULL);
    if (interval == NULL) {
        return NULL;
    }
    return yun_rt_wrap((os_workgroup_t)interval, interval);
}

void yun_rt_workgroup_free(YunRTWorkgroup *workgroup) {
    if (workgroup == NULL) {
        return;
    }
    if (workgroup->workgroup != NULL) {
        os_release(workgroup->workgroup);
    }
    free(workgroup);
}

int yun_rt_workgroup_join(YunRTWorkgroup *workgroup, YunRTJoinToken *token) {
    memset(token->storage, 0, sizeof(token->storage));
    return os_workgroup_join(workgroup->workgroup, (os_workgroup_join_token_t)token->storage);
}

void yun_rt_workgroup_leave(YunRTWorkgroup *workgroup, YunRTJoinToken *token) {
    os_workgroup_leave(workgroup->workgroup, (os_workgroup_join_token_t)token->storage);
}

bool yun_rt_interval_start(YunRTWorkgroup *workgroup, uint64_t start, uint64_t deadline) {
    if (workgroup->interval == NULL) {
        return false;
    }
    return os_workgroup_interval_start(workgroup->interval, start, deadline, NULL) == 0;
}

bool yun_rt_interval_finish(YunRTWorkgroup *workgroup) {
    if (workgroup->interval == NULL) {
        return false;
    }
    return os_workgroup_interval_finish(workgroup->interval, NULL) == 0;
}

bool yun_rt_workgroup_is_interval(YunRTWorkgroup *workgroup) {
    return workgroup->interval != NULL;
}

#pragma mark - Lock-free command queue

struct YunRTQueue {
    YunRTCommand *slots;
    uint32_t mask;
    /// Written by the producer, read by the consumer.
    _Atomic uint32_t head;
    /// Written by the consumer, read by the producer.
    _Atomic uint32_t tail;
};

static uint32_t RoundUpToPowerOfTwo(uint32_t value) {
    uint32_t result = 1;
    while (result < value && result < (1u << 31)) result <<= 1;
    return result;
}

YunRTQueue *yun_rt_queue_create(uint32_t capacity) {
    uint32_t slots = RoundUpToPowerOfTwo(capacity < 2 ? 2 : capacity);
    YunRTQueue *queue = calloc(1, sizeof(YunRTQueue));
    if (queue == NULL) return NULL;
    queue->slots = calloc(slots, sizeof(YunRTCommand));
    if (queue->slots == NULL) {
        free(queue);
        return NULL;
    }
    queue->mask = slots - 1;
    atomic_store_explicit(&queue->head, 0, memory_order_relaxed);
    atomic_store_explicit(&queue->tail, 0, memory_order_relaxed);
    return queue;
}

void yun_rt_queue_free(YunRTQueue *queue) {
    if (queue == NULL) return;
    free(queue->slots);
    free(queue);
}

bool yun_rt_queue_push(YunRTQueue *queue, YunRTCommand command) {
    uint32_t head = atomic_load_explicit(&queue->head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&queue->tail, memory_order_acquire);
    if (((head + 1) & queue->mask) == (tail & queue->mask)) return false;

    queue->slots[head & queue->mask] = command;
    // Release so the consumer that observes the new head also sees the payload.
    atomic_store_explicit(&queue->head, head + 1, memory_order_release);
    return true;
}

bool yun_rt_queue_pop(YunRTQueue *queue, YunRTCommand *outCommand) {
    uint32_t tail = atomic_load_explicit(&queue->tail, memory_order_relaxed);
    uint32_t head = atomic_load_explicit(&queue->head, memory_order_acquire);
    if ((tail & queue->mask) == (head & queue->mask)) return false;

    *outCommand = queue->slots[tail & queue->mask];
    atomic_store_explicit(&queue->tail, tail + 1, memory_order_release);
    return true;
}

#pragma mark - Allocation tripwire

/// The allocator calls this on every operation when it is non-NULL. It is a
/// documented hook used by Instruments and the malloc stack logger.
typedef void (*yun_malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2,
                                    uintptr_t arg3, uintptr_t result,
                                    uint32_t framesToSkip);
extern yun_malloc_logger_t malloc_logger;

/// The realtime thread is identified by its pthread handle rather than a
/// thread-local flag. A `_Thread_local` looks like the natural choice and is a
/// trap: its first access on a thread can allocate, the allocator calls this
/// logger, the logger touches the thread-local again, and the recursion runs
/// the stack out before anything is printed.
static _Atomic uint64_t gRealtimeThread = 0;
static _Atomic uint64_t gTripwireViolations = 0;

/// Counts and returns. Deliberately does NOT chain to whatever logger was
/// installed before: the previous hook is normally the system stack logger,
/// which is only safe to call once its own infrastructure has been initialised
/// by MallocStackLogging. Calling it blind segfaults during process start-up.
static void TripwireLogger(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3,
                           uintptr_t result, uint32_t framesToSkip) {
    (void)type; (void)arg1; (void)arg2; (void)arg3; (void)result; (void)framesToSkip;
    uint64_t marked = atomic_load_explicit(&gRealtimeThread, memory_order_relaxed);
    if (marked != 0 && marked == (uint64_t)(uintptr_t)pthread_self()) {
        atomic_fetch_add_explicit(&gTripwireViolations, 1, memory_order_relaxed);
    }
}

void yun_rt_tripwire_enable(void) {
    malloc_logger = TripwireLogger;
}

void yun_rt_tripwire_mark_realtime(bool isRealtime) {
    atomic_store_explicit(
        &gRealtimeThread,
        isRealtime ? (uint64_t)(uintptr_t)pthread_self() : 0,
        memory_order_relaxed);
}

uint64_t yun_rt_tripwire_violations(void) {
    return atomic_load_explicit(&gTripwireViolations, memory_order_relaxed);
}
