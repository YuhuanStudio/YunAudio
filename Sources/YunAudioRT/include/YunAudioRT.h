//
//  YunAudioRT.h
//  Realtime-thread scheduling primitives that Swift cannot reach.
//
//  <AudioToolbox/AudioWorkInterval.h> annotates AudioWorkIntervalCreate with
//  __SWIFT_UNAVAILABLE_MSG("Swift is not supported for use with audio realtime
//  threads"), and the os_workgroup family is OS_REFINED_FOR_SWIFT in a way that
//  hides the join/leave pair. Both are required to schedule auxiliary audio
//  threads against the device's IO deadline, so the whole surface is bridged
//  here and handed to Swift as opaque handles.
//

#ifndef YUN_AUDIO_RT_H
#define YUN_AUDIO_RT_H

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/AudioHardware.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>

#include "YunAudioIncidentTelemetry.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque wrapper around an `os_workgroup_t`.
typedef struct YunRTWorkgroup YunRTWorkgroup;

/// Caller-owned storage for an `os_workgroup_join_token_s`.
///
/// A thread must hand back the token it received from `yun_rt_workgroup_join`
/// in order to leave, so the token cannot live inside the workgroup handle
/// (one handle may be joined by several threads). The size is checked against
/// the real token type with a `_Static_assert` in YunAudioRT.c.
typedef struct {
    unsigned char storage[64] __attribute__((aligned(8)));
} YunRTJoinToken;

/// Copies the device's IO thread workgroup
/// (`kAudioDevicePropertyIOThreadOSWorkgroup`).
///
/// Returns NULL when the device publishes no workgroup — that is a normal
/// condition for some virtual devices, not an error.
YunRTWorkgroup *_Nullable yun_rt_workgroup_for_device(AudioObjectID device);

/// Creates a standalone audio work interval (`AudioWorkIntervalCreate`) for
/// threads that drive their own duty cycle rather than following a device.
YunRTWorkgroup *_Nullable yun_rt_workgroup_create_interval(const char *_Nonnull name);

/// Releases the underlying workgroup. Safe to call with NULL.
void yun_rt_workgroup_free(YunRTWorkgroup *_Nullable workgroup);

/// Joins the calling thread to the workgroup.
///
/// Returns 0 on success, otherwise an errno-style code. On success `token` is
/// filled in and must be passed to `yun_rt_workgroup_leave` from the same
/// thread before it exits.
int yun_rt_workgroup_join(YunRTWorkgroup *_Nonnull workgroup,
                          YunRTJoinToken *_Nonnull token);

/// Removes the calling thread from the workgroup it joined with `token`.
void yun_rt_workgroup_leave(YunRTWorkgroup *_Nonnull workgroup,
                            YunRTJoinToken *_Nonnull token);

/// Marks the start of a work cycle. Only meaningful for interval workgroups
/// created by `yun_rt_workgroup_create_interval`; returns false otherwise.
///
/// `start` and `deadline` are mach absolute time values.
bool yun_rt_interval_start(YunRTWorkgroup *_Nonnull workgroup,
                           uint64_t start,
                           uint64_t deadline);

/// Marks the end of a work cycle started by `yun_rt_interval_start`.
bool yun_rt_interval_finish(YunRTWorkgroup *_Nonnull workgroup);

/// True when the handle came from `yun_rt_workgroup_create_interval` and so
/// accepts the interval start/finish markers.
bool yun_rt_workgroup_is_interval(YunRTWorkgroup *_Nonnull workgroup);

#pragma mark - Lock-free command queue (UI -> realtime)

/// A parameter change destined for the realtime thread.
///
/// Plain scalars only. The realtime side drains these at the top of a cycle, so
/// a fader move takes effect without rebuilding the graph or restarting the
/// device.
typedef struct {
    int32_t kind;   ///< YunRTCommandKind
    int32_t index;  ///< Route the command applies to.
    float value;
} YunRTCommand;

