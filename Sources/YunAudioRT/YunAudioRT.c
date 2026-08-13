//
//  YunAudioRT.c
//

#include "include/YunAudioRT.h"

#include <AudioToolbox/AudioWorkInterval.h>
#include <os/object.h>
#include <pthread.h>
#include <unistd.h>
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

#pragma mark - Latest-value control mailbox

typedef struct {
    _Atomic uint32_t valueBits;
    _Atomic uint64_t version;
    /// Consumer-only. No atomic traffic is needed for a value only the IO
    /// thread reads and writes.
    uint64_t consumedVersion;
} YunRTControlSlot;

struct YunRTControlMailbox {
    YunRTControlSlot *slots;
    uint32_t routeCount;
    uint32_t slotCount;
    /// Producer-only generation reservation. The release store to `desired`
    /// publishes the slot which carries this number.
    uint64_t nextGeneration;
    _Atomic uint64_t desiredGeneration;
    _Atomic uint64_t appliedGeneration;
};

_Static_assert(sizeof(float) == sizeof(uint32_t),
               "The control mailbox stores IEEE float bits atomically");

typedef union {
    float value;
    uint32_t bits;
} YunRTFloatBits;

static int64_t YunRTControlSlotIndex(
    const YunRTControlMailbox *mailbox, int32_t kind, int32_t index) {
    if (kind == kYunRTCommandSetGain || kind == kYunRTCommandSetMute) {
        if (index < 0 || (uint32_t)index >= mailbox->routeCount) return -1;
        return (int64_t)((uint32_t)index * 2u + (uint32_t)kind);
    }
    if (kind >= kYunRTCommandSetInputGain &&
        kind <= kYunRTCommandClearOutputClipping) {
        return (int64_t)(mailbox->routeCount * 2u +
                         (uint32_t)(kind - kYunRTCommandSetInputGain));
    }
    return -1;
}

YunRTControlMailbox *yun_rt_control_mailbox_create(uint32_t routeCount) {
    uint64_t globalSlots =
        (uint64_t)(kYunRTCommandClearOutputClipping - kYunRTCommandSetInputGain + 1);
    uint64_t slotCount = (uint64_t)routeCount * 2u + globalSlots;
    if (slotCount > UINT32_MAX) return NULL;

    YunRTControlMailbox *mailbox = calloc(1, sizeof(YunRTControlMailbox));
    if (mailbox == NULL) return NULL;
    mailbox->slots = calloc((size_t)slotCount, sizeof(YunRTControlSlot));
    if (mailbox->slots == NULL) {
        free(mailbox);
        return NULL;
    }
    mailbox->routeCount = routeCount;
    mailbox->slotCount = (uint32_t)slotCount;
    atomic_store_explicit(&mailbox->desiredGeneration, 0, memory_order_relaxed);
    atomic_store_explicit(&mailbox->appliedGeneration, 0, memory_order_relaxed);
    return mailbox;
}

void yun_rt_control_mailbox_free(YunRTControlMailbox *mailbox) {
    if (mailbox == NULL) return;
    free(mailbox->slots);
    free(mailbox);
}

bool yun_rt_control_mailbox_publish(
    YunRTControlMailbox *mailbox, YunRTCommand command) {
    int64_t slotIndex = YunRTControlSlotIndex(mailbox, command.kind, command.index);
    if (slotIndex < 0 || (uint64_t)slotIndex >= mailbox->slotCount) return false;

    YunRTFloatBits encoded = {.value = command.value};
    uint64_t generation = ++mailbox->nextGeneration;
    YunRTControlSlot *slot = &mailbox->slots[slotIndex];
    atomic_store_explicit(&slot->valueBits, encoded.bits, memory_order_relaxed);
    atomic_store_explicit(&slot->version, generation, memory_order_release);
    // Last: observing this generation means its complete slot is visible.
    atomic_store_explicit(
        &mailbox->desiredGeneration, generation, memory_order_release);
    return true;
}

uint64_t yun_rt_control_mailbox_begin(YunRTControlMailbox *mailbox) {
    uint64_t desired =
        atomic_load_explicit(&mailbox->desiredGeneration, memory_order_acquire);
    uint64_t applied =
        atomic_load_explicit(&mailbox->appliedGeneration, memory_order_relaxed);
    return desired == applied ? 0 : desired;
}

bool yun_rt_control_mailbox_take(
    YunRTControlMailbox *mailbox,
    int32_t kind,
    int32_t index,
    YunRTCommand *outCommand) {
    int64_t slotIndex = YunRTControlSlotIndex(mailbox, kind, index);
    if (slotIndex < 0 || (uint64_t)slotIndex >= mailbox->slotCount) return false;

    YunRTControlSlot *slot = &mailbox->slots[slotIndex];
    uint64_t version = atomic_load_explicit(&slot->version, memory_order_acquire);
    if (version == 0 || version == slot->consumedVersion) return false;
    YunRTFloatBits encoded = {
        .bits = atomic_load_explicit(&slot->valueBits, memory_order_relaxed)};
    slot->consumedVersion = version;
    *outCommand =
        (YunRTCommand){.kind = kind, .index = index, .value = encoded.value};
    return true;
}

void yun_rt_control_mailbox_finish(
    YunRTControlMailbox *mailbox, uint64_t generation) {
    atomic_store_explicit(
        &mailbox->appliedGeneration, generation, memory_order_release);
}

uint64_t yun_rt_control_mailbox_desired_generation(
    YunRTControlMailbox *mailbox) {
    return atomic_load_explicit(&mailbox->desiredGeneration, memory_order_acquire);
}

uint64_t yun_rt_control_mailbox_applied_generation(
    YunRTControlMailbox *mailbox) {
    return atomic_load_explicit(&mailbox->appliedGeneration, memory_order_acquire);
}

#pragma mark - Realtime pointer publication

