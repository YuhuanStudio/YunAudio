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
void yun_rt_tripwire_enable(void);

/// Marks the calling thread as realtime for the duration of an IO cycle.
void yun_rt_tripwire_mark_realtime(bool isRealtime);

/// Allocations observed on a thread marked realtime. Must stay at zero.
uint64_t yun_rt_tripwire_violations(void);

#ifdef __cplusplus
}
#endif

#endif /* YUN_AUDIO_RT_H */
