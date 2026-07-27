//
//  YunAudioDriver.c
//
//  Object tree: PlugIn -> Device -> { input stream, output stream }.
//  No box, no volume controls. Every object the host can reach is another
//  surface that has to be correct, and a fault here takes coreaudiod down with
//  all system audio attached. The controls can be added once the core is
//  proven.
//

#include "YunAudioDriver.h"

#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#pragma mark - Globals

YunDriverState gDriver = {
    .stateMutex = PTHREAD_MUTEX_INITIALIZER,
    .sampleRate = kDevice_DefaultSampleRate,
    .pendingSampleRate = 0.0,
    .inputVolume = 1.0f,
    .inputGain = 1.0f,
    .hostTicksPerFrame = 0.0,
};

static AudioServerPlugInDriverInterface gInterface;
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;

/// The host is handed `&gInterfacePtr` by the factory, and an
/// AudioServerPlugInDriverRef is a *pointer to* the interface pointer.
/// Comparing against `gInterfacePtr` would compare the wrong level of
/// indirection and silently accept any caller.
static inline bool IsOurDriver(const void *driver) {
    return driver == (const void *)&gInterfacePtr;
}

static const Float64 kSupportedSampleRates[] = { 44100.0, 48000.0, 88200.0, 96000.0 };
static const UInt32 kSupportedSampleRateCount =
    sizeof(kSupportedSampleRates) / sizeof(kSupportedSampleRates[0]);

#define YUN_GUARD(condition, error, label) \
    if (!(condition)) {                    \
        status = (error);                  \
        goto label;                        \
    }

#pragma mark - Helpers

static void FillStreamDescription(AudioStreamBasicDescription *description, Float64 sampleRate) {
    description->mSampleRate = sampleRate;
    description->mFormatID = kAudioFormatLinearPCM;
    // Float, packed, non-interleaved is what the HAL prefers for virtual
    // devices and keeps the IO path free of any conversion.
    description->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    description->mBytesPerPacket = kDevice_ChannelCount * sizeof(Float32);
    description->mFramesPerPacket = 1;
    description->mBytesPerFrame = kDevice_ChannelCount * sizeof(Float32);
    description->mChannelsPerFrame = kDevice_ChannelCount;
    description->mBitsPerChannel = 32;
    description->mReserved = 0;
}

static bool IsSupportedSampleRate(Float64 rate) {
    for (UInt32 index = 0; index < kSupportedSampleRateCount; ++index) {
        if (kSupportedSampleRates[index] == rate) return true;
    }
    return false;
}

/// Recomputes the host-ticks-per-frame ratio. Called whenever the rate changes.
static void RefreshTimebase_Locked(void) {
    static Float64 sTicksPerSecond = 0.0;
    if (sTicksPerSecond == 0.0) {
        struct mach_timebase_info timebase;
        mach_timebase_info(&timebase);
        // mach_absolute_time ticks -> nanoseconds is numer/denom, so ticks per
        // second is 1e9 * denom / numer.
        sTicksPerSecond = 1000000000.0 * (Float64)timebase.denom / (Float64)timebase.numer;
    }
    gDriver.nominalTicksPerFrame = sTicksPerSecond / gDriver.sampleRate;
    gDriver.hostTicksPerFrame = gDriver.nominalTicksPerFrame;
    gDriver.hasLastAnchor = false;
    gDriver.isClockFollowing = false;
}

/// Converts mach ticks to seconds. Only used off the IO path.
static Float64 TicksToSeconds(UInt64 ticks) {
    static Float64 sSecondsPerTick = 0.0;
    if (sSecondsPerTick == 0.0) {
        struct mach_timebase_info timebase;
        mach_timebase_info(&timebase);
        sSecondsPerTick = ((Float64)timebase.numer / (Float64)timebase.denom) / 1000000000.0;
    }
    return (Float64)ticks * sSecondsPerTick;
}

/// Folds a new anchor from the application into the measured master rate.
///
/// Two anchors straddle a known number of master frames and a known number of
/// host ticks, which is exactly the master's real sample period — including
/// whatever its crystal is actually doing rather than what it claims. Caller
/// holds stateMutex.
static void ApplyClockAnchor_Locked(Float64 sampleTime, UInt64 hostTime, Float64 sampleRate) {
    UInt64 now = mach_absolute_time();
    gDriver.lastAnchorReceivedAt = now;

    if (gDriver.hasLastAnchor) {
        Float64 frameDelta = sampleTime - gDriver.lastAnchorSampleTime;
        Float64 tickDelta = (Float64)(hostTime - gDriver.lastAnchorHostTime);

        if (frameDelta > 0.0 && tickDelta > 0.0 && sampleRate > 0.0) {
            // Ticks per master frame, rescaled to this device's frame rate in
            // case the two run at different nominal rates.
            Float64 ticksPerMasterFrame = tickDelta / frameDelta;
            Float64 measured = ticksPerMasterFrame * (sampleRate / gDriver.sampleRate);

            Float64 deviation =
                (measured - gDriver.nominalTicksPerFrame) / gDriver.nominalTicksPerFrame;
            if (deviation < 0.0) deviation = -deviation;

            if (deviation <= kClockFollowMaxDeviation) {
                Float64 target = gDriver.isClockFollowing
                    ? gDriver.hostTicksPerFrame
                        + kClockFollowSmoothing * (measured - gDriver.hostTicksPerFrame)
                    : measured;

                // Re-base the anchor so the timestamp series stays continuous.
                // Without this, changing the slope retroactively moves every
                // past anchor and the host sees time jump — which is exactly
                // the crackle this whole design exists to avoid.
                Float64 oldTicksPerRing = gDriver.hostTicksPerFrame * (Float64)kRingBufferFrames;
                Float64 newTicksPerRing = target * (Float64)kRingBufferFrames;
                Float64 elapsed = (Float64)gDriver.timeStampCount;
                Float64 currentAnchorHost =
                    (Float64)gDriver.anchorHostTime + elapsed * oldTicksPerRing;
                gDriver.anchorHostTime = (UInt64)(currentAnchorHost - elapsed * newTicksPerRing);

                gDriver.hostTicksPerFrame = target;
                gDriver.isClockFollowing = true;
            }
        }
    }

    gDriver.lastAnchorSampleTime = sampleTime;
    gDriver.lastAnchorHostTime = hostTime;
    gDriver.hasLastAnchor = true;
}

/// Drops back to the nominal rate when the application stops publishing.
/// Caller holds stateMutex.
static void ExpireClockAnchorIfStale_Locked(void) {
    if (!gDriver.isClockFollowing) return;
    UInt64 now = mach_absolute_time();
    if (now <= gDriver.lastAnchorReceivedAt) return;
    if (TicksToSeconds(now - gDriver.lastAnchorReceivedAt) < kClockAnchorTimeoutSeconds) return;

    Float64 oldTicksPerRing = gDriver.hostTicksPerFrame * (Float64)kRingBufferFrames;
    Float64 newTicksPerRing = gDriver.nominalTicksPerFrame * (Float64)kRingBufferFrames;
    Float64 elapsed = (Float64)gDriver.timeStampCount;
    Float64 currentAnchorHost = (Float64)gDriver.anchorHostTime + elapsed * oldTicksPerRing;
    gDriver.anchorHostTime = (UInt64)(currentAnchorHost - elapsed * newTicksPerRing);

    gDriver.hostTicksPerFrame = gDriver.nominalTicksPerFrame;
    gDriver.isClockFollowing = false;
    gDriver.hasLastAnchor = false;
}