typedef enum {
    kYunRTCommandSetGain = 0,
    kYunRTCommandSetMute = 1,
    /// Trim on the input before anything reads it, and the master on the
    /// output bus after everything has been mixed into it. `index` is unused
    /// for these — they are one control each, not one per route.
    kYunRTCommandSetInputGain = 2,
    kYunRTCommandSetInputMute = 3,
    kYunRTCommandSetOutputGain = 4,
    kYunRTCommandSetOutputMute = 5,
    /// Linear drive into the final output limiter. Like the master controls,
    /// this belongs to the complete mix and does not carry a route index.
    kYunRTCommandSetLimiterPreGain = 6,
    kYunRTCommandSetDuckingEnabled = 7,
    kYunRTCommandSetDuckingDepth = 8,
    kYunRTCommandSetDuckingAllowed = 9,
    kYunRTCommandSetAnalysisEnabled = 10,
    kYunRTCommandSetRecordingPaused = 11,
    /// A non-zero raw Float bit pattern atomically begins a fresh calibration
    /// and identifies that reset across a graph swap. Zero stops accumulation
    /// before that cycle processes audio.
    kYunRTCommandSetCalibrating = 12,
    /// The raw Float bits identify this reset across a graph swap. A dedicated
    /// coalescing slot means it cannot be discarded behind fader traffic.
    kYunRTCommandClearOutputClipping = 13,
} YunRTCommandKind;

/// Single-producer, single-consumer ring. The producer is whichever thread the
/// UI runs on; the consumer is the IO thread. Neither ever blocks.
typedef struct YunRTQueue YunRTQueue;

/// `capacity` is rounded up to a power of two so the index wrap is a mask.
YunRTQueue *_Nullable yun_rt_queue_create(uint32_t capacity);
void yun_rt_queue_free(YunRTQueue *_Nullable queue);

/// Producer side. Returns false when the ring is full. A caller must surface or
/// retry that loss; continuous controls use the latest-value mailbox below so
/// their final safety state can never disappear behind intermediate events.
bool yun_rt_queue_push(YunRTQueue *_Nonnull queue, YunRTCommand command);

/// Consumer side. Returns false when empty.
bool yun_rt_queue_pop(YunRTQueue *_Nonnull queue, YunRTCommand *_Nonnull outCommand);

#pragma mark - Latest-value control mailbox (UI -> realtime)

/// Coalescing control state for values whose final setting matters more than
/// every intermediate pointer movement.
///
/// Unlike the FIFO above this cannot become full. Each route gain/mute and each
/// global control owns one slot, so a stalled callback observes the newest
/// value when it resumes. One producer and one consumer, as for `YunRTQueue`.
typedef struct YunRTControlMailbox YunRTControlMailbox;

YunRTControlMailbox *_Nullable yun_rt_control_mailbox_create(uint32_t routeCount);
void yun_rt_control_mailbox_free(YunRTControlMailbox *_Nullable mailbox);

/// Producer side. Returns false only for an invalid kind or route index.
bool yun_rt_control_mailbox_publish(
    YunRTControlMailbox *_Nonnull mailbox, YunRTCommand command);

/// Consumer side. Returns zero when every publication has already been
/// applied; otherwise returns the generation this scan must finish against.
uint64_t yun_rt_control_mailbox_begin(YunRTControlMailbox *_Nonnull mailbox);

/// Returns the newest value for one slot when it changed since the last scan.
bool yun_rt_control_mailbox_take(
    YunRTControlMailbox *_Nonnull mailbox,
    int32_t kind,
    int32_t index,
    YunRTCommand *_Nonnull outCommand);

/// Completes one bounded scan. A publication which raced the scan has a newer
/// generation and therefore remains pending for the next callback.
void yun_rt_control_mailbox_finish(
    YunRTControlMailbox *_Nonnull mailbox, uint64_t generation);

/// Diagnostic generations: equality proves all desired values were observed.
uint64_t yun_rt_control_mailbox_desired_generation(
    YunRTControlMailbox *_Nonnull mailbox);
uint64_t yun_rt_control_mailbox_applied_generation(
    YunRTControlMailbox *_Nonnull mailbox);

#pragma mark - Realtime pointer publication (RCU)

/// A pointer the realtime thread reads and a control thread replaces.
///
/// Swapping a whole graph rather than mutating one in place is what lets a
/// route be added or removed without stopping the device. The realtime thread
/// picks up the new pointer at the top of a cycle; the control thread waits
/// until it has seen the cycle counter advance past the swap before freeing
/// what it replaced, which is the read-copy-update discipline.
///
/// Lives in C so the memory ordering is stated rather than inferred.
typedef struct YunRTCell YunRTCell;

