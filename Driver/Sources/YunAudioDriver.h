//
//  YunAudioDriver.h
//  A virtual audio device implemented as an AudioServerPlugIn.
//
//  Written from scratch against <CoreAudio/AudioServerPlugIn.h>. BlackHole is
//  GPL-3.0; none of its code is used here, so this project stays free to pick
//  its own licence.
//
//  Why ship a driver at all, when BlackHole already works: because the host
//  drives a device's timing from GetZeroTimeStamp(), and that function is ours.
//  A virtual device whose sample clock is derived from the physical microphone
//  is sample-locked to it, which means no drift, no drift correction, and no
//  resampling anywhere on the path. A third-party loopback device cannot do
//  that — it has no idea which microphone the user cares about.
//

#ifndef YUN_AUDIO_DRIVER_H
#define YUN_AUDIO_DRIVER_H

#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>

#pragma mark - Identity

#define kDriver_BundleID "com.yuhuanstudio.yunaudio.driver"
#define kDevice_Name "YunAudio"
#define kDevice_UID "YunAudioDevice_UID"
#define kDevice_ModelUID "YunAudioDevice_Model"
#define kDevice_Manufacturer "YuhuanStudio"
#define kBox_UID "YunAudioBox_UID"

#pragma mark - Configuration

/// Stereo. Deliberately not sixteen channels: the device shows up in every
/// application's picker, and a clean 2-channel endpoint is what a voice chat
/// or a stream actually wants.
#define kDevice_ChannelCount 2

/// Power of two so the ring index is a mask rather than a modulo on the IO
/// thread. One second at 96 kHz is comfortable headroom.
#define kRingBufferFrames 131072
#define kRingBufferMask (kRingBufferFrames - 1)
/// Seventeen bits encode every legal callback length as `frames - 1`.
#define kRingTransactionFrameBits 17
/// The remaining 47 bits cover more than 46 years at 96 kHz. The device clock
/// restarts on every driver lifetime, so rejecting the next frame is a bounded
/// fail-safe, not a practical session limit.
#define kRingTransactionMaximumStart ((UINT64_C(1) << 47) - 2)

#define kDevice_DefaultSampleRate 48000.0

/// The one buffer period this fixed-latency virtual device advertises.
/// Explicitly publishing the size and its one-value range keeps the HAL from
/// having to infer a callback contract from the safety offset.
#define kDevice_BufferFrameSize 512

/// Gives CoreAudio enough notice to finish a loopback write before an
/// independent input client reads the same sample time. One whole advertised
/// period costs 10.67 ms at 48 kHz. Apple permits individual operation sizes
/// to differ from the nominal period, so per-frame publication — rather than
/// this constant alone — decides whether those uncommon cycles are ready.
#define kDevice_SafetyOffsetFrames kDevice_BufferFrameSize

#pragma mark - Object IDs

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Box = 2,
    kObjectID_Device = 3,
    kObjectID_Stream_Input = 4,
    kObjectID_Stream_Output = 5,
    kObjectID_Volume_Input_Master = 6,
    kObjectID_Mute_Input_Master = 7,
    kObjectID_Volume_Output_Master = 8,
    kObjectID_Mute_Output_Master = 9,
};

/// Range of the level controls, in decibels.
///
/// Both scopes carry one. The first attempt gave only the input scope a
/// control, on the reasoning that whatever writes into the device already had a
/// fader of its own — but this device appears in both the input and the output
/// list, and macOS draws a slider on whichever tab you are looking at whether
/// the device implements one or not. A scope without a control is a slider that
/// moves and does nothing, which is worse than the problem it was avoiding.
#define kVolume_MinimumDecibels (-64.0f)
#define kVolume_MaximumDecibels (0.0f)

#pragma mark - Custom properties

/// Set by the YunAudio application to publish the clock anchor of the physical
/// device it is capturing. Once the driver follows that anchor, its sample clock
/// and the microphone's advance together, so the aggregate no longer needs
/// drift correction and the path becomes bit-exact.
///
/// Payload is a CFDictionary (kAudioServerPlugInCustomPropertyDataTypeCFPropertyList)
/// with the keys below, all CFNumbers of kCFNumberDoubleType. A property set is
/// the only channel that crosses coreaudiod's sandbox; shared memory does not.
enum {
    kYunCustomProperty_ClockAnchor = 'yclk',
    kYunCustomProperty_IOHealth = 'yioh',
};

#define kYunAnchorKey_SampleTime "sampleTime"
#define kYunAnchorKey_HostTime "hostTime"
#define kYunAnchorKey_SampleRate "sampleRate"
#define kYunIOHealthKey_UnsafeReadOperations "unsafeReadOperations"
#define kYunIOHealthKey_UnsafeWriteOperations "unsafeWriteOperations"

/// An anchor is only trusted for this long. If the application stops publishing
/// — it quit, or routing stopped — the device falls back to the host clock
/// rather than freewheeling on a stale measurement.
#define kClockAnchorTimeoutSeconds 2.0