struct YunRTCell {
    _Atomic(void *) pointer;
    /// Incremented by the realtime thread once per completed cycle.
    _Atomic uint64_t cycles;
    /// A stalled old callback must prevent later callbacks from advancing its
    /// retirement fence. The HAL does not publicly promise non-reentrancy, so
    /// make that premise executable instead of relying on it.
    _Atomic uint32_t readerActive;
    _Atomic uint64_t overlaps;
};

YunRTCell *yun_rt_cell_create(void *initial) {
    YunRTCell *cell = calloc(1, sizeof(YunRTCell));
    if (cell == NULL) return NULL;
    atomic_store_explicit(&cell->pointer, initial, memory_order_relaxed);
    atomic_store_explicit(&cell->cycles, 0, memory_order_relaxed);
    atomic_store_explicit(&cell->readerActive, 0, memory_order_relaxed);
    atomic_store_explicit(&cell->overlaps, 0, memory_order_relaxed);
    return cell;
}

void yun_rt_cell_free(YunRTCell *cell) { free(cell); }

void *yun_rt_cell_load(YunRTCell *cell) {
    uint32_t expected = 0;
    if (!atomic_compare_exchange_strong_explicit(
            &cell->readerActive, &expected, 1,
            memory_order_acq_rel, memory_order_relaxed)) {
        atomic_fetch_add_explicit(&cell->overlaps, 1, memory_order_relaxed);
        return NULL;
    }
    void *pointer = atomic_load_explicit(&cell->pointer, memory_order_acquire);
    if (pointer == NULL) {
        atomic_store_explicit(&cell->readerActive, 0, memory_order_release);
    }
    return pointer;
}

void *yun_rt_cell_publish(YunRTCell *cell, void *next) {
    // Release: everything written into the new graph must be visible to the
    // realtime thread that observes the pointer.
    return atomic_exchange_explicit(&cell->pointer, next, memory_order_acq_rel);
}

void yun_rt_cell_retire(YunRTCell *cell) {
    uint32_t wasActive =
        atomic_exchange_explicit(&cell->readerActive, 0, memory_order_acq_rel);
    if (wasActive != 0) {
        atomic_fetch_add_explicit(&cell->cycles, 1, memory_order_release);
    }
}

uint64_t yun_rt_cell_cycles(YunRTCell *cell) {
    return atomic_load_explicit(&cell->cycles, memory_order_acquire);
}

uint64_t yun_rt_cell_overlaps(YunRTCell *cell) {
    return atomic_load_explicit(&cell->overlaps, memory_order_acquire);
}

bool yun_rt_cell_wait_for_swap(YunRTCell *cell, uint32_t timeoutMilliseconds) {
    return yun_rt_cell_wait_until(
        cell, yun_rt_cell_retirement_fence(cell), timeoutMilliseconds);
}

uint64_t yun_rt_cell_retirement_fence(YunRTCell *cell) {
    return atomic_load_explicit(&cell->cycles, memory_order_acquire) + 2;
}

bool yun_rt_cell_has_reached(YunRTCell *cell, uint64_t retirementFence) {
    uint64_t now = atomic_load_explicit(&cell->cycles, memory_order_acquire);
    // The fence is at most a handful of cycles ahead. Half-range modular
    // ordering stays correct across the once-in-centuries UInt64 wrap without
    // turning a wrapped target into a fence that can never be reached.
    return (now - retirementFence) < (UINT64_C(1) << 63);
}

bool yun_rt_cell_wait_until(
    YunRTCell *cell, uint64_t retirementFence, uint32_t timeoutMilliseconds) {
    // Poll rather than block on a condition variable: the realtime thread must
    // never touch a lock, so it cannot signal one. A cycle is well under a
    // millisecond, so this returns almost immediately when audio is running.
    for (uint32_t elapsed = 0;; ++elapsed) {
        if (yun_rt_cell_has_reached(cell, retirementFence)) return true;
        if (elapsed >= timeoutMilliseconds) return false;
        usleep(1000);
    }
}

#pragma mark - Atomic counters shared with realtime callbacks

struct YunRTAtomicCounter {
    _Atomic uint64_t value;
};

YunRTAtomicCounter *yun_rt_counter_create(uint64_t initialValue) {
    YunRTAtomicCounter *counter = malloc(sizeof(YunRTAtomicCounter));
    if (counter == NULL) return NULL;
    atomic_init(&counter->value, initialValue);
    return counter;
}

void yun_rt_counter_free(YunRTAtomicCounter *counter) { free(counter); }

void yun_rt_counter_increment(YunRTAtomicCounter *counter) {
    // Release makes an increment a publication point for any append-only
    // payload completed before it. Diagnostics use this to pair a failure
    // count with the status written immediately before that failure.
    atomic_fetch_add_explicit(&counter->value, 1, memory_order_release);
}

void yun_rt_counter_store(YunRTAtomicCounter *counter, uint64_t value) {
    atomic_store_explicit(&counter->value, value, memory_order_release);
}

uint64_t yun_rt_counter_load(YunRTAtomicCounter *counter) {
    return atomic_load_explicit(&counter->value, memory_order_acquire);
}

#pragma mark - Echo-cancellation Audio Unit callbacks

struct YunRTEchoRenderDiagnostics {
    _Atomic uint64_t sequence;
    _Atomic uint64_t failureCount;
    _Atomic uint32_t statusBits;
};

_Static_assert(sizeof(OSStatus) == sizeof(uint32_t),
               "Echo diagnostics preserve OSStatus as exact 32-bit bits");

YunRTEchoRenderDiagnostics *yun_rt_echo_render_diagnostics_create(void) {
    YunRTEchoRenderDiagnostics *diagnostics =
        malloc(sizeof(YunRTEchoRenderDiagnostics));
    if (diagnostics == NULL) return NULL;
    atomic_init(&diagnostics->sequence, 0);
    atomic_init(&diagnostics->failureCount, 0);
    atomic_init(&diagnostics->statusBits, 0);
    return diagnostics;
}

void yun_rt_echo_render_diagnostics_free(
    YunRTEchoRenderDiagnostics *diagnostics) {
    free(diagnostics);
}