YunRTCell *_Nullable yun_rt_cell_create(void *_Nullable initial);
void yun_rt_cell_free(YunRTCell *_Nullable cell);

/// Realtime side. Acquire, so whatever the publisher wrote before the swap is
/// visible to the reader that observes it. Returns NULL when another callback
/// is still active; that callback must fail silent and must not call `retire`.
void *_Nullable yun_rt_cell_load(YunRTCell *_Nonnull cell);

/// Control side. Returns the pointer that was there, which the caller must not
/// free until `yun_rt_cell_wait_for_swap` says the realtime thread has moved on.
void *_Nullable yun_rt_cell_publish(YunRTCell *_Nonnull cell, void *_Nullable next);

/// Records that a cycle has completed. Called by the realtime thread after it
/// has finished with whatever `yun_rt_cell_load` handed it.
void yun_rt_cell_retire(YunRTCell *_Nonnull cell);

/// Blocks until the realtime thread has completed two cycles since the publish,
/// or until `timeoutMilliseconds` elapses. Two rather than one because a cycle
/// already in flight when the swap happened may still hold the old pointer.
///
/// Returns true when the wait succeeded and the old pointer is safe to free.
/// False says only that safety could not be established before the deadline.
/// A callback may have loaded the old pointer and then stalled, so a caller
/// must retain the pointer and try its retirement fence again later.
bool yun_rt_cell_wait_for_swap(YunRTCell *_Nonnull cell, uint32_t timeoutMilliseconds);

/// The completed-cycle value after which a pointer published immediately
/// before this call can no longer be held by the realtime thread.
///
/// Store this value with the retired owner. Unlike `yun_rt_cell_wait_for_swap`,
/// a later retry then waits for the original publication rather than starting
/// an unnecessary new two-cycle grace period each time.
uint64_t yun_rt_cell_retirement_fence(YunRTCell *_Nonnull cell);

/// True once `retirementFence` has passed. This never blocks and is the polling
/// half of a deferred generation reclaimer.
bool yun_rt_cell_has_reached(YunRTCell *_Nonnull cell, uint64_t retirementFence);

/// Waits for a previously captured retirement fence, up to the given deadline.
/// False is never permission to reclaim the retired owner.
bool yun_rt_cell_wait_until(
    YunRTCell *_Nonnull cell, uint64_t retirementFence, uint32_t timeoutMilliseconds);

/// Cycles completed since the cell was created.
///
/// Lives here rather than in the published structure precisely because it has
/// to survive a swap: a counter that resets whenever the graph is replaced
/// cannot answer "is audio still flowing across this change", which is the one
/// question worth asking of it.
uint64_t yun_rt_cell_cycles(YunRTCell *_Nonnull cell);

/// Callback entries refused because an earlier callback was still active.
/// Any non-zero value disproves the expected one-reader Core Audio contract.
uint64_t yun_rt_cell_overlaps(YunRTCell *_Nonnull cell);

#pragma mark - Atomic counters shared with realtime callbacks

/// One lock-free 64-bit value for diagnostics written by a callback and read
/// by control code. `store`/`load` also publish append-only payloads which were
/// completed before the stored count.
typedef struct YunRTAtomicCounter YunRTAtomicCounter;

YunRTAtomicCounter *_Nullable yun_rt_counter_create(uint64_t initialValue);
void yun_rt_counter_free(YunRTAtomicCounter *_Nullable counter);
void yun_rt_counter_increment(YunRTAtomicCounter *_Nonnull counter);
void yun_rt_counter_store(YunRTAtomicCounter *_Nonnull counter, uint64_t value);
uint64_t yun_rt_counter_load(YunRTAtomicCounter *_Nonnull counter);

#pragma mark - Echo-cancellation Audio Unit callbacks

/// Absolute C-side ceiling for one AUVoiceProcessingIO slice. The Swift
/// admission policy uses the same 4,096-frame limit; retaining it at this ABI
/// boundary means a malformed caller still cannot create an unbounded clear.
enum { kYunRTEchoMaximumFramesPerSlice = 4096 };

