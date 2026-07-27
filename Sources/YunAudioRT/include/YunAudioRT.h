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

#include <CoreAudio/AudioHardware.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>

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
} YunRTCommandKind;

/// Single-producer, single-consumer ring. The producer is whichever thread the
/// UI runs on; the consumer is the IO thread. Neither ever blocks.
typedef struct YunRTQueue YunRTQueue;

/// `capacity` is rounded up to a power of two so the index wrap is a mask.
YunRTQueue *_Nullable yun_rt_queue_create(uint32_t capacity);
void yun_rt_queue_free(YunRTQueue *_Nullable queue);

/// Producer side. Returns false when the ring is full, which means the consumer
/// has stalled — dropping a fader update is the right failure here, since a
/// newer one is always coming.
bool yun_rt_queue_push(YunRTQueue *_Nonnull queue, YunRTCommand command);

/// Consumer side. Returns false when empty.
bool yun_rt_queue_pop(YunRTQueue *_Nonnull queue, YunRTCommand *_Nonnull outCommand);

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
/// visible to the reader that observes it.
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
/// A false return means the device is not running — the caller can free
/// immediately, since nothing is reading.
bool yun_rt_cell_wait_for_swap(YunRTCell *_Nonnull cell, uint32_t timeoutMilliseconds);

/// Cycles completed since the cell was created.
///
/// Lives here rather than in the published structure precisely because it has
/// to survive a swap: a counter that resets whenever the graph is replaced
/// cannot answer "is audio still flowing across this change", which is the one
/// question worth asking of it.
uint64_t yun_rt_cell_cycles(YunRTCell *_Nonnull cell);

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

#pragma mark - Allocation tripwire (debug builds)

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
void yun_rt_tripwire_enable(void);

/// Removes the hook and puts the allocator back the way it was found.
void yun_rt_tripwire_disable(void);

/// Marks the calling thread as realtime for the duration of an IO cycle.
void yun_rt_tripwire_mark_realtime(bool isRealtime);

/// Allocations observed on a thread marked realtime. Must stay at zero.
uint64_t yun_rt_tripwire_violations(void);

#ifdef __cplusplus
}
#endif

#endif /* YUN_AUDIO_RT_H */