/// Pulls the three anchor fields out of the dictionary the application set.
static bool ReadAnchorDictionary(CFDictionaryRef dictionary,
                                 Float64 *outSampleTime,
                                 UInt64 *outHostTime,
                                 Float64 *outSampleRate) {
    if (dictionary == NULL || CFGetTypeID(dictionary) != CFDictionaryGetTypeID()) return false;

    Float64 values[3] = { 0.0, 0.0, 0.0 };
    const char *keys[3] = {
        kYunAnchorKey_SampleTime, kYunAnchorKey_HostTime, kYunAnchorKey_SampleRate
    };
    for (int index = 0; index < 3; ++index) {
        CFStringRef key = CFStringCreateWithCString(NULL, keys[index], kCFStringEncodingUTF8);
        if (key == NULL) return false;
        CFNumberRef number = (CFNumberRef)CFDictionaryGetValue(dictionary, key);
        CFRelease(key);
        if (number == NULL || CFGetTypeID(number) != CFNumberGetTypeID()) return false;
        if (!CFNumberGetValue(number, kCFNumberDoubleType, &values[index])) return false;
    }

    *outSampleTime = values[0];
    // Host times exceed 2^53 only after ~285 years of uptime, so a double
    // carries them exactly for any real machine.
    *outHostTime = (UInt64)values[1];
    *outSampleRate = values[2];
    return true;
}

#pragma mark - IUnknown

static HRESULT Yun_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (!IsOurDriver(inDriver) || outInterface == NULL) return kAudioHardwareBadObjectError;

    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) return kAudioHardwareIllegalOperationError;

    CFUUIDRef plugInInterface = CFUUIDGetConstantUUIDWithBytes(
        NULL, 0xEE, 0xA5, 0x77, 0x3D, 0xCC, 0x43, 0x49, 0xF1,
        0x8E, 0x00, 0x8F, 0x96, 0xE7, 0xD2, 0x3B, 0x17);
    CFUUIDRef unknownInterface = CFUUIDGetConstantUUIDWithBytes(
        NULL, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46);

    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, plugInInterface) || CFEqual(requested, unknownInterface)) {
        pthread_mutex_lock(&gDriver.stateMutex);
        ++gDriver.refCount;
        pthread_mutex_unlock(&gDriver.stateMutex);
        *outInterface = &gInterfacePtr;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG Yun_AddRef(void *inDriver) {
    if (!IsOurDriver(inDriver)) return 0;
    pthread_mutex_lock(&gDriver.stateMutex);
    if (gDriver.refCount < UINT32_MAX) ++gDriver.refCount;
    ULONG result = gDriver.refCount;
    pthread_mutex_unlock(&gDriver.stateMutex);
    return result;
}

static ULONG Yun_Release(void *inDriver) {
    if (!IsOurDriver(inDriver)) return 0;
    pthread_mutex_lock(&gDriver.stateMutex);
    if (gDriver.refCount > 0) --gDriver.refCount;
    ULONG result = gDriver.refCount;
    pthread_mutex_unlock(&gDriver.stateMutex);
    return result;
}

#pragma mark - Lifecycle

static OSStatus Yun_Initialize(AudioServerPlugInDriverRef inDriver,
                               AudioServerPlugInHostRef inHost) {
    if (!IsOurDriver(inDriver)) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gDriver.stateMutex);
    gDriver.host = inHost;
    if (gDriver.ringBuffer == NULL) {
        gDriver.ringBuffer = (Float32 *)calloc(
            (size_t)kRingBufferFrames * kDevice_ChannelCount, sizeof(Float32));
    }
    RefreshTimebase_Locked();
    gDriver.isInitialized = (gDriver.ringBuffer != NULL);
    OSStatus status = gDriver.isInitialized ? 0 : kAudioHardwareUnspecifiedError;
    pthread_mutex_unlock(&gDriver.stateMutex);
    return status;
}

/// The device is published statically, so the host never asks us to build one.
static OSStatus Yun_CreateDevice(AudioServerPlugInDriverRef inDriver,
                                 CFDictionaryRef inDescription,
                                 const AudioServerPlugInClientInfo *inClientInfo,
                                 AudioObjectID *outDeviceObjectID) {
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Yun_DestroyDevice(AudioServerPlugInDriverRef inDriver,
                                  AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Yun_AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inDeviceObjectID,
                                    const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inClientInfo;
    if (!IsOurDriver(inDriver)) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}

static OSStatus Yun_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inDeviceObjectID,
                                       const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inClientInfo;
    if (!IsOurDriver(inDriver)) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}

static OSStatus Yun_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                     AudioObjectID inDeviceObjectID,
                                                     UInt64 inChangeAction,
                                                     void *inChangeInfo) {
    (void)inChangeInfo;
    if (!IsOurDriver(inDriver)) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    // The change action carries the new rate, agreed when SetPropertyData asked
    // the host for a configuration change.
    Float64 newRate = (Float64)inChangeAction;
    if (!IsSupportedSampleRate(newRate)) return kAudioHardwareIllegalOperationError;

    pthread_mutex_lock(&gDriver.stateMutex);
    gDriver.sampleRate = newRate;
    gDriver.pendingSampleRate = 0.0;
    RefreshTimebase_Locked();
    // Restart the timestamp series: sample time is meaningless across a rate
    // change, and leaving stale anchors is how virtual devices start crackling.
    gDriver.timeStampCount = 0;
    gDriver.anchorHostTime = mach_absolute_time();
    if (gDriver.ringBuffer != NULL) {
        memset(gDriver.ringBuffer, 0,
               (size_t)kRingBufferFrames * kDevice_ChannelCount * sizeof(Float32));
    }
    pthread_mutex_unlock(&gDriver.stateMutex);
    return 0;
}

static OSStatus Yun_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                   AudioObjectID inDeviceObjectID,
                                                   UInt64 inChangeAction,
                                                   void *inChangeInfo) {
    (void)inChangeAction; (void)inChangeInfo;
    if (!IsOurDriver(inDriver)) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gDriver.stateMutex);
    gDriver.pendingSampleRate = 0.0;
    pthread_mutex_unlock(&gDriver.stateMutex);
    return 0;
}

#pragma mark - Property support

static bool IsControl(AudioObjectID objectID) {
    return objectID == kObjectID_Volume_Input_Master
        || objectID == kObjectID_Mute_Input_Master;
}

static bool ObjectExists(AudioObjectID objectID) {
    return objectID == kObjectID_PlugIn || objectID == kObjectID_Device
        || objectID == kObjectID_Stream_Input || objectID == kObjectID_Stream_Output
        || IsControl(objectID);
}

static bool StreamIsInput(AudioObjectID objectID) {
    return objectID == kObjectID_Stream_Input;
}

/// Scalar 0...1 to decibels, with a taper rather than a straight line.
///
/// A linear scalar spends most of its travel in the top few decibels, so the
/// slider feels dead over its lower half. Squaring the scalar is the usual
/// remedy and is what the system's own controls do.
static Float32 ScalarToDecibels(Float32 scalar) {
    if (scalar <= 0.0f) return kVolume_MinimumDecibels;
    if (scalar >= 1.0f) return kVolume_MaximumDecibels;
    return kVolume_MinimumDecibels
        + (kVolume_MaximumDecibels - kVolume_MinimumDecibels) * scalar * scalar;
}

static Float32 DecibelsToScalar(Float32 decibels) {
    if (decibels <= kVolume_MinimumDecibels) return 0.0f;
    if (decibels >= kVolume_MaximumDecibels) return 1.0f;
    Float32 fraction = (decibels - kVolume_MinimumDecibels)
        / (kVolume_MaximumDecibels - kVolume_MinimumDecibels);
    return sqrtf(fraction);
}

/// The linear gain the IO thread applies, from the stored scalar.
static Float32 ScalarToGain(Float32 scalar) {
    if (scalar <= 0.0f) return 0.0f;
    if (scalar >= 1.0f) return 1.0f;
    return powf(10.0f, ScalarToDecibels(scalar) / 20.0f);
}