/// Raw, immutable state reached directly from AUVoiceProcessingIO.
///
/// Keeping the Audio Unit, buffers and diagnostics here prevents the realtime
/// entry points from borrowing a Swift owner merely to discover C pointers.
/// The optional Swift handlers are retained by control code and exposed here
/// only as unowned raw contexts. They must remain alive until a successful
/// AudioOutputUnitStop has fenced every callback.
typedef struct YunRTEchoCallbackContext YunRTEchoCallbackContext;

typedef void (*YunRTEchoCaptureHandler)(
    void *_Nonnull context,
    const float *_Nonnull samples,
    uint32_t frames,
    const AudioTimeStamp *_Nonnull timestamp);

typedef int64_t (*YunRTEchoFarEndProvider)(
    void *_Nonnull context,
    float *_Nonnull destination,
    uint32_t frames);

/// One coherent `(failure count, OSStatus)` render diagnostic.
typedef struct YunRTEchoRenderDiagnostics YunRTEchoRenderDiagnostics;

YunRTEchoRenderDiagnostics *_Nullable
yun_rt_echo_render_diagnostics_create(void);
void yun_rt_echo_render_diagnostics_free(
    YunRTEchoRenderDiagnostics *_Nullable diagnostics);

/// Single admitted input-callback writer. Lock-free and allocation-free.
void yun_rt_echo_render_diagnostics_record(
    YunRTEchoRenderDiagnostics *_Nonnull diagnostics, OSStatus status);

/// Returns false after eight contended attempts, leaving outputs unchanged.
bool yun_rt_echo_render_diagnostics_load(
    YunRTEchoRenderDiagnostics *_Nonnull diagnostics,
    uint64_t *_Nonnull failureCount,
    OSStatus *_Nonnull status);

/// Returns NULL unless `maximumFrames` is within 1...4,096.
YunRTEchoCallbackContext *_Nullable yun_rt_echo_callback_context_create(
    AudioUnit _Nullable unit,
    uint32_t maximumFrames,
    AudioBufferList *_Nullable captureBufferList,
    float *_Nullable captureBuffer,
    YunRTAtomicCounter *_Nonnull truncatedBlocks,
    YunRTAtomicCounter *_Nonnull inputCallbacks,
    YunRTAtomicCounter *_Nonnull farEndCallbacks,
    YunRTEchoRenderDiagnostics *_Nonnull renderDiagnostics);

void yun_rt_echo_callback_context_free(
    YunRTEchoCallbackContext *_Nullable context);

/// Control side. Call only while the Audio Unit is stopped.
void yun_rt_echo_callback_context_bind(
    YunRTEchoCallbackContext *_Nonnull context,
    YunRTEchoCaptureHandler _Nonnull captureHandler,
    void *_Nonnull captureContext,
    YunRTEchoFarEndProvider _Nullable farEndProvider,
    void *_Nullable farEndContext);

/// Control side. A successful AudioOutputUnitStop must precede this call.
void yun_rt_echo_callback_context_clear(
    YunRTEchoCallbackContext *_Nonnull context);

/// Input or render entries refused because the same entry was already active.
uint64_t yun_rt_echo_callback_context_overlaps(
    YunRTEchoCallbackContext *_Nonnull context);

/// Realtime entry points installed on AUVoiceProcessingIO.
///
/// The render entry accepts exactly one mono buffer. It returns
/// `kAudioUnitErr_TooManyFramesToProcess` when `frameCount` exceeds the
/// context's admitted maximum and `kAudioUnitErr_InvalidParameter` for an
/// invalid buffer layout or byte count. Refusals mark the output silent and
/// clear no more than `maximumFrames * sizeof(float)` bytes.
OSStatus yun_rt_echo_input_callback(
    void *_Nonnull refCon,
    AudioUnitRenderActionFlags *_Nonnull flags,
    const AudioTimeStamp *_Nonnull timestamp,
    uint32_t bus,
    uint32_t frameCount,
    AudioBufferList *_Nullable ioData);

OSStatus yun_rt_echo_render_callback(
    void *_Nonnull refCon,
    AudioUnitRenderActionFlags *_Nonnull flags,
    const AudioTimeStamp *_Nonnull timestamp,
    uint32_t bus,
    uint32_t frameCount,
    AudioBufferList *_Nullable ioData);

