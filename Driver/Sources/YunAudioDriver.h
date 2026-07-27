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
#define kDevice_Manufacturer "Yuhuan Studio"
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

#define kDevice_DefaultSampleRate 48000.0

#pragma mark - Object IDs

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Box = 2,
    kObjectID_Device = 3,
    kObjectID_Stream_Input = 4,
    kObjectID_Stream_Output = 5,
    kObjectID_Volume_Output_Master = 6,
    kObjectID_Mute_Output_Master = 7,
};

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
};

#define kYunAnchorKey_SampleTime "sampleTime"
#define kYunAnchorKey_HostTime "hostTime"
#define kYunAnchorKey_SampleRate "sampleRate"

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

typedef struct {
    /// Guards everything below except the ring buffer, which is touched only
    /// by the IO thread and by readers that tolerate a frame of skew.
    pthread_mutex_t stateMutex;

    AudioServerPlugInHostRef host;

    UInt32 refCount;
    bool isInitialized;

    // Box
    bool boxAcquired;

    // Device
    Float64 sampleRate;
    UInt32 ioRunningCount;
    /// Rate requested through SetPropertyData, applied when the host calls
    /// PerformDeviceConfigurationChange.
    Float64 pendingSampleRate;

    // Output control state
    Float32 outputVolume;
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
    UInt64 timeStampCount;

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
    /// the input stream.
    Float32 *ringBuffer;
} YunDriverState;

extern YunDriverState gDriver;

#endif /* YUN_AUDIO_DRIVER_H */