static Boolean Yun_HasProperty(AudioServerPlugInDriverRef inDriver,
                               AudioObjectID inObjectID,
                               pid_t inClientProcessID,
                               const AudioObjectPropertyAddress *inAddress) {
    (void)inClientProcessID;
    if (!IsOurDriver(inDriver) || inAddress == NULL || !ObjectExists(inObjectID)) return false;

    // Answered by asking the size accessor, so the two can never disagree about
    // which properties exist.
    UInt32 size = 0;
    OSStatus status = gInterface.GetPropertyDataSize(
        inDriver, inObjectID, inClientProcessID, inAddress, 0, NULL, &size);
    return status == 0;
}

static OSStatus Yun_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inObjectID,
                                       pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress *inAddress,
                                       Boolean *outIsSettable) {
    (void)inClientProcessID;
    if (!IsOurDriver(inDriver) || inAddress == NULL || outIsSettable == NULL) {
        return kAudioHardwareBadObjectError;
    }
    if (!ObjectExists(inObjectID)) return kAudioHardwareBadObjectError;

    switch (inAddress->mSelector) {
    case kAudioDevicePropertyNominalSampleRate:
        *outIsSettable = (inObjectID == kObjectID_Device);
        break;
    case kAudioStreamPropertyIsActive:
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
        *outIsSettable = (inObjectID == kObjectID_Stream_Input
                          || inObjectID == kObjectID_Stream_Output);
        break;
    case kYunCustomProperty_ClockAnchor:
        *outIsSettable = (inObjectID == kObjectID_Device);
        break;
    case kAudioLevelControlPropertyScalarValue:
    case kAudioLevelControlPropertyDecibelValue:
        *outIsSettable = (inObjectID == kObjectID_Volume_Input_Master);
        break;
    case kAudioBooleanControlPropertyValue:
        *outIsSettable = (inObjectID == kObjectID_Mute_Input_Master);
        break;
    default:
        *outIsSettable = false;
        break;
    }
    return 0;
}