/// One lock-free Float transported as exact IEEE-754 bits.
typedef struct YunRTAtomicFloat YunRTAtomicFloat;

YunRTAtomicFloat *_Nullable yun_rt_atomic_float_create(float initialValue);
void yun_rt_atomic_float_free(YunRTAtomicFloat *_Nullable value);
void yun_rt_atomic_float_store(YunRTAtomicFloat *_Nonnull value, float next);
float yun_rt_atomic_float_load(YunRTAtomicFloat *_Nonnull value);

#pragma mark - Atomic clock publication (realtime -> control)

/// One coherent `(sampleTime, hostTime)` pair guarded by a C11 atomic seqlock.
typedef struct YunRTClock YunRTClock;

YunRTClock *_Nullable yun_rt_clock_create(void);
void yun_rt_clock_free(YunRTClock *_Nullable clock);

/// Realtime writer. Lock-free and allocation-free.
void yun_rt_clock_publish(
    YunRTClock *_Nonnull clock, double sampleTime, uint64_t hostTime);

/// Control reader. Returns false when the writer remained active through all
/// eight bounded attempts; a caller should keep its previous anchor and retry
/// on its next ordinary poll.
bool yun_rt_clock_load(
    YunRTClock *_Nonnull clock,
    double *_Nonnull sampleTime,
    uint64_t *_Nonnull hostTime);

#pragma mark - Coherent realtime telemetry (realtime -> control)

/// One fixed-capacity meter frame published with a C11 atomic seqlock.
/// Swift's ordinary Float and UInt64 loads are data races even when a torn
/// meter value would be visually harmless; this boundary makes the complete
/// frame defined as well as coherent.
typedef struct YunRTTelemetry YunRTTelemetry;

YunRTTelemetry *_Nullable yun_rt_telemetry_create(uint32_t routeCount);
void yun_rt_telemetry_free(YunRTTelemetry *_Nullable telemetry);

/// Realtime writer. Every array contains `routeCount` elements.
void yun_rt_telemetry_publish(
    YunRTTelemetry *_Nonnull telemetry,
    const float *_Nonnull peaks,
    const float *_Nonnull rms,
    const double *_Nonnull calibrationEnergy,
    const uint64_t *_Nonnull calibrationFrames,
    uint32_t routeCount,
    float outputPeak,
    uint64_t outputClipped,
    uint64_t outputLimiterFailures);

/// Control reader. Returns false before the first complete realtime frame.
/// Optional arrays are filled only when non-NULL; when present
/// their capacity must cover the route count. Returns false after eight
/// contended attempts. Array storage is then indeterminate because an
/// unsuccessful attempt may have started filling it; use staging storage and
/// retain the preceding complete frame, as the engine reader does.
bool yun_rt_telemetry_load(
    YunRTTelemetry *_Nonnull telemetry,
    float *_Nullable peaks,
    float *_Nullable rms,
    double *_Nullable calibrationEnergy,
    uint64_t *_Nullable calibrationFrames,
    uint32_t routeCapacity,
    float *_Nullable outputPeak,
    uint64_t *_Nullable outputClipped,
    uint64_t *_Nullable outputLimiterFailures);

uint32_t yun_rt_telemetry_route_count(YunRTTelemetry *_Nonnull telemetry);

#pragma mark - Sample ring (realtime -> writer)

/// A lock-free ring of floats.
///
/// Distinct from the command queue: that carries a handful of parameter changes,
/// this carries continuous audio and has to be sized in seconds rather than
/// messages. Same discipline — one producer on the realtime thread, one
/// consumer, neither ever blocking.
typedef struct YunRTRing YunRTRing;

YunRTRing *_Nullable yun_rt_ring_create(uint32_t capacity);
void yun_rt_ring_free(YunRTRing *_Nullable ring);

/// Producer. Returns how many samples were taken; a short count means the
/// consumer fell behind and the remainder was dropped, which is the right
/// trade — stalling the IO thread would cost the live signal too.
uint32_t yun_rt_ring_write(
    YunRTRing *_Nonnull ring, const float *_Nonnull samples, uint32_t count);