/// A measured rate further than this from nominal is a bad sample, not real
/// drift. Real crystals are tens of parts per million out, not percent.
#define kClockFollowMaxDeviation 0.01

/// One-pole smoothing on the measured rate. Individual anchor pairs are noisy
/// because host timestamps are taken on a scheduled thread.
#define kClockFollowSmoothing 0.1

#pragma mark - Driver state

/// One coherently published view of the clock for GetZeroTimeStamp.
///
/// Every member is atomic because a sequence counter alone does not make
/// concurrent non-atomic C accesses legal. The reader retries a bounded number
/// of times and therefore never waits for a property setter holding stateMutex.
typedef struct {
    _Atomic UInt64 version;
    _Atomic UInt64 anchorHostTime;
    _Atomic UInt64 hostTicksPerFrameBits;
    _Atomic UInt64 nominalTicksPerFrameBits;
    _Atomic UInt64 lastAnchorReceivedAt;
    _Atomic UInt64 anchorTimeoutTicks;
    _Atomic UInt64 isClockFollowing;
    _Atomic UInt64 seed;
} YunPublishedClock;

/// One independently published stereo frame in the shared loopback timeline.
///
/// CoreAudio identifies each callback's client but does not promise that
/// callbacks for different clients share a thread or a serial executor. All
/// three fields are therefore atomic. `owner` packs the absolute start and
/// frame count into one non-zero, collision-free transaction identity;
/// `sampleFrame` prevents stale wraparound data and `stereoBits` keeps left and
/// right from ever belonging to different writes.
typedef struct {
    _Atomic UInt64 owner;
    _Atomic UInt64 sampleFrame;
    _Atomic UInt64 stereoBits;
} YunRingFrame;

typedef struct {
    /// Guards everything below except atomic fields and the ring buffer.
    pthread_mutex_t stateMutex;

    /// Serialises the short admission and reconciliation stages around a
    /// configuration request. It is deliberately released before calling the
    /// host because the host may synchronously re-enter this driver.
    pthread_mutex_t configurationRequestMutex;

    AudioServerPlugInHostRef host;

    UInt32 refCount;
    bool isInitialized;

    // Box
    bool boxAcquired;

    // Device
    Float64 sampleRate;
    UInt32 ioRunningCount;
    /// Stream activity is host-visible state even though this loopback does
    /// not need it to choose a different IO routine.
    bool inputStreamIsActive;
    bool outputStreamIsActive;
    /// Rate requested through SetPropertyData, applied when the host calls
    /// PerformDeviceConfigurationChange.
    Float64 pendingSampleRate;
    /// The host may defer or reorder configuration callbacks. The opaque
    /// action identifies the one request which is still allowed to commit.
    UInt64 pendingConfigurationGeneration;
    /// Non-zero only while the matching host request call has not returned.
    /// A synchronous Perform callback may clear the pending action first; this
    /// separate stage prevents a second host call from overlapping the first.
    UInt64 configurationRequestInFlightGeneration;
    UInt64 nextConfigurationGeneration;
    /// Invalidates an action returned by a previous host initialisation.
    UInt64 configurationLifetimeGeneration;

    // Output control state
    /// Scalar 0...1, as the controls report it.
    Float32 inputVolume;
    Float32 outputVolume;
    /// Effective linear gains as IEEE-754 bits. Mute is folded into the value,
    /// so an IO cycle makes one coherent lock-free load rather than racing two
    /// independently changing control fields.
    _Atomic UInt32 inputGainBits;
    _Atomic UInt32 outputGainBits;
    /// Fail-silent operation counts. Incremented relaxed on the IO thread and
    /// exposed through the read-only `yioh` custom property.
    _Atomic UInt64 unsafeReadOperations;
    _Atomic UInt64 unsafeWriteOperations;
    bool inputMuted;
    bool outputMuted;

    // Zero timestamp bookkeeping
    /// Host ticks per frame actually used to emit timestamps. Starts at the
    /// nominal value and is pulled towards the measured master rate while
    /// clock following is active.
    Float64 hostTicksPerFrame;
    /// Nominal value, kept so deviation can be bounded and so the device can
    /// snap back when following stops.
    Float64 nominalTicksPerFrame;
    UInt64 anchorHostTime;
    UInt64 clockSeed;
    UInt64 anchorTimeoutTicks;
    YunPublishedClock publishedClock;

    // Clock following
    /// Previous anchor from the application, used to measure the master's real
    /// rate across the interval between two anchors.
    Float64 lastAnchorSampleTime;
    UInt64 lastAnchorHostTime;
    bool hasLastAnchor;
    /// mach_absolute_time of the most recent anchor, for the staleness check.
    UInt64 lastAnchorReceivedAt;
    bool isClockFollowing;

    /// Loopback storage: whatever is written to the output stream reappears on
    /// the input stream. Each slot carries its absolute sample frame so a wrap
    /// cannot replay stale audio and concurrent clients never race in C.
    YunRingFrame *ringBuffer;
} YunDriverState;

extern YunDriverState gDriver;

#endif /* YUN_AUDIO_DRIVER_H */