static OSStatus Yun_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                        AudioObjectID inObjectID,
                                        pid_t inClientProcessID,
                                        const AudioObjectPropertyAddress *inAddress,
                                        UInt32 inQualifierDataSize,
                                        const void *inQualifierData,
                                        UInt32 *outDataSize) {
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (!IsOurDriver(inDriver) || inAddress == NULL || outDataSize == NULL) {
        return kAudioHardwareBadObjectError;
    }
    if (!ObjectExists(inObjectID)) return kAudioHardwareBadObjectError;

    switch (inAddress->mSelector) {
    // Shared across every object.
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
        *outDataSize = sizeof(AudioClassID);
        return 0;
    case kAudioObjectPropertyOwner:
        *outDataSize = sizeof(AudioObjectID);
        return 0;
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyManufacturer:
    case kAudioObjectPropertyModelName:
        *outDataSize = sizeof(CFStringRef);
        return 0;

    case kAudioObjectPropertyOwnedObjects:
        if (inObjectID == kObjectID_PlugIn) {
            *outDataSize = sizeof(AudioObjectID);
        } else if (inObjectID == kObjectID_Device) {
            switch (inAddress->mScope) {
            // The input side owns its stream plus the level and mute controls.
            case kAudioObjectPropertyScopeInput:
                *outDataSize = 3 * sizeof(AudioObjectID);
                break;
            case kAudioObjectPropertyScopeOutput:
                *outDataSize = sizeof(AudioObjectID);
                break;
            default:
                *outDataSize = 2 * sizeof(AudioObjectID);
                break;
            }
        } else {
            *outDataSize = 0;
        }
        return 0;

    // PlugIn
    case kAudioPlugInPropertyDeviceList:
        if (inObjectID != kObjectID_PlugIn) break;
        *outDataSize = sizeof(AudioObjectID);
        return 0;
    case kAudioPlugInPropertyBoxList:
        if (inObjectID != kObjectID_PlugIn) break;
        *outDataSize = 0;
        return 0;
    case kAudioPlugInPropertyTranslateUIDToDevice:
        if (inObjectID != kObjectID_PlugIn) break;
        *outDataSize = sizeof(AudioObjectID);
        return 0;
    case kAudioPlugInPropertyResourceBundle:
        if (inObjectID != kObjectID_PlugIn) break;
        *outDataSize = sizeof(CFStringRef);
        return 0;

    // Device
    case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID:
        if (inObjectID != kObjectID_Device) break;
        *outDataSize = sizeof(CFStringRef);
        return 0;
    case kAudioDevicePropertyTransportType:
    case kAudioDevicePropertyClockDomain:
    case kAudioDevicePropertyDeviceIsAlive:
    case kAudioDevicePropertyDeviceIsRunning:
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
    case kAudioDevicePropertySafetyOffset:
    case kAudioDevicePropertyZeroTimeStampPeriod:
    case kAudioDevicePropertyIsHidden:
        if (inObjectID != kObjectID_Device) break;
        *outDataSize = sizeof(UInt32);
        return 0;
    case kAudioDevicePropertyNominalSampleRate:
        if (inObjectID != kObjectID_Device) break;
        *outDataSize = sizeof(Float64);
        return 0;
    case kAudioDevicePropertyAvailableNominalSampleRates:
        if (inObjectID != kObjectID_Device) break;
        *outDataSize = kSupportedSampleRateCount * sizeof(AudioValueRange);
        return 0;
    case kAudioDevicePropertyPreferredChannelsForStereo:
        if (inObjectID != kObjectID_Device) break;
        *outDataSize = 2 * sizeof(UInt32);
        return 0;
    case kAudioDevicePropertyPreferredChannelLayout:
        if (inObjectID != kObjectID_Device) break;
        *outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions)
            + (kDevice_ChannelCount * sizeof(AudioChannelDescription));
        return 0;
    case kAudioDevicePropertyStreams:
        if (inObjectID != kObjectID_Device) break;
        switch (inAddress->mScope) {
        case kAudioObjectPropertyScopeInput:
        case kAudioObjectPropertyScopeOutput:
            *outDataSize = sizeof(AudioObjectID);
            break;
        default:
            *outDataSize = 4 * sizeof(AudioObjectID);
            break;
        }
        return 0;
    case kAudioObjectPropertyControlList:
        if (inObjectID != kObjectID_Device) break;
        *outDataSize = 2 * sizeof(AudioObjectID);
        return 0;

    // Controls.
    case kAudioControlPropertyScope:
        if (!IsControl(inObjectID)) break;
        *outDataSize = sizeof(AudioObjectPropertyScope);
        return 0;
    case kAudioControlPropertyElement:
        if (!IsControl(inObjectID)) break;
        *outDataSize = sizeof(AudioObjectPropertyElement);
        return 0;
    case kAudioLevelControlPropertyScalarValue:
    case kAudioLevelControlPropertyDecibelValue:
        if (inObjectID != kObjectID_Volume_Input_Master) break;
        *outDataSize = sizeof(Float32);
        return 0;
    case kAudioLevelControlPropertyDecibelRange:
        if (inObjectID != kObjectID_Volume_Input_Master) break;
        *outDataSize = sizeof(AudioValueRange);
        return 0;
    case kAudioLevelControlPropertyConvertScalarToDecibels:
    case kAudioLevelControlPropertyConvertDecibelsToScalar:
        if (inObjectID != kObjectID_Volume_Input_Master) break;
        *outDataSize = sizeof(Float32);
        return 0;
    case kAudioBooleanControlPropertyValue:
        if (inObjectID != kObjectID_Mute_Input_Master) break;
        *outDataSize = sizeof(UInt32);
        return 0;
    case kAudioObjectPropertyCustomPropertyInfoList:
        if (inObjectID != kObjectID_Device) break;
        *outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);
        return 0;
    case kYunCustomProperty_ClockAnchor:
        if (inObjectID != kObjectID_Device) break;
        *outDataSize = sizeof(CFPropertyListRef);
        return 0;
    case kAudioDevicePropertyRelatedDevices:
        if (inObjectID != kObjectID_Device) break;
        *outDataSize = sizeof(AudioObjectID);
        return 0;

    // Streams
    case kAudioStreamPropertyIsActive:
    case kAudioStreamPropertyDirection:
    case kAudioStreamPropertyTerminalType:
    case kAudioStreamPropertyStartingChannel:
        if (inObjectID != kObjectID_Stream_Input && inObjectID != kObjectID_Stream_Output) break;
        *outDataSize = sizeof(UInt32);
        return 0;

    // kAudioDevicePropertyLatency and kAudioStreamPropertyLatency are the same
    // selector ('ltnc'), so one case serves both the device and its streams.
    case kAudioDevicePropertyLatency:
        *outDataSize = sizeof(UInt32);
        return 0;
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
        if (inObjectID != kObjectID_Stream_Input && inObjectID != kObjectID_Stream_Output) break;
        *outDataSize = sizeof(AudioStreamBasicDescription);
        return 0;
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats:
        if (inObjectID != kObjectID_Stream_Input && inObjectID != kObjectID_Stream_Output) break;
        *outDataSize = kSupportedSampleRateCount * sizeof(AudioStreamRangedDescription);
        return 0;

    default:
        break;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus Yun_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inObjectID,
                                    pid_t inClientProcessID,
                                    const AudioObjectPropertyAddress *inAddress,
                                    UInt32 inQualifierDataSize,
                                    const void *inQualifierData,
                                    UInt32 inDataSize,
                                    UInt32 *outDataSize,
                                    void *outData) {
    (void)inClientProcessID;
    if (!IsOurDriver(inDriver) || inAddress == NULL || outDataSize == NULL || outData == NULL) {
        return kAudioHardwareBadObjectError;
    }
    if (!ObjectExists(inObjectID)) return kAudioHardwareBadObjectError;

    OSStatus status = 0;

    switch (inAddress->mSelector) {
    case kAudioObjectPropertyBaseClass:
        YUN_GUARD(inDataSize >= sizeof(AudioClassID), kAudioHardwareBadPropertySizeError, done);
        if (inObjectID == kObjectID_Volume_Input_Master) {
            // The HAL walks the class hierarchy to decide what a control is;
            // a volume whose base class is not the level control is not found
            // by anything looking for a level control.
            *(AudioClassID *)outData = kAudioLevelControlClassID;
        } else if (inObjectID == kObjectID_Mute_Input_Master) {
            *(AudioClassID *)outData = kAudioBooleanControlClassID;
        } else {
            *(AudioClassID *)outData = kAudioObjectClassID;
        }
        *outDataSize = sizeof(AudioClassID);
        break;

    case kAudioObjectPropertyClass:
        YUN_GUARD(inDataSize >= sizeof(AudioClassID), kAudioHardwareBadPropertySizeError, done);
        if (inObjectID == kObjectID_PlugIn) {
            *(AudioClassID *)outData = kAudioPlugInClassID;
        } else if (inObjectID == kObjectID_Device) {
            *(AudioClassID *)outData = kAudioDeviceClassID;
        } else if (inObjectID == kObjectID_Volume_Input_Master) {
            *(AudioClassID *)outData = kAudioVolumeControlClassID;
        } else if (inObjectID == kObjectID_Mute_Input_Master) {
            *(AudioClassID *)outData = kAudioMuteControlClassID;
        } else {
            *(AudioClassID *)outData = kAudioStreamClassID;
        }
        *outDataSize = sizeof(AudioClassID);
        break;

    case kAudioObjectPropertyOwner:
        YUN_GUARD(inDataSize >= sizeof(AudioObjectID), kAudioHardwareBadPropertySizeError, done);
        if (inObjectID == kObjectID_PlugIn) {
            *(AudioObjectID *)outData = kAudioObjectUnknown;
        } else if (inObjectID == kObjectID_Device) {
            *(AudioObjectID *)outData = kObjectID_PlugIn;
        } else {
            *(AudioObjectID *)outData = kObjectID_Device;
        }
        *outDataSize = sizeof(AudioObjectID);
        break;

    case kAudioObjectPropertyManufacturer:
        YUN_GUARD(inDataSize >= sizeof(CFStringRef), kAudioHardwareBadPropertySizeError, done);
        *(CFStringRef *)outData = CFSTR(kDevice_Manufacturer);
        CFRetain(*(CFStringRef *)outData);
        *outDataSize = sizeof(CFStringRef);
        break;

    case kAudioObjectPropertyName:
        YUN_GUARD(inDataSize >= sizeof(CFStringRef), kAudioHardwareBadPropertySizeError, done);
        if (inObjectID == kObjectID_Device) {
            *(CFStringRef *)outData = CFSTR(kDevice_Name);
        } else if (inObjectID == kObjectID_Stream_Input) {
            *(CFStringRef *)outData = CFSTR(kDevice_Name " Input");
        } else if (inObjectID == kObjectID_Stream_Output) {
            *(CFStringRef *)outData = CFSTR(kDevice_Name " Output");
        } else {
            *(CFStringRef *)outData = CFSTR(kDevice_Name);
        }
        CFRetain(*(CFStringRef *)outData);
        *outDataSize = sizeof(CFStringRef);
        break;

    case kAudioObjectPropertyModelName:
        YUN_GUARD(inDataSize >= sizeof(CFStringRef), kAudioHardwareBadPropertySizeError, done);
        *(CFStringRef *)outData = CFSTR(kDevice_Name);
        CFRetain(*(CFStringRef *)outData);
        *outDataSize = sizeof(CFStringRef);
        break;

    case kAudioObjectPropertyOwnedObjects: {
        AudioObjectID *ids = (AudioObjectID *)outData;
        UInt32 capacity = inDataSize / sizeof(AudioObjectID);
        UInt32 written = 0;
        if (inObjectID == kObjectID_PlugIn) {
            if (capacity > written) ids[written++] = kObjectID_Device;
        } else if (inObjectID == kObjectID_Device) {
            if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
                if (capacity > written) ids[written++] = kObjectID_Stream_Input;
                if (capacity > written) ids[written++] = kObjectID_Volume_Input_Master;
                if (capacity > written) ids[written++] = kObjectID_Mute_Input_Master;
            } else if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                if (capacity > written) ids[written++] = kObjectID_Stream_Output;
            } else {
                if (capacity > written) ids[written++] = kObjectID_Stream_Input;
                if (capacity > written) ids[written++] = kObjectID_Stream_Output;
                if (capacity > written) ids[written++] = kObjectID_Volume_Input_Master;
                if (capacity > written) ids[written++] = kObjectID_Mute_Input_Master;
            }
        }
        *outDataSize = written * sizeof(AudioObjectID);
        break;
    }

    case kAudioPlugInPropertyBoxList:
        *outDataSize = 0;
        break;

    case kAudioObjectPropertyControlList: {
        YUN_GUARD(inDataSize >= 2 * sizeof(AudioObjectID),
                  kAudioHardwareBadPropertySizeError, done);
        AudioObjectID *controls = (AudioObjectID *)outData;
        controls[0] = kObjectID_Volume_Input_Master;
        controls[1] = kObjectID_Mute_Input_Master;
        *outDataSize = 2 * sizeof(AudioObjectID);
        break;
    }

    case kAudioControlPropertyScope:
        YUN_GUARD(inDataSize >= sizeof(AudioObjectPropertyScope),
                  kAudioHardwareBadPropertySizeError, done);
        *(AudioObjectPropertyScope *)outData = kAudioObjectPropertyScopeInput;
        *outDataSize = sizeof(AudioObjectPropertyScope);
        break;

    case kAudioControlPropertyElement:
        YUN_GUARD(inDataSize >= sizeof(AudioObjectPropertyElement),
                  kAudioHardwareBadPropertySizeError, done);
        *(AudioObjectPropertyElement *)outData = kAudioObjectPropertyElementMain;
        *outDataSize = sizeof(AudioObjectPropertyElement);
        break;

    case kAudioLevelControlPropertyScalarValue:
        YUN_GUARD(inDataSize >= sizeof(Float32), kAudioHardwareBadPropertySizeError, done);
        pthread_mutex_lock(&gDriver.stateMutex);
        *(Float32 *)outData = gDriver.inputVolume;
        pthread_mutex_unlock(&gDriver.stateMutex);
        *outDataSize = sizeof(Float32);
        break;

    case kAudioLevelControlPropertyDecibelValue:
        YUN_GUARD(inDataSize >= sizeof(Float32), kAudioHardwareBadPropertySizeError, done);
        pthread_mutex_lock(&gDriver.stateMutex);
        *(Float32 *)outData = ScalarToDecibels(gDriver.inputVolume);
        pthread_mutex_unlock(&gDriver.stateMutex);
        *outDataSize = sizeof(Float32);
        break;

    case kAudioLevelControlPropertyDecibelRange: {
        YUN_GUARD(inDataSize >= sizeof(AudioValueRange),
                  kAudioHardwareBadPropertySizeError, done);
        AudioValueRange *range = (AudioValueRange *)outData;
        range->mMinimum = kVolume_MinimumDecibels;
        range->mMaximum = kVolume_MaximumDecibels;
        *outDataSize = sizeof(AudioValueRange);
        break;
    }

    case kAudioLevelControlPropertyConvertScalarToDecibels:
        YUN_GUARD(inDataSize >= sizeof(Float32), kAudioHardwareBadPropertySizeError, done);
        *(Float32 *)outData = ScalarToDecibels(*(Float32 *)outData);
        *outDataSize = sizeof(Float32);
        break;

    case kAudioLevelControlPropertyConvertDecibelsToScalar:
        YUN_GUARD(inDataSize >= sizeof(Float32), kAudioHardwareBadPropertySizeError, done);
        *(Float32 *)outData = DecibelsToScalar(*(Float32 *)outData);
        *outDataSize = sizeof(Float32);
        break;

    case kAudioBooleanControlPropertyValue:
        YUN_GUARD(inDataSize >= sizeof(UInt32), kAudioHardwareBadPropertySizeError, done);
        pthread_mutex_lock(&gDriver.stateMutex);
        *(UInt32 *)outData = gDriver.inputMuted ? 1 : 0;
        pthread_mutex_unlock(&gDriver.stateMutex);
        *outDataSize = sizeof(UInt32);
        break;

    case kAudioObjectPropertyCustomPropertyInfoList: {
        YUN_GUARD(inDataSize >= sizeof(AudioServerPlugInCustomPropertyInfo),
                  kAudioHardwareBadPropertySizeError, done);
        AudioServerPlugInCustomPropertyInfo *info =
            (AudioServerPlugInCustomPropertyInfo *)outData;
        info[0].mSelector = kYunCustomProperty_ClockAnchor;
        info[0].mPropertyDataType = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;
        info[0].mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
        *outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);
        break;
    }

    case kYunCustomProperty_ClockAnchor: {
        // Reading reports what the clock is actually doing, so the application
        // can show an honest "locked" indicator instead of assuming its own
        // writes took effect.
        YUN_GUARD(inDataSize >= sizeof(CFPropertyListRef),
                  kAudioHardwareBadPropertySizeError, done);

        pthread_mutex_lock(&gDriver.stateMutex);
        ExpireClockAnchorIfStale_Locked();
        Float64 following = gDriver.isClockFollowing ? 1.0 : 0.0;
        Float64 ticksPerFrame = gDriver.hostTicksPerFrame;
        Float64 nominalTicks = gDriver.nominalTicksPerFrame;
        pthread_mutex_unlock(&gDriver.stateMutex);

        // Ratio of actual to nominal: 1.0 means the master is running at its
        // stated rate, 1.00002 means twenty parts per million fast.
        Float64 ratio = (nominalTicks > 0.0) ? (ticksPerFrame / nominalTicks) : 1.0;

        CFMutableDictionaryRef result = CFDictionaryCreateMutable(
            NULL, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (result == NULL) {
            status = kAudioHardwareUnspecifiedError;
            goto done;
        }
        CFNumberRef followingNumber = CFNumberCreate(NULL, kCFNumberDoubleType, &following);
        CFNumberRef ratioNumber = CFNumberCreate(NULL, kCFNumberDoubleType, &ratio);
        CFDictionarySetValue(result, CFSTR("following"), followingNumber);
        CFDictionarySetValue(result, CFSTR("rateRatio"), ratioNumber);
        CFRelease(followingNumber);
        CFRelease(ratioNumber);

        *(CFPropertyListRef *)outData = result;
        *outDataSize = sizeof(CFPropertyListRef);
        break;
    }

    case kAudioPlugInPropertyDeviceList:
    case kAudioDevicePropertyRelatedDevices: {
        AudioObjectID *ids = (AudioObjectID *)outData;
        UInt32 written = 0;
        if (inDataSize >= sizeof(AudioObjectID)) {
            ids[written++] = kObjectID_Device;
        }
        *outDataSize = written * sizeof(AudioObjectID);
        break;
    }

    case kAudioPlugInPropertyTranslateUIDToDevice: {
        YUN_GUARD(inQualifierDataSize == sizeof(CFStringRef),
                  kAudioHardwareBadPropertySizeError, done);
        YUN_GUARD(inDataSize >= sizeof(AudioObjectID), kAudioHardwareBadPropertySizeError, done);
        CFStringRef uid = *(const CFStringRef *)inQualifierData;
        *(AudioObjectID *)outData =
            (uid != NULL && CFStringCompare(uid, CFSTR(kDevice_UID), 0) == kCFCompareEqualTo)
                ? kObjectID_Device : kAudioObjectUnknown;
        *outDataSize = sizeof(AudioObjectID);
        break;
    }

    case kAudioPlugInPropertyResourceBundle:
        YUN_GUARD(inDataSize >= sizeof(CFStringRef), kAudioHardwareBadPropertySizeError, done);
        // Empty string means "the plug-in bundle itself".
        *(CFStringRef *)outData = CFSTR("");
        CFRetain(*(CFStringRef *)outData);
        *outDataSize = sizeof(CFStringRef);
        break;

    case kAudioDevicePropertyDeviceUID:
        YUN_GUARD(inDataSize >= sizeof(CFStringRef), kAudioHardwareBadPropertySizeError, done);
        *(CFStringRef *)outData = CFSTR(kDevice_UID);
        CFRetain(*(CFStringRef *)outData);
        *outDataSize = sizeof(CFStringRef);
        break;

    case kAudioDevicePropertyModelUID:
        YUN_GUARD(inDataSize >= sizeof(CFStringRef), kAudioHardwareBadPropertySizeError, done);
        *(CFStringRef *)outData = CFSTR(kDevice_ModelUID);
        CFRetain(*(CFStringRef *)outData);
        *outDataSize = sizeof(CFStringRef);
        break;

    case kAudioDevicePropertyTransportType:
        YUN_GUARD(inDataSize >= sizeof(UInt32), kAudioHardwareBadPropertySizeError, done);
        *(UInt32 *)outData = kAudioDeviceTransportTypeVirtual;
        *outDataSize = sizeof(UInt32);
        break;

    case kAudioDevicePropertyClockDomain:
        YUN_GUARD(inDataSize >= sizeof(UInt32), kAudioHardwareBadPropertySizeError, done);
        // Zero means "no shared domain". Once clock following is active this
        // will report the master's domain so the HAL can skip drift correction.
        *(UInt32 *)outData = 0;
        *outDataSize = sizeof(UInt32);
        break;

    case kAudioDevicePropertyDeviceIsAlive:
        YUN_GUARD(inDataSize >= sizeof(UInt32), kAudioHardwareBadPropertySizeError, done);
        *(UInt32 *)outData = 1;
        *outDataSize = sizeof(UInt32);
        break;

    case kAudioDevicePropertyDeviceIsRunning:
        YUN_GUARD(inDataSize >= sizeof(UInt32), kAudioHardwareBadPropertySizeError, done);
        pthread_mutex_lock(&gDriver.stateMutex);
        *(UInt32 *)outData = gDriver.ioRunningCount > 0 ? 1 : 0;
        pthread_mutex_unlock(&gDriver.stateMutex);
        *outDataSize = sizeof(UInt32);
        break;

    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        YUN_GUARD(inDataSize >= sizeof(UInt32), kAudioHardwareBadPropertySizeError, done);
        *(UInt32 *)outData = 1;
        *outDataSize = sizeof(UInt32);
        break;

    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        YUN_GUARD(inDataSize >= sizeof(UInt32), kAudioHardwareBadPropertySizeError, done);
        // Keeping alerts and system sounds out of a routing endpoint by
        // default: nobody wants a notification chime in their stream mix.
        *(UInt32 *)outData = 0;
        *outDataSize = sizeof(UInt32);
        break;

    case kAudioDevicePropertyLatency:  // == kAudioStreamPropertyLatency
        YUN_GUARD(inDataSize >= sizeof(UInt32), kAudioHardwareBadPropertySizeError, done);
        *(UInt32 *)outData = 0;
        *outDataSize = sizeof(UInt32);
        break;

    case kAudioDevicePropertySafetyOffset:
        YUN_GUARD(inDataSize >= sizeof(UInt32), kAudioHardwareBadPropertySizeError, done);
        *(UInt32 *)outData = 0;
        *outDataSize = sizeof(UInt32);
        break;

    case kAudioDevicePropertyIsHidden:
        YUN_GUARD(inDataSize >= sizeof(UInt32), kAudioHardwareBadPropertySizeError, done);
        *(UInt32 *)outData = 0;
        *outDataSize = sizeof(UInt32);
        break;

    case kAudioDevicePropertyZeroTimeStampPeriod:
        YUN_GUARD(inDataSize >= sizeof(UInt32), kAudioHardwareBadPropertySizeError, done);
        *(UInt32 *)outData = kRingBufferFrames;
        *outDataSize = sizeof(UInt32);
        break;

    case kAudioDevicePropertyNominalSampleRate:
        YUN_GUARD(inDataSize >= sizeof(Float64), kAudioHardwareBadPropertySizeError, done);
        pthread_mutex_lock(&gDriver.stateMutex);
        *(Float64 *)outData = gDriver.sampleRate;
        pthread_mutex_unlock(&gDriver.stateMutex);
        *outDataSize = sizeof(Float64);
        break;

    case kAudioDevicePropertyAvailableNominalSampleRates: {
        AudioValueRange *ranges = (AudioValueRange *)outData;
        UInt32 capacity = inDataSize / sizeof(AudioValueRange);
        UInt32 written = 0;
        for (UInt32 index = 0; index < kSupportedSampleRateCount && written < capacity; ++index) {
            ranges[written].mMinimum = kSupportedSampleRates[index];
            ranges[written].mMaximum = kSupportedSampleRates[index];
            ++written;
        }
        *outDataSize = written * sizeof(AudioValueRange);
        break;
    }

    case kAudioDevicePropertyPreferredChannelsForStereo: {
        YUN_GUARD(inDataSize >= 2 * sizeof(UInt32), kAudioHardwareBadPropertySizeError, done);
        UInt32 *pair = (UInt32 *)outData;
        pair[0] = 1;
        pair[1] = 2;
        *outDataSize = 2 * sizeof(UInt32);
        break;
    }

    case kAudioDevicePropertyPreferredChannelLayout: {
        UInt32 required = offsetof(AudioChannelLayout, mChannelDescriptions)
            + (kDevice_ChannelCount * sizeof(AudioChannelDescription));
        YUN_GUARD(inDataSize >= required, kAudioHardwareBadPropertySizeError, done);
        AudioChannelLayout *layout = (AudioChannelLayout *)outData;
        memset(layout, 0, required);
        layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
        layout->mNumberChannelDescriptions = kDevice_ChannelCount;
        layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
        layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
        *outDataSize = required;
        break;
    }

    case kAudioDevicePropertyStreams: {
        AudioObjectID *ids = (AudioObjectID *)outData;
        UInt32 capacity = inDataSize / sizeof(AudioObjectID);
        UInt32 written = 0;
        if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
            if (capacity > written) ids[written++] = kObjectID_Stream_Input;
        } else if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
            if (capacity > written) ids[written++] = kObjectID_Stream_Output;
        } else {
            if (capacity > written) ids[written++] = kObjectID_Stream_Input;
            if (capacity > written) ids[written++] = kObjectID_Stream_Output;
        }
        *outDataSize = written * sizeof(AudioObjectID);
        break;
    }

    case kAudioStreamPropertyIsActive:
        YUN_GUARD(inDataSize >= sizeof(UInt32), kAudioHardwareBadPropertySizeError, done);
        *(UInt32 *)outData = 1;
        *outDataSize = sizeof(UInt32);
        break;

    case kAudioStreamPropertyDirection:
        YUN_GUARD(inDataSize >= sizeof(UInt32), kAudioHardwareBadPropertySizeError, done);
        *(UInt32 *)outData = StreamIsInput(inObjectID) ? 1 : 0;
        *outDataSize = sizeof(UInt32);
        break;

    case kAudioStreamPropertyTerminalType:
        YUN_GUARD(inDataSize >= sizeof(UInt32), kAudioHardwareBadPropertySizeError, done);
        *(UInt32 *)outData = StreamIsInput(inObjectID)
            ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
        *outDataSize = sizeof(UInt32);
        break;

    case kAudioStreamPropertyStartingChannel:
        YUN_GUARD(inDataSize >= sizeof(UInt32), kAudioHardwareBadPropertySizeError, done);
        *(UInt32 *)outData = 1;
        *outDataSize = sizeof(UInt32);
        break;

    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: {
        YUN_GUARD(inDataSize >= sizeof(AudioStreamBasicDescription),
                  kAudioHardwareBadPropertySizeError, done);
        pthread_mutex_lock(&gDriver.stateMutex);
        Float64 rate = gDriver.sampleRate;
        pthread_mutex_unlock(&gDriver.stateMutex);
        FillStreamDescription((AudioStreamBasicDescription *)outData, rate);
        *outDataSize = sizeof(AudioStreamBasicDescription);
        break;
    }

    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription *formats = (AudioStreamRangedDescription *)outData;
        UInt32 capacity = inDataSize / sizeof(AudioStreamRangedDescription);
        UInt32 written = 0;
        for (UInt32 index = 0; index < kSupportedSampleRateCount && written < capacity; ++index) {
            memset(&formats[written], 0, sizeof(AudioStreamRangedDescription));
            FillStreamDescription(&formats[written].mFormat, kSupportedSampleRates[index]);
            formats[written].mSampleRateRange.mMinimum = kSupportedSampleRates[index];
            formats[written].mSampleRateRange.mMaximum = kSupportedSampleRates[index];
            ++written;
        }
        *outDataSize = written * sizeof(AudioStreamRangedDescription);
        break;
    }

    default:
        status = kAudioHardwareUnknownPropertyError;
        break;
    }