/// Consumer. Returns how many samples were taken.
uint32_t yun_rt_ring_read(
    YunRTRing *_Nonnull ring, float *_Nonnull destination, uint32_t capacity);

/// Samples the producer had to drop. Non-zero means the recording has gaps.
uint64_t yun_rt_ring_dropped(YunRTRing *_Nonnull ring);

/// Samples the producer has written since the ring was made, wrapping at 2^32.
/// Tells "nothing was ever produced" apart from "it was produced and consumed",
/// which the fill level alone cannot.
uint32_t yun_rt_ring_written(YunRTRing *_Nonnull ring);

/// Samples waiting to be read. The slack between two realtime threads: steady
/// is healthy, climbing means the consumer is slower than the producer.
uint32_t yun_rt_ring_available(YunRTRing *_Nonnull ring);

#pragma mark - Allocation tripwire (explicit diagnostics)

/// Installs a hook on the allocator that records any allocation made while the
/// calling thread is marked as realtime.
///
/// This is the only way to know the no-allocation rule actually holds. Reading
/// the code is not evidence: a Swift array growth, a string interpolation or an
/// unexpected ARC retain all allocate, and none of them are visible at the call
/// site.
///
/// Measure against an OPTIMISED build. A debug build reports hundreds of
/// allocations per cycle because Swift's own bounds and exclusivity checking
/// machinery allocates; that says nothing about the code that ships.
///
/// The hook is process-wide and sits in front of EVERY allocation the process
/// makes, not only the ones on the IO thread — there is no way to install it
/// selectively. So it is a measurement to switch on, not a thing to leave
/// running: an application that arms it at launch makes every allocation in
/// SwiftUI, AppKit and CoreAudio pay for a diagnostic nobody asked for.
/// Returns false without changing the allocator hook when another logger is
/// already installed. Silent replacement would make both measurements false.
/// Every successful call owns one reference and must be paired with disable;
/// overlapping diagnostics therefore cannot disarm each other's measurement.
bool yun_rt_tripwire_enable(void);

/// Releases one successful enable. The final release removes the hook and puts
/// the allocator back the way it was found.
void yun_rt_tripwire_disable(void);

/// Marks the calling thread as realtime for the duration of an IO cycle.
/// Marks are nestable: each true must be paired with one false, and the thread
/// remains covered until its outermost mark leaves.
void yun_rt_tripwire_mark_realtime(bool isRealtime);

/// Nesting depth of the calling thread's realtime mark. Test and diagnostic
/// support; zero means allocations on this thread are not currently covered.
uint32_t yun_rt_tripwire_current_thread_depth(void);

/// Threads currently covered by the allocation hook. A production route may
/// own more than one Core Audio callback at once.
uint32_t yun_rt_tripwire_marked_thread_count(void);

/// Marks which could not be represented by the fixed lock-free registry.
/// Any non-zero value invalidates an allocation measurement.
uint64_t yun_rt_tripwire_registration_failures(void);

/// Allocations observed on a thread marked realtime. Must stay at zero.
uint64_t yun_rt_tripwire_violations(void);

#ifdef __cplusplus
}
#endif

#endif /* YUN_AUDIO_RT_H */

// MARK: - JavaScriptCore's execution time limit

// Declared here because JavaScriptCore does not export these to Swift. They
// live in `JSContextRefPrivate.h`, which is not in the public module, and the
// symbols are in the shipping dylib — so the declaration is all that is
// missing.
//
// It is worth the awkwardness because there is no other way to stop a script.
// A scripting interface without a time limit is one `while (true)` away from
// an application that has to be force-quit, and the model this talks to lives
// on the main actor. Nothing else in JavaScriptCore's public surface can
// interrupt a loop that makes no function calls.
//
// Asserted rather than assumed: there is a test that runs an endless loop and
// requires it to come back. If a future macOS drops these, that test fails
// here rather than the interface hanging on somebody's machine.

#include <JavaScriptCore/JavaScriptCore.h>

extern void JSContextGroupSetExecutionTimeLimit(
    JSContextGroupRef _Nonnull group, double limit,
    bool (* _Nullable callback)(JSContextRef _Nonnull ctx, void * _Nullable context),
    void * _Nullable context);
extern void JSContextGroupClearExecutionTimeLimit(JSContextGroupRef _Nonnull group);