void yun_rt_echo_render_diagnostics_record(
    YunRTEchoRenderDiagnostics *diagnostics, OSStatus status) {
    uint32_t statusBits = 0;
    memcpy(&statusBits, &status, sizeof(statusBits));
    atomic_fetch_add_explicit(&diagnostics->sequence, 1, memory_order_acq_rel);
    atomic_fetch_add_explicit(
        &diagnostics->failureCount, 1, memory_order_relaxed);
    atomic_store_explicit(
        &diagnostics->statusBits, statusBits, memory_order_relaxed);
    atomic_fetch_add_explicit(&diagnostics->sequence, 1, memory_order_release);
}

bool yun_rt_echo_render_diagnostics_load(
    YunRTEchoRenderDiagnostics *diagnostics,
    uint64_t *failureCount,
    OSStatus *status) {
    for (uint32_t attempt = 0; attempt < 8; ++attempt) {
        uint64_t before =
            atomic_load_explicit(&diagnostics->sequence, memory_order_acquire);
        if ((before & 1u) != 0) continue;
        uint64_t count = atomic_load_explicit(
            &diagnostics->failureCount, memory_order_relaxed);
        uint32_t bits = atomic_load_explicit(
            &diagnostics->statusBits, memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        uint64_t after =
            atomic_load_explicit(&diagnostics->sequence, memory_order_acquire);
        if (before != after || (after & 1u) != 0) continue;
        *failureCount = count;
        memcpy(status, &bits, sizeof(bits));
        return true;
    }
    return false;
}

struct YunRTEchoCallbackContext {
    AudioUnit unit;
    uint32_t maximumFrames;
    AudioBufferList *captureBufferList;
    float *captureBuffer;
    YunRTAtomicCounter *truncatedBlocks;
    YunRTAtomicCounter *inputCallbacks;
    YunRTAtomicCounter *farEndCallbacks;
    YunRTEchoRenderDiagnostics *renderDiagnostics;
    _Atomic uint32_t inputActive;
    _Atomic uint64_t inputOverlaps;
    _Atomic uint32_t renderActive;
    _Atomic uint64_t renderOverlaps;
    YunRTEchoCaptureHandler captureHandler;
    void *captureContext;
    YunRTEchoFarEndProvider farEndProvider;
    void *farEndContext;
};

YunRTEchoCallbackContext *yun_rt_echo_callback_context_create(
    AudioUnit unit,
    uint32_t maximumFrames,
    AudioBufferList *captureBufferList,
    float *captureBuffer,
    YunRTAtomicCounter *truncatedBlocks,
    YunRTAtomicCounter *inputCallbacks,
    YunRTAtomicCounter *farEndCallbacks,
    YunRTEchoRenderDiagnostics *renderDiagnostics) {
    if (maximumFrames == 0 ||
        maximumFrames > kYunRTEchoMaximumFramesPerSlice) {
        return NULL;
    }
    YunRTEchoCallbackContext *context = calloc(1, sizeof(YunRTEchoCallbackContext));
    if (context == NULL) return NULL;
    context->unit = unit;
    context->maximumFrames = maximumFrames;
    context->captureBufferList = captureBufferList;
    context->captureBuffer = captureBuffer;
    context->truncatedBlocks = truncatedBlocks;
    context->inputCallbacks = inputCallbacks;
    context->farEndCallbacks = farEndCallbacks;
    context->renderDiagnostics = renderDiagnostics;
    atomic_init(&context->inputActive, 0);
    atomic_init(&context->inputOverlaps, 0);
    atomic_init(&context->renderActive, 0);
    atomic_init(&context->renderOverlaps, 0);
    return context;
}

void yun_rt_echo_callback_context_free(YunRTEchoCallbackContext *context) {
    free(context);
}

void yun_rt_echo_callback_context_bind(
    YunRTEchoCallbackContext *context,
    YunRTEchoCaptureHandler captureHandler,
    void *captureContext,
    YunRTEchoFarEndProvider farEndProvider,
    void *farEndContext) {
    context->captureContext = captureContext;
    context->farEndContext = farEndContext;
    context->farEndProvider = farEndProvider;
    // The capture pointer is the admission flag, and is therefore published
    // last even though lifecycle fencing means no callback can race this call.
    context->captureHandler = captureHandler;
}

void yun_rt_echo_callback_context_clear(YunRTEchoCallbackContext *context) {
    // AudioOutputUnitStop is the callback fence. Clearing the admission flag
    // first makes an accidental post-stop entry silent before control code
    // releases either raw handler context.
    context->captureHandler = NULL;
    context->farEndProvider = NULL;
    context->captureContext = NULL;
    context->farEndContext = NULL;
}

uint64_t yun_rt_echo_callback_context_overlaps(
    YunRTEchoCallbackContext *context) {
    uint64_t input =
        atomic_load_explicit(&context->inputOverlaps, memory_order_acquire);
    uint64_t render =
        atomic_load_explicit(&context->renderOverlaps, memory_order_acquire);
    return input + render;
}

static OSStatus YunRTEchoInputBody(
    YunRTEchoCallbackContext *context,
    AudioUnitRenderActionFlags *flags,
    const AudioTimeStamp *timestamp,
    uint32_t bus,
    uint32_t frameCount) {
    uint32_t expected = 0;
    if (!atomic_compare_exchange_strong_explicit(
            &context->inputActive, &expected, 1,
            memory_order_acq_rel, memory_order_relaxed)) {
        atomic_fetch_add_explicit(
            &context->inputOverlaps, 1, memory_order_relaxed);
        return noErr;
    }
    YunRTEchoCaptureHandler handler = context->captureHandler;
    if (handler == NULL) {
        atomic_store_explicit(&context->inputActive, 0, memory_order_release);
        return noErr;
    }

    yun_rt_counter_increment(context->inputCallbacks);
    uint32_t frames = frameCount;
    if (frames > context->maximumFrames) {
        frames = context->maximumFrames;
        yun_rt_counter_increment(context->truncatedBlocks);
    }
    context->captureBufferList->mBuffers[0].mDataByteSize =
        frames * (uint32_t)sizeof(float);
    OSStatus status = AudioUnitRender(
        context->unit, flags, timestamp, bus, frames, context->captureBufferList);
    if (status != noErr) {
        yun_rt_echo_render_diagnostics_record(context->renderDiagnostics, status);
        atomic_store_explicit(&context->inputActive, 0, memory_order_release);
        return status;
    }
    handler(context->captureContext, context->captureBuffer, frames, timestamp);
    atomic_store_explicit(&context->inputActive, 0, memory_order_release);
    return noErr;
}

OSStatus yun_rt_echo_input_callback(
    void *refCon,
    AudioUnitRenderActionFlags *flags,
    const AudioTimeStamp *timestamp,
    uint32_t bus,
    uint32_t frameCount,
    AudioBufferList *ioData) {
    (void)ioData;
    yun_rt_tripwire_mark_realtime(true);
    OSStatus status = YunRTEchoInputBody(
        (YunRTEchoCallbackContext *)refCon, flags, timestamp, bus, frameCount);
    yun_rt_tripwire_mark_realtime(false);
    return status;
}

/// Marks the host buffer silent without trusting its variable-length layout or
/// advertised byte count. AudioBufferList always contains its first buffer in
/// the fixed header, but no later buffer may be inspected until the count is
/// exactly the configured one.
static void YunRTEchoFailSilent(
    const YunRTEchoCallbackContext *context,
    AudioUnitRenderActionFlags *flags,
    uint32_t frameCount,
    AudioBufferList *ioData) {
    if (flags != NULL) {
        *flags |= kAudioUnitRenderAction_OutputIsSilence;
    }
    if (ioData == NULL || ioData->mNumberBuffers == 0) return;
    AudioBuffer *buffer = &ioData->mBuffers[0];
    if (buffer->mData == NULL) return;

    uint64_t requestedBytes = (uint64_t)frameCount * sizeof(float);
    uint64_t maximumBytes = (uint64_t)context->maximumFrames * sizeof(float);
    uint64_t clearBytes = buffer->mDataByteSize;
    if (clearBytes > requestedBytes) clearBytes = requestedBytes;
    if (clearBytes > maximumBytes) clearBytes = maximumBytes;
    memset(buffer->mData, 0, (size_t)clearBytes);
}

/// Clears a valid mono buffer range through the same absolute context bound
/// used by every refusal path.
static void YunRTEchoClearFrames(
    const YunRTEchoCallbackContext *context,
    AudioBuffer *buffer,
    uint32_t firstFrame,
    uint32_t frameCount) {
    if (buffer->mData == NULL || frameCount == 0 ||
        firstFrame >= context->maximumFrames) {
        return;
    }
    uint32_t boundedFrames = frameCount;
    uint32_t maximumRemaining = context->maximumFrames - firstFrame;
    if (boundedFrames > maximumRemaining) boundedFrames = maximumRemaining;

    uint32_t availableFrames =
        buffer->mDataByteSize / (uint32_t)sizeof(float);
    if (firstFrame >= availableFrames) return;
    uint32_t availableRemaining = availableFrames - firstFrame;
    if (boundedFrames > availableRemaining) boundedFrames = availableRemaining;
    memset(
        (float *)buffer->mData + firstFrame, 0,
        (size_t)boundedFrames * sizeof(float));
}

static OSStatus YunRTEchoRenderBody(
    YunRTEchoCallbackContext *context,
    AudioUnitRenderActionFlags *flags,
    uint32_t frameCount,
    AudioBufferList *ioData) {
    yun_rt_counter_increment(context->farEndCallbacks);

    if (frameCount > context->maximumFrames) {
        YunRTEchoFailSilent(context, flags, frameCount, ioData);
        return kAudioUnitErr_TooManyFramesToProcess;
    }
    if (ioData == NULL || ioData->mNumberBuffers != 1) {
        YunRTEchoFailSilent(context, flags, frameCount, ioData);
        return kAudioUnitErr_InvalidParameter;
    }

    AudioBuffer *buffer = &ioData->mBuffers[0];
    uint64_t requestedBytes = (uint64_t)frameCount * sizeof(float);
    if (buffer->mNumberChannels != 1 ||
        (frameCount > 0 && buffer->mData == NULL) ||
        buffer->mDataByteSize % (uint32_t)sizeof(float) != 0 ||
        (uint64_t)buffer->mDataByteSize < requestedBytes) {
        YunRTEchoFailSilent(context, flags, frameCount, ioData);
        return kAudioUnitErr_InvalidParameter;
    }

    int64_t reported = 0;
    if (frameCount > 0 && context->farEndProvider != NULL) {
        reported = context->farEndProvider(
            context->farEndContext, (float *)buffer->mData, frameCount);
    }
    uint32_t written = 0;
    if (reported > 0) {
        written = (uint64_t)reported < frameCount
            ? (uint32_t)reported
            : frameCount;
    }
    if (written < frameCount) {
        YunRTEchoClearFrames(
            context, buffer, written, frameCount - written);
    }
    return noErr;
}

OSStatus yun_rt_echo_render_callback(
    void *refCon,
    AudioUnitRenderActionFlags *flags,
    const AudioTimeStamp *timestamp,
    uint32_t bus,
    uint32_t frameCount,
    AudioBufferList *ioData) {
    (void)timestamp;
    (void)bus;
    yun_rt_tripwire_mark_realtime(true);
    YunRTEchoCallbackContext *context = (YunRTEchoCallbackContext *)refCon;
    if (flags != NULL) {
        *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
    }
    uint32_t expected = 0;
    if (!atomic_compare_exchange_strong_explicit(
            &context->renderActive, &expected, 1,
            memory_order_acq_rel, memory_order_relaxed)) {
        atomic_fetch_add_explicit(
            &context->renderOverlaps, 1, memory_order_relaxed);
        YunRTEchoFailSilent(context, flags, frameCount, ioData);
        yun_rt_tripwire_mark_realtime(false);
        return noErr;
    }
    OSStatus status = YunRTEchoRenderBody(
        context, flags, frameCount, ioData);
    atomic_store_explicit(&context->renderActive, 0, memory_order_release);
    yun_rt_tripwire_mark_realtime(false);
    return status;
}

struct YunRTAtomicFloat {
    _Atomic uint32_t bits;
};

YunRTAtomicFloat *yun_rt_atomic_float_create(float initialValue) {
    YunRTAtomicFloat *value = malloc(sizeof(YunRTAtomicFloat));
    if (value == NULL) return NULL;
    YunRTFloatBits encoded = {.value = initialValue};
    atomic_init(&value->bits, encoded.bits);
    return value;
}

void yun_rt_atomic_float_free(YunRTAtomicFloat *value) { free(value); }

void yun_rt_atomic_float_store(YunRTAtomicFloat *value, float next) {
    YunRTFloatBits encoded = {.value = next};
    atomic_store_explicit(&value->bits, encoded.bits, memory_order_release);
}

float yun_rt_atomic_float_load(YunRTAtomicFloat *value) {
    YunRTFloatBits encoded = {
        .bits = atomic_load_explicit(&value->bits, memory_order_acquire)};
    return encoded.value;
}

#pragma mark - Atomic clock publication

struct YunRTClock {
    /// Odd while the writer is replacing the pair, even when it is stable.
    _Atomic uint64_t sequence;
    /// Atomic payloads are required as well as the sequence. A seqlock made
    /// from ordinary fields still has a C data race, however often the reader
    /// retries after discovering it.
    _Atomic uint64_t sampleTimeBits;
    _Atomic uint64_t hostTime;
};

_Static_assert(ATOMIC_INT_LOCK_FREE == 2 && ATOMIC_LONG_LOCK_FREE == 2 &&
                   ATOMIC_LLONG_LOCK_FREE == 2,
               "Realtime publication requires lock-free 32- and 64-bit atomics");

YunRTClock *yun_rt_clock_create(void) {
    YunRTClock *clock = calloc(1, sizeof(YunRTClock));
    if (clock == NULL) return NULL;
    atomic_store_explicit(&clock->sequence, 0, memory_order_relaxed);
    atomic_store_explicit(&clock->sampleTimeBits, 0, memory_order_relaxed);
    atomic_store_explicit(&clock->hostTime, 0, memory_order_relaxed);
    return clock;
}

void yun_rt_clock_free(YunRTClock *clock) { free(clock); }

void yun_rt_clock_publish(YunRTClock *clock, double sampleTime, uint64_t hostTime) {
    uint64_t bits = 0;
    memcpy(&bits, &sampleTime, sizeof(bits));

    // The first increment prevents a reader from accepting either payload
    // while it is changing. The release on the second publishes the complete
    // pair to a reader that observes that even sequence.
    atomic_fetch_add_explicit(&clock->sequence, 1, memory_order_acq_rel);
    atomic_store_explicit(&clock->sampleTimeBits, bits, memory_order_relaxed);
    atomic_store_explicit(&clock->hostTime, hostTime, memory_order_relaxed);
    atomic_fetch_add_explicit(&clock->sequence, 1, memory_order_release);
}

bool yun_rt_clock_load(YunRTClock *clock, double *sampleTime, uint64_t *hostTime) {
    for (uint32_t attempt = 0; attempt < 8; ++attempt) {
        uint64_t before = atomic_load_explicit(&clock->sequence, memory_order_acquire);
        if ((before & 1) != 0) continue;
        uint64_t bits =
            atomic_load_explicit(&clock->sampleTimeBits, memory_order_relaxed);
        uint64_t host = atomic_load_explicit(&clock->hostTime, memory_order_relaxed);
        // Keep the confirming sequence load after both payload loads. The
        // acquire on `before` protects the other edge; neither one alone is a
        // complete read-side seqlock on weakly ordered CPUs.
        atomic_thread_fence(memory_order_acquire);
        uint64_t after = atomic_load_explicit(&clock->sequence, memory_order_acquire);
        if (before != after || (after & 1) != 0) continue;
        memcpy(sampleTime, &bits, sizeof(bits));
        *hostTime = host;
        return true;
    }
    return false;
}

#pragma mark - Coherent realtime telemetry

struct YunRTTelemetry {
    uint32_t routeCount;
    _Atomic uint64_t sequence;
    _Atomic uint32_t *peakBits;
    _Atomic uint32_t *rmsBits;
    _Atomic uint64_t *energyBits;
    _Atomic uint64_t *calibrationFrames;
    _Atomic uint32_t outputPeakBits;
    _Atomic uint64_t outputClipped;
    _Atomic uint64_t outputLimiterFailures;
};

typedef union {
    double value;
    uint64_t bits;
} YunRTDoubleBits;

YunRTTelemetry *yun_rt_telemetry_create(uint32_t routeCount) {
    YunRTTelemetry *telemetry = calloc(1, sizeof(YunRTTelemetry));
    if (telemetry == NULL) return NULL;
    size_t count = routeCount > 0 ? routeCount : 1;
    telemetry->peakBits = calloc(count, sizeof(*telemetry->peakBits));
    telemetry->rmsBits = calloc(count, sizeof(*telemetry->rmsBits));
    telemetry->energyBits = calloc(count, sizeof(*telemetry->energyBits));
    telemetry->calibrationFrames =
        calloc(count, sizeof(*telemetry->calibrationFrames));
    if (telemetry->peakBits == NULL || telemetry->rmsBits == NULL ||
        telemetry->energyBits == NULL || telemetry->calibrationFrames == NULL) {
        yun_rt_telemetry_free(telemetry);
        return NULL;
    }
    telemetry->routeCount = routeCount;
    return telemetry;
}

void yun_rt_telemetry_free(YunRTTelemetry *telemetry) {
    if (telemetry == NULL) return;
    free(telemetry->peakBits);
    free(telemetry->rmsBits);
    free(telemetry->energyBits);
    free(telemetry->calibrationFrames);
    free(telemetry);
}

void yun_rt_telemetry_publish(
    YunRTTelemetry *telemetry,
    const float *peaks,
    const float *rms,
    const double *calibrationEnergy,
    const uint64_t *calibrationFrames,
    uint32_t routeCount,
    float outputPeak,
    uint64_t outputClipped,
    uint64_t outputLimiterFailures) {
    if (routeCount != telemetry->routeCount) return;
    // The acquire half is intentional. A release-only store would order work
    // which came before it, not the payload stores which follow it, and could
    // let a reader accept a new array element under the preceding even
    // sequence on a weakly ordered CPU. This matches the clock publisher's
    // writer-side seqlock contract.
    atomic_fetch_add_explicit(&telemetry->sequence, 1, memory_order_acq_rel);
    for (uint32_t index = 0; index < routeCount; ++index) {
        YunRTFloatBits peak = {.value = peaks[index]};
        YunRTFloatBits mean = {.value = rms[index]};
        YunRTDoubleBits energy = {.value = calibrationEnergy[index]};
        atomic_store_explicit(
            &telemetry->peakBits[index], peak.bits, memory_order_relaxed);
        atomic_store_explicit(
            &telemetry->rmsBits[index], mean.bits, memory_order_relaxed);
        atomic_store_explicit(
            &telemetry->energyBits[index], energy.bits, memory_order_relaxed);
        atomic_store_explicit(
            &telemetry->calibrationFrames[index], calibrationFrames[index],
            memory_order_relaxed);
    }
    YunRTFloatBits output = {.value = outputPeak};
    atomic_store_explicit(
        &telemetry->outputPeakBits, output.bits, memory_order_relaxed);
    atomic_store_explicit(
        &telemetry->outputClipped, outputClipped, memory_order_relaxed);
    atomic_store_explicit(
        &telemetry->outputLimiterFailures, outputLimiterFailures,
        memory_order_relaxed);
    atomic_fetch_add_explicit(&telemetry->sequence, 1, memory_order_release);
}

bool yun_rt_telemetry_load(
    YunRTTelemetry *telemetry,
    float *peaks,
    float *rms,
    double *calibrationEnergy,
    uint64_t *calibrationFrames,
    uint32_t routeCapacity,
    float *outputPeak,
    uint64_t *outputClipped,
    uint64_t *outputLimiterFailures) {
    bool readsRoutes = peaks != NULL || rms != NULL || calibrationEnergy != NULL ||
                       calibrationFrames != NULL;
    if (readsRoutes && routeCapacity < telemetry->routeCount) return false;
    for (uint32_t attempt = 0; attempt < 8; ++attempt) {
        uint64_t before =
            atomic_load_explicit(&telemetry->sequence, memory_order_acquire);
        if (before == 0) return false;
        if ((before & 1u) != 0) continue;
        if (readsRoutes) {
            for (uint32_t index = 0; index < telemetry->routeCount; ++index) {
                if (peaks != NULL) {
                    YunRTFloatBits value = {.bits = atomic_load_explicit(
                        &telemetry->peakBits[index], memory_order_relaxed)};
                    peaks[index] = value.value;
                }
                if (rms != NULL) {
                    YunRTFloatBits value = {.bits = atomic_load_explicit(
                        &telemetry->rmsBits[index], memory_order_relaxed)};
                    rms[index] = value.value;
                }
                if (calibrationEnergy != NULL) {
                    YunRTDoubleBits value = {.bits = atomic_load_explicit(
                        &telemetry->energyBits[index], memory_order_relaxed)};
                    calibrationEnergy[index] = value.value;
                }
                if (calibrationFrames != NULL) {
                    calibrationFrames[index] = atomic_load_explicit(
                        &telemetry->calibrationFrames[index], memory_order_relaxed);
                }
            }
        }
        YunRTFloatBits output = {.bits = atomic_load_explicit(
            &telemetry->outputPeakBits, memory_order_relaxed)};
        uint64_t clipped = atomic_load_explicit(
            &telemetry->outputClipped, memory_order_relaxed);
        uint64_t failures = atomic_load_explicit(
            &telemetry->outputLimiterFailures, memory_order_relaxed);
        // Pair with the writer's final release and prevent the confirmation
        // from moving ahead of any element in this candidate frame.
        atomic_thread_fence(memory_order_acquire);
        uint64_t after =
            atomic_load_explicit(&telemetry->sequence, memory_order_acquire);
        if (before != after || (after & 1u) != 0) continue;
        if (outputPeak != NULL) *outputPeak = output.value;
        if (outputClipped != NULL) *outputClipped = clipped;
        if (outputLimiterFailures != NULL) *outputLimiterFailures = failures;
        return true;
    }
    return false;
}

uint32_t yun_rt_telemetry_route_count(YunRTTelemetry *telemetry) {
    return telemetry->routeCount;
}

#pragma mark - Sample ring

struct YunRTRing {
    float *samples;
    uint32_t capacity;  // power of two
    uint32_t mask;
    _Atomic uint32_t writeIndex;
    _Atomic uint32_t readIndex;
    _Atomic uint64_t dropped;
};

YunRTRing *yun_rt_ring_create(uint32_t capacity) {
    uint32_t slots = RoundUpToPowerOfTwo(capacity < 1024 ? 1024 : capacity);
    YunRTRing *ring = calloc(1, sizeof(YunRTRing));
    if (ring == NULL) return NULL;
    ring->samples = calloc(slots, sizeof(float));
    if (ring->samples == NULL) {
        free(ring);
        return NULL;
    }
    ring->capacity = slots;
    ring->mask = slots - 1;
    return ring;
}

void yun_rt_ring_free(YunRTRing *ring) {
    if (ring == NULL) return;
    free(ring->samples);
    free(ring);
}

// Copied in at most two runs rather than sample by sample.
//
// The capacity is a power of two, so a block spans the wrap at most once: the
// part up to the end of the storage, then the part from the start. The masked
// per-sample loop this replaces cost about one float per clock cycle because
// every store carried an and, an add and a bounds-free index calculation that
// nothing could vectorise. Two memcpys hand the same bytes to code that already
// knows how to move sixteen at a time.
//
// memcpy on the IO thread is not a violation of anything: it takes no lock,
// makes no syscall and allocates nothing, and the callback already memsets the
// output bus every cycle.
//
// Measured over the callback at 128 frames, against the same graph with the
// consumer switched off: the analysis fold went from 104 ns a cycle to 74, and
// feeding the recorder from 86 ns to 31.
uint32_t yun_rt_ring_write(YunRTRing *ring, const float *samples, uint32_t count) {
    uint32_t write = atomic_load_explicit(&ring->writeIndex, memory_order_relaxed);
    uint32_t read = atomic_load_explicit(&ring->readIndex, memory_order_acquire);
    uint32_t free_slots = ring->capacity - (write - read) - 1;
    uint32_t taken = count < free_slots ? count : free_slots;

    uint32_t offset = write & ring->mask;
    uint32_t first = ring->capacity - offset;
    if (first > taken) first = taken;
    memcpy(ring->samples + offset, samples, first * sizeof(float));
    if (taken > first) {
        memcpy(ring->samples, samples + first, (taken - first) * sizeof(float));
    }
    atomic_store_explicit(&ring->writeIndex, write + taken, memory_order_release);

    if (taken < count) {
        atomic_fetch_add_explicit(&ring->dropped, count - taken, memory_order_relaxed);
    }
    return taken;
}

uint32_t yun_rt_ring_read(YunRTRing *ring, float *destination, uint32_t capacity) {
    uint32_t read = atomic_load_explicit(&ring->readIndex, memory_order_relaxed);
    uint32_t write = atomic_load_explicit(&ring->writeIndex, memory_order_acquire);
    uint32_t available = write - read;
    uint32_t taken = available < capacity ? available : capacity;

    uint32_t offset = read & ring->mask;
    uint32_t first = ring->capacity - offset;
    if (first > taken) first = taken;
    memcpy(destination, ring->samples + offset, first * sizeof(float));
    if (taken > first) {
        memcpy(destination + first, ring->samples, (taken - first) * sizeof(float));
    }
    atomic_store_explicit(&ring->readIndex, read + taken, memory_order_release);
    return taken;
}

uint64_t yun_rt_ring_dropped(YunRTRing *ring) {
    return atomic_load_explicit(&ring->dropped, memory_order_relaxed);
}

uint32_t yun_rt_ring_written(YunRTRing *ring) {
    return atomic_load_explicit(&ring->writeIndex, memory_order_relaxed);
}

uint32_t yun_rt_ring_available(YunRTRing *ring) {
    uint32_t write = atomic_load_explicit(&ring->writeIndex, memory_order_acquire);
    uint32_t read = atomic_load_explicit(&ring->readIndex, memory_order_relaxed);
    return write - read;
}

#pragma mark - Allocation tripwire

/// The allocator calls this on every operation when it is non-NULL. It is a
/// documented hook used by Instruments and the malloc stack logger.
typedef void (*yun_malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2,
                                    uintptr_t arg3, uintptr_t result,
                                    uint32_t framesToSkip);
extern yun_malloc_logger_t malloc_logger;

/// Realtime threads are identified by pthread handles rather than a
/// thread-local flag. A `_Thread_local` looks natural and is a trap: its first
/// access can allocate, the allocator calls this logger, the logger touches the
/// thread-local again, and the recursion runs the stack out.
///
/// A route normally owns one IOProc, but VoiceProcessingIO and diagnostic
/// callbacks can overlap it. A single global handle silently stopped watching
/// the first callback as soon as the second one entered. This fixed registry
/// has no allocation, lock or first-touch cost on either path.
#define YUN_RT_TRIPWIRE_THREAD_CAPACITY 16
static _Atomic uint64_t gRealtimeThreads[YUN_RT_TRIPWIRE_THREAD_CAPACITY];
/// Nesting belongs to a slot rather than to thread-local storage for the same
/// reason as the thread identifier above: first-touch TLS is allowed to
/// allocate. Only the registered thread changes its own depth while the
/// tripwire is installed; atomics keep diagnostics and teardown defined.
static _Atomic uint32_t gRealtimeThreadDepths[YUN_RT_TRIPWIRE_THREAD_CAPACITY];
static _Atomic uint64_t gTripwireViolations = 0;
static _Atomic uint64_t gTripwireRegistrationFailures = 0;
static _Atomic bool gTripwireInstalled = false;
static _Atomic uint32_t gTripwireClients = 0;
static atomic_flag gTripwireOwnershipLock = ATOMIC_FLAG_INIT;

static void LockTripwireOwnership(void) {
    while (atomic_flag_test_and_set_explicit(
        &gTripwireOwnershipLock, memory_order_acquire)) {}
}

static void UnlockTripwireOwnership(void) {
    atomic_flag_clear_explicit(&gTripwireOwnershipLock, memory_order_release);
}

/// Counts and returns. Installation is refused when another logger exists: not
/// chaining would disable its measurement, while calling an unknown logger
/// from inside the allocator is not a safe compatibility strategy.
static void TripwireLogger(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3,
                           uintptr_t result, uint32_t framesToSkip) {
    (void)type; (void)arg1; (void)arg2; (void)arg3; (void)result; (void)framesToSkip;
    uint64_t current = (uint64_t)(uintptr_t)pthread_self();
    for (uint32_t index = 0; index < YUN_RT_TRIPWIRE_THREAD_CAPACITY; ++index) {
        if (atomic_load_explicit(&gRealtimeThreads[index], memory_order_relaxed) ==
            current) {
            atomic_fetch_add_explicit(&gTripwireViolations, 1, memory_order_relaxed);
            return;
        }
    }
}

bool yun_rt_tripwire_enable(void) {
    LockTripwireOwnership();
    uint32_t clients = atomic_load_explicit(&gTripwireClients, memory_order_relaxed);
    if (clients > 0) {
        bool stillOwned = malloc_logger == TripwireLogger;
        if (stillOwned && clients < UINT32_MAX) {
            atomic_store_explicit(&gTripwireClients, clients + 1, memory_order_relaxed);
        }
        UnlockTripwireOwnership();
        return stillOwned && clients < UINT32_MAX;
    }
    if (malloc_logger != NULL) {
        UnlockTripwireOwnership();
        return false;
    }
    malloc_logger = TripwireLogger;
    atomic_store_explicit(&gTripwireClients, 1, memory_order_relaxed);
    atomic_store_explicit(&gTripwireInstalled, true, memory_order_release);
    UnlockTripwireOwnership();
    return true;
}

void yun_rt_tripwire_disable(void) {
    LockTripwireOwnership();
    uint32_t clients = atomic_load_explicit(&gTripwireClients, memory_order_relaxed);
    if (clients == 0) {
        UnlockTripwireOwnership();
        return;
    }
    clients -= 1;
    atomic_store_explicit(&gTripwireClients, clients, memory_order_relaxed);
    if (clients > 0) {
        UnlockTripwireOwnership();
        return;
    }
    atomic_store_explicit(&gTripwireInstalled, false, memory_order_release);
    // Do not overwrite a logger somebody installed after this measurement.
    if (malloc_logger == TripwireLogger) malloc_logger = NULL;
    for (uint32_t index = 0; index < YUN_RT_TRIPWIRE_THREAD_CAPACITY; ++index) {
        atomic_store_explicit(&gRealtimeThreads[index], 0, memory_order_relaxed);
        atomic_store_explicit(
            &gRealtimeThreadDepths[index], 0, memory_order_relaxed);
    }
    UnlockTripwireOwnership();
}

void yun_rt_tripwire_mark_realtime(bool isRealtime) {
    // The shipping-off path stays one relaxed load. Scanning the registry on
    // every ordinary callback would make the measurement tool itself a
    // permanent realtime cost.
    if (!atomic_load_explicit(&gTripwireInstalled, memory_order_relaxed)) return;
    uint64_t current = (uint64_t)(uintptr_t)pthread_self();
    if (isRealtime) {
        for (uint32_t index = 0; index < YUN_RT_TRIPWIRE_THREAD_CAPACITY; ++index) {
            if (atomic_load_explicit(&gRealtimeThreads[index], memory_order_relaxed) ==
                current) {
                uint32_t depth = atomic_load_explicit(
                    &gRealtimeThreadDepths[index], memory_order_relaxed);
                if (depth == UINT32_MAX) {
                    atomic_fetch_add_explicit(
                        &gTripwireRegistrationFailures, 1, memory_order_relaxed);
                    return;
                }
                atomic_store_explicit(
                    &gRealtimeThreadDepths[index], depth + 1,
                    memory_order_relaxed);
                return;
            }
        }
        for (uint32_t index = 0; index < YUN_RT_TRIPWIRE_THREAD_CAPACITY; ++index) {
            uint64_t empty = 0;
            if (atomic_compare_exchange_strong_explicit(
                    &gRealtimeThreads[index], &empty, current, memory_order_relaxed,
                    memory_order_relaxed)) {
                atomic_store_explicit(
                    &gRealtimeThreadDepths[index], 1, memory_order_relaxed);
                return;
            }
        }
        atomic_fetch_add_explicit(
            &gTripwireRegistrationFailures, 1, memory_order_relaxed);
        return;
    }

    for (uint32_t index = 0; index < YUN_RT_TRIPWIRE_THREAD_CAPACITY; ++index) {
        if (atomic_load_explicit(&gRealtimeThreads[index], memory_order_relaxed) !=
            current) {
            continue;
        }
        uint32_t depth = atomic_load_explicit(
            &gRealtimeThreadDepths[index], memory_order_relaxed);
        if (depth > 1) {
            atomic_store_explicit(
                &gRealtimeThreadDepths[index], depth - 1, memory_order_relaxed);
            return;
        }
        // Clear the depth before making the slot claimable. Reversing these two
        // stores lets a new thread claim the identifier between them and then
        // have its freshly-installed depth erased by this departing thread.
        atomic_store_explicit(
            &gRealtimeThreadDepths[index], 0, memory_order_relaxed);
        uint64_t marked = current;
        (void)atomic_compare_exchange_strong_explicit(
            &gRealtimeThreads[index], &marked, 0, memory_order_relaxed,
            memory_order_relaxed);
        return;
    }
}

uint32_t yun_rt_tripwire_current_thread_depth(void) {
    uint64_t current = (uint64_t)(uintptr_t)pthread_self();
    for (uint32_t index = 0; index < YUN_RT_TRIPWIRE_THREAD_CAPACITY; ++index) {
        if (atomic_load_explicit(&gRealtimeThreads[index], memory_order_relaxed) ==
            current) {
            return atomic_load_explicit(
                &gRealtimeThreadDepths[index], memory_order_relaxed);
        }
    }
    return 0;
}

uint32_t yun_rt_tripwire_marked_thread_count(void) {
    uint32_t count = 0;
    for (uint32_t index = 0; index < YUN_RT_TRIPWIRE_THREAD_CAPACITY; ++index) {
        if (atomic_load_explicit(&gRealtimeThreads[index], memory_order_relaxed) != 0) {
            ++count;
        }
    }
    return count;
}

uint64_t yun_rt_tripwire_registration_failures(void) {
    return atomic_load_explicit(
        &gTripwireRegistrationFailures, memory_order_relaxed);
}

uint64_t yun_rt_tripwire_violations(void) {
    return atomic_load_explicit(&gTripwireViolations, memory_order_relaxed);
}