done:
    return status;
}

static OSStatus Yun_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inObjectID,
                                    pid_t inClientProcessID,
                                    const AudioObjectPropertyAddress *inAddress,
                                    UInt32 inQualifierDataSize,
                                    const void *inQualifierData,
                                    UInt32 inDataSize,
                                    const void *inData) {
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (!IsOurDriver(inDriver) || inAddress == NULL || inData == NULL) {
        return kAudioHardwareBadObjectError;
    }
    if (!ObjectExists(inObjectID)) return kAudioHardwareBadObjectError;

    switch (inAddress->mSelector) {
    case kAudioLevelControlPropertyScalarValue:
    case kAudioLevelControlPropertyDecibelValue: {
        if (inObjectID != kObjectID_Volume_Input_Master) {
            return kAudioHardwareUnknownPropertyError;
        }
        if (inDataSize != sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
        Float32 scalar =
            (inAddress->mSelector == kAudioLevelControlPropertyScalarValue)
                ? *(const Float32 *)inData
                : DecibelsToScalar(*(const Float32 *)inData);
        if (scalar < 0.0f) scalar = 0.0f;
        if (scalar > 1.0f) scalar = 1.0f;

        pthread_mutex_lock(&gDriver.stateMutex);
        bool changed = (scalar != gDriver.inputVolume);
        gDriver.inputVolume = scalar;
        // Recomputed here rather than on the IO thread, which must not call
        // powf or take this lock.
        gDriver.inputGain = ScalarToGain(scalar);
        AudioServerPlugInHostRef host = gDriver.host;
        pthread_mutex_unlock(&gDriver.stateMutex);

        // Both representations move together, so both have to be announced or
        // whichever one the observer watches goes stale.
        if (changed && host != NULL) {
            AudioObjectPropertyAddress changes[2] = {
                { kAudioLevelControlPropertyScalarValue,
                  kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                { kAudioLevelControlPropertyDecibelValue,
                  kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
            };
            host->PropertiesChanged(host, kObjectID_Volume_Input_Master, 2, changes);
        }
        return 0;
    }

    case kAudioBooleanControlPropertyValue: {
        if (inObjectID != kObjectID_Mute_Input_Master) {
            return kAudioHardwareUnknownPropertyError;
        }
        if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        bool muted = (*(const UInt32 *)inData != 0);

        pthread_mutex_lock(&gDriver.stateMutex);
        bool changed = (muted != gDriver.inputMuted);
        gDriver.inputMuted = muted;
        AudioServerPlugInHostRef host = gDriver.host;
        pthread_mutex_unlock(&gDriver.stateMutex);

        if (changed && host != NULL) {
            AudioObjectPropertyAddress change = {
                kAudioBooleanControlPropertyValue,
                kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
            };
            host->PropertiesChanged(host, kObjectID_Mute_Input_Master, 1, &change);
        }
        return 0;
    }

    case kAudioDevicePropertyNominalSampleRate: {
        if (inObjectID != kObjectID_Device) return kAudioHardwareUnknownPropertyError;
        if (inDataSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        Float64 requested = *(const Float64 *)inData;
        if (!IsSupportedSampleRate(requested)) return kAudioHardwareIllegalOperationError;

        pthread_mutex_lock(&gDriver.stateMutex);
        bool changed = (requested != gDriver.sampleRate);
        if (changed) gDriver.pendingSampleRate = requested;
        AudioServerPlugInHostRef host = gDriver.host;
        pthread_mutex_unlock(&gDriver.stateMutex);

        // A rate change alters the IO structure, so it has to go through the
        // host: it stops outstanding IO, calls us back, then restarts.
        if (changed && host != NULL) {
            host->RequestDeviceConfigurationChange(host, kObjectID_Device,
                                                   (UInt64)requested, NULL);
        }
        return 0;
    }

    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: {
        if (inObjectID != kObjectID_Stream_Input && inObjectID != kObjectID_Stream_Output) {
            return kAudioHardwareUnknownPropertyError;
        }
        if (inDataSize != sizeof(AudioStreamBasicDescription)) {
            return kAudioHardwareBadPropertySizeError;
        }
        const AudioStreamBasicDescription *format = (const AudioStreamBasicDescription *)inData;
        if (format->mFormatID != kAudioFormatLinearPCM
            || format->mChannelsPerFrame != kDevice_ChannelCount
            || format->mBitsPerChannel != 32
            || !(format->mFormatFlags & kAudioFormatFlagIsFloat)
            || !IsSupportedSampleRate(format->mSampleRate)) {
            return kAudioDeviceUnsupportedFormatError;
        }

        pthread_mutex_lock(&gDriver.stateMutex);
        bool changed = (format->mSampleRate != gDriver.sampleRate);
        if (changed) gDriver.pendingSampleRate = format->mSampleRate;
        AudioServerPlugInHostRef host = gDriver.host;
        pthread_mutex_unlock(&gDriver.stateMutex);

        if (changed && host != NULL) {
            host->RequestDeviceConfigurationChange(host, kObjectID_Device,
                                                   (UInt64)format->mSampleRate, NULL);
        }
        return 0;
    }

    case kAudioStreamPropertyIsActive:
        // Both streams are always active; accept the write so clients that set
        // it unconditionally do not see an error.
        return 0;

    case kYunCustomProperty_ClockAnchor: {
        if (inObjectID != kObjectID_Device) return kAudioHardwareUnknownPropertyError;
        if (inDataSize != sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;

        CFPropertyListRef payload = *(const CFPropertyListRef *)inData;
        Float64 sampleTime = 0.0;
        Float64 sampleRate = 0.0;
        UInt64 hostTime = 0;
        if (!ReadAnchorDictionary((CFDictionaryRef)payload,
                                  &sampleTime, &hostTime, &sampleRate)) {
            return kAudioHardwareIllegalOperationError;
        }

        pthread_mutex_lock(&gDriver.stateMutex);
        ApplyClockAnchor_Locked(sampleTime, hostTime, sampleRate);
        pthread_mutex_unlock(&gDriver.stateMutex);
        return 0;
    }

    default:
        return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - IO

static OSStatus Yun_StartIO(AudioServerPlugInDriverRef inDriver,
                            AudioObjectID inDeviceObjectID,
                            UInt32 inClientID) {
    (void)inClientID;
    if (!IsOurDriver(inDriver)) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gDriver.stateMutex);
    if (gDriver.ioRunningCount == 0) {
        // First client in: reset the timestamp series and clear stale audio.
        gDriver.timeStampCount = 0;
        gDriver.anchorHostTime = mach_absolute_time();
        RefreshTimebase_Locked();
        if (gDriver.ringBuffer != NULL) {
            memset(gDriver.ringBuffer, 0,
                   (size_t)kRingBufferFrames * kDevice_ChannelCount * sizeof(Float32));
        }
    }
    ++gDriver.ioRunningCount;
    pthread_mutex_unlock(&gDriver.stateMutex);
    return 0;
}

static OSStatus Yun_StopIO(AudioServerPlugInDriverRef inDriver,
                           AudioObjectID inDeviceObjectID,
                           UInt32 inClientID) {
    (void)inClientID;
    if (!IsOurDriver(inDriver)) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gDriver.stateMutex);
    if (gDriver.ioRunningCount > 0) --gDriver.ioRunningCount;
    pthread_mutex_unlock(&gDriver.stateMutex);
    return 0;
}

/// Publishes the mapping between the device's sample time and host time.
///
/// The host interpolates between these anchors to schedule every IO cycle, so
/// this function *is* the device's clock. Today it advances on the host clock,
/// one ring buffer per period. Once the application publishes a clock anchor
/// taken from the physical microphone, this follows that instead, which locks
/// the two devices together and removes the need for drift correction.
static OSStatus Yun_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                     AudioObjectID inDeviceObjectID,
                                     UInt32 inClientID,
                                     Float64 *outSampleTime,
                                     UInt64 *outHostTime,
                                     UInt64 *outSeed) {
    (void)inClientID;
    if (!IsOurDriver(inDriver)) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    pthread_mutex_lock(&gDriver.stateMutex);

    // If the application stopped publishing anchors, stop trusting the last
    // measured rate before it is used to emit another timestamp.
    ExpireClockAnchorIfStale_Locked();

    Float64 ticksPerRing = gDriver.hostTicksPerFrame * (Float64)kRingBufferFrames;
    UInt64 now = mach_absolute_time();
    UInt64 nextAnchor = gDriver.anchorHostTime
        + (UInt64)(((Float64)gDriver.timeStampCount + 1.0) * ticksPerRing);
    if (now >= nextAnchor) {
        ++gDriver.timeStampCount;
    }

    *outSampleTime = (Float64)gDriver.timeStampCount * (Float64)kRingBufferFrames;
    *outHostTime = gDriver.anchorHostTime
        + (UInt64)((Float64)gDriver.timeStampCount * ticksPerRing);
    *outSeed = 1;

    pthread_mutex_unlock(&gDriver.stateMutex);
    return 0;
}

static OSStatus Yun_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inDeviceObjectID,
                                      UInt32 inClientID,
                                      UInt32 inOperationID,
                                      Boolean *outWillDo,
                                      Boolean *outWillDoInPlace) {
    (void)inClientID;
    if (!IsOurDriver(inDriver)) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (outWillDo == NULL || outWillDoInPlace == NULL) return kAudioHardwareIllegalOperationError;

    // Only the two ends of the loopback are interesting: read the ring into the
    // input stream, write the client mix into the ring.
    switch (inOperationID) {
    case kAudioServerPlugInIOOperationReadInput:
    case kAudioServerPlugInIOOperationWriteMix:
        *outWillDo = true;
        *outWillDoInPlace = true;
        break;
    default:
        *outWillDo = false;
        *outWillDoInPlace = true;
        break;
    }
    return 0;
}

static OSStatus Yun_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                     AudioObjectID inDeviceObjectID,
                                     UInt32 inClientID,
                                     UInt32 inOperationID,
                                     UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (!IsOurDriver(inDriver)) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}

/// The loopback itself. Runs on a realtime thread with a deadline: no locks, no
/// allocation, no logging.
static OSStatus Yun_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                  AudioObjectID inDeviceObjectID,
                                  AudioObjectID inStreamObjectID,
                                  UInt32 inClientID,
                                  UInt32 inOperationID,
                                  UInt32 inIOBufferFrameSize,
                                  const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                                  void *ioMainBuffer,
                                  void *ioSecondaryBuffer) {
    (void)inStreamObjectID; (void)inClientID; (void)ioSecondaryBuffer;
    if (!IsOurDriver(inDriver)) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    Float32 *ring = gDriver.ringBuffer;
    if (ring == NULL || ioMainBuffer == NULL) return 0;

    Float32 *buffer = (Float32 *)ioMainBuffer;

    if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        // Read without the lock: both are single scalars written by the control
        // thread, and taking a mutex here would be the one thing this whole
        // project exists to avoid. A cycle either side of a slider move is the
        // worst case, and a slider move is not a sample-accurate event.
        Float32 gain = gDriver.inputMuted ? 0.0f : gDriver.inputGain;

        UInt64 startFrame = (UInt64)inIOCycleInfo->mInputTime.mSampleTime;
        if (gain == 1.0f) {
            // Unity is the ordinary case and has to stay exactly untouched:
            // multiplying by 1.0f is arithmetic, and this device's claim is
            // that it does none.
            for (UInt32 frame = 0; frame < inIOBufferFrameSize; ++frame) {
                UInt64 slot = (startFrame + frame) & kRingBufferMask;
                for (UInt32 channel = 0; channel < kDevice_ChannelCount; ++channel) {
                    buffer[frame * kDevice_ChannelCount + channel] =
                        ring[slot * kDevice_ChannelCount + channel];
                }
            }
        } else {
            for (UInt32 frame = 0; frame < inIOBufferFrameSize; ++frame) {
                UInt64 slot = (startFrame + frame) & kRingBufferMask;
                for (UInt32 channel = 0; channel < kDevice_ChannelCount; ++channel) {
                    buffer[frame * kDevice_ChannelCount + channel] =
                        ring[slot * kDevice_ChannelCount + channel] * gain;
                }
            }
        }
        return 0;
    }

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        UInt64 startFrame = (UInt64)inIOCycleInfo->mOutputTime.mSampleTime;
        for (UInt32 frame = 0; frame < inIOBufferFrameSize; ++frame) {
            UInt64 slot = (startFrame + frame) & kRingBufferMask;
            for (UInt32 channel = 0; channel < kDevice_ChannelCount; ++channel) {
                ring[slot * kDevice_ChannelCount + channel] =
                    buffer[frame * kDevice_ChannelCount + channel];
            }
        }
        return 0;
    }

    return 0;
}

static OSStatus Yun_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inDeviceObjectID,
                                   UInt32 inClientID,
                                   UInt32 inOperationID,
                                   UInt32 inIOBufferFrameSize,
                                   const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (!IsOurDriver(inDriver)) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}

#pragma mark - Factory

static AudioServerPlugInDriverInterface gInterface = {
    .QueryInterface = Yun_QueryInterface,
    .AddRef = Yun_AddRef,
    .Release = Yun_Release,
    .Initialize = Yun_Initialize,
    .CreateDevice = Yun_CreateDevice,
    .DestroyDevice = Yun_DestroyDevice,
    .AddDeviceClient = Yun_AddDeviceClient,
    .RemoveDeviceClient = Yun_RemoveDeviceClient,
    .PerformDeviceConfigurationChange = Yun_PerformDeviceConfigurationChange,
    .AbortDeviceConfigurationChange = Yun_AbortDeviceConfigurationChange,
    .HasProperty = Yun_HasProperty,
    .IsPropertySettable = Yun_IsPropertySettable,
    .GetPropertyDataSize = Yun_GetPropertyDataSize,
    .GetPropertyData = Yun_GetPropertyData,
    .SetPropertyData = Yun_SetPropertyData,
    .StartIO = Yun_StartIO,
    .StopIO = Yun_StopIO,
    .GetZeroTimeStamp = Yun_GetZeroTimeStamp,
    .WillDoIOOperation = Yun_WillDoIOOperation,
    .BeginIOOperation = Yun_BeginIOOperation,
    .DoIOOperation = Yun_DoIOOperation,
    .EndIOOperation = Yun_EndIOOperation,
};

/// CFPlugIn entry point, named in the bundle's Info.plist.
///
/// Explicitly exported: the bundle is compiled with -fvisibility=hidden so that
/// nothing else leaks into coreaudiod's symbol space, and CFPlugIn resolves
/// this one by name at load time.
__attribute__((visibility("default")))
void *YunAudioDriverFactory(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);

__attribute__((visibility("default")))
void *YunAudioDriverFactory(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (inRequestedTypeUUID == NULL) return NULL;
    if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    return &gInterfacePtr;
}
