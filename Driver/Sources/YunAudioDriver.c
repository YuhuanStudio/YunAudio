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
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#pragma mark - Globals

YunDriverState gDriver = {
    .stateMutex = PTHREAD_MUTEX_INITIALIZER,
    .configurationRequestMutex = PTHREAD_MUTEX_INITIALIZER,
    .sampleRate = kDevice_DefaultSampleRate,
    .pendingSampleRate = 0.0,
    .configurationLifetimeGeneration = 1,
    .inputStreamIsActive = true,
    .outputStreamIsActive = true,
    .inputVolume = 1.0f,
    .outputVolume = 1.0f,
    .inputGainBits = 0x3F800000,
    .outputGainBits = 0x3F800000,
    .firstPublishedFrame = UINT64_MAX,
    .hostTicksPerFrame = 0.0,
    .clockSeed = 1,
};

static AudioServerPlugInDriverInterface gInterface;
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;

#if defined(YUNAUDIO_DRIVER_TESTING)
typedef void (*YunDriverIOTestHook)(bool entering,
                                    UInt32 clientID,
                                    UInt32 operationID);
static YunDriverIOTestHook gYunDriverIOTestHook;
#define YUN_DRIVER_IO_TEST_HOOK(entering, clientID, operationID) \
    do {                                                        \
        if (gYunDriverIOTestHook != NULL) {                      \
            gYunDriverIOTestHook((entering), (clientID), (operationID)); \
        }                                                       \
    } while (0)
#else
#define YUN_DRIVER_IO_TEST_HOOK(entering, clientID, operationID) \
    do {                                                        \
        (void)(entering);                                       \
        (void)(clientID);                                       \
        (void)(operationID);                                    \
    } while (0)
#endif

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

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "UInt32 atomics must be lock-free on the IO thread");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2,
               "UInt64 atomics must be lock-free on realtime threads");
_Static_assert(2 * sizeof(Float32) == sizeof(UInt64),
               "A stereo frame must fit in one lock-free atomic word");
_Static_assert((kRingBufferFrames & kRingBufferMask) == 0,
               "The ring size must remain a power of two");

#define YUN_GUARD(condition, error, label) \
    if (!(condition)) {                    \
        status = (error);                  \
        goto label;                        \
    }

#pragma mark - Helpers

static UInt32 Float32Bits(Float32 value) {
    UInt32 bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static Float32 Float32FromBits(UInt32 bits) {
    Float32 value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static UInt64 PackStereoFrame(const Float32 *samples) {
    UInt64 bits;
    memcpy(&bits, samples, sizeof(bits));
    return bits;
}

static void UnpackStereoFrame(UInt64 bits, Float32 *samples) {
    memcpy(samples, &bits, sizeof(bits));
}

/// UINT64_MAX cannot be an exact accepted Float64 sample time, so it is an
/// unambiguous unpublished state even at the edge of the accepted timeline.
static const UInt64 kRingFrameUnpublished = UINT64_MAX;

static YunRingFrame *CreateRingBuffer(void) {
    YunRingFrame *ring = calloc(kRingBufferFrames, sizeof(*ring));
    if (ring == NULL) return NULL;
    for (UInt32 frame = 0; frame < kRingBufferFrames; ++frame) {
        atomic_init(&ring[frame].owner, 0);
        atomic_init(&ring[frame].sampleFrame, kRingFrameUnpublished);
        atomic_init(&ring[frame].stereoBits, 0);
    }
    atomic_store_explicit(
        &gDriver.firstPublishedFrame, kRingFrameUnpublished,
        memory_order_seq_cst);
    atomic_store_explicit(
        &gDriver.unsafeReadEvidenceState, 0, memory_order_seq_cst);
    atomic_store_explicit(
        &gDriver.lastPublishedIdentity, 0, memory_order_seq_cst);
    return ring;
}

/// Called only across a host lifecycle boundary, never from DoIOOperation.
static void ResetRingBuffer(YunRingFrame *ring) {
    if (ring == NULL) return;
    for (UInt32 frame = 0; frame < kRingBufferFrames; ++frame) {
        atomic_store_explicit(&ring[frame].owner, 0, memory_order_seq_cst);
        atomic_store_explicit(
            &ring[frame].sampleFrame, kRingFrameUnpublished,
            memory_order_seq_cst);
        atomic_store_explicit(
            &ring[frame].stereoBits, 0, memory_order_seq_cst);
    }
    atomic_store_explicit(
        &gDriver.firstPublishedFrame, kRingFrameUnpublished,
        memory_order_seq_cst);
    atomic_store_explicit(
        &gDriver.unsafeReadEvidenceState, 0, memory_order_seq_cst);
    atomic_store_explicit(
        &gDriver.lastPublishedIdentity, 0, memory_order_seq_cst);
}

static UInt64 Float64Bits(Float64 value) {
    UInt64 bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static Float64 Float64FromBits(UInt64 bits) {
    Float64 value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

/// Returns every whole timestamp period that has elapsed, not merely one.
///
/// A delayed callback used to advance exactly once. At 48 kHz one period is
/// 2.731 seconds, so a ten-period scheduling delay left the published clock
/// nine periods behind and invited the host to poll repeatedly to catch up.
static UInt64 TimestampPeriodAtHostTime(UInt64 anchorHostTime,
                                        UInt64 hostTime,
                                        Float64 ticksPerPeriod) {
    if (hostTime <= anchorHostTime || !isfinite(ticksPerPeriod) || ticksPerPeriod <= 0.0) {
        return 0;
    }
    return (UInt64)((Float64)(hostTime - anchorHostTime) / ticksPerPeriod);
}

/// Rebases a slope at a host instant without changing its timestamp count.
static UInt64 RebasedAnchorHostTime(UInt64 anchorHostTime,
                                    Float64 oldTicksPerPeriod,
                                    Float64 newTicksPerPeriod,
                                    UInt64 rebaseHostTime) {
    if (!isfinite(oldTicksPerPeriod) || oldTicksPerPeriod <= 0.0
        || !isfinite(newTicksPerPeriod) || newTicksPerPeriod <= 0.0) {
        return anchorHostTime;
    }
    UInt64 period =
        TimestampPeriodAtHostTime(anchorHostTime, rebaseHostTime, oldTicksPerPeriod);
    Float64 currentHostTime =
        (Float64)anchorHostTime + (Float64)period * oldTicksPerPeriod;
    Float64 newOffset = (Float64)period * newTicksPerPeriod;
    return currentHostTime > newOffset ? (UInt64)(currentHostTime - newOffset) : 0;
}

typedef struct {
    UInt64 anchorHostTime;
    Float64 hostTicksPerFrame;
    Float64 nominalTicksPerFrame;
    UInt64 lastAnchorReceivedAt;
    UInt64 anchorTimeoutTicks;
    bool isClockFollowing;
    UInt64 seed;
} YunClockSnapshot;

static void PublishClockState_Locked(void) {
    atomic_fetch_add_explicit(&gDriver.publishedClock.version, 1, memory_order_acq_rel);
    atomic_store_explicit(&gDriver.publishedClock.anchorHostTime,
                          gDriver.anchorHostTime, memory_order_relaxed);
    atomic_store_explicit(&gDriver.publishedClock.hostTicksPerFrameBits,
                          Float64Bits(gDriver.hostTicksPerFrame), memory_order_relaxed);
    atomic_store_explicit(&gDriver.publishedClock.nominalTicksPerFrameBits,
                          Float64Bits(gDriver.nominalTicksPerFrame), memory_order_relaxed);
    atomic_store_explicit(&gDriver.publishedClock.lastAnchorReceivedAt,
                          gDriver.lastAnchorReceivedAt, memory_order_relaxed);
    atomic_store_explicit(&gDriver.publishedClock.anchorTimeoutTicks,
                          gDriver.anchorTimeoutTicks, memory_order_relaxed);
    atomic_store_explicit(&gDriver.publishedClock.isClockFollowing,
                          gDriver.isClockFollowing ? 1 : 0, memory_order_relaxed);
    atomic_store_explicit(&gDriver.publishedClock.seed,
                          gDriver.clockSeed, memory_order_relaxed);
    atomic_fetch_add_explicit(&gDriver.publishedClock.version, 1, memory_order_release);
}

/// Reads a coherent publication without ever waiting for the writer.
static YunClockSnapshot ReadPublishedClock(void) {
    YunClockSnapshot snapshot = { 0 };
    for (UInt32 attempt = 0; attempt < 3; ++attempt) {
        UInt64 before =
            atomic_load_explicit(&gDriver.publishedClock.version, memory_order_acquire);
        if ((before & 1) != 0) continue;

        snapshot.anchorHostTime = atomic_load_explicit(
            &gDriver.publishedClock.anchorHostTime, memory_order_relaxed);
        snapshot.hostTicksPerFrame = Float64FromBits(atomic_load_explicit(
            &gDriver.publishedClock.hostTicksPerFrameBits, memory_order_relaxed));
        snapshot.nominalTicksPerFrame = Float64FromBits(atomic_load_explicit(
            &gDriver.publishedClock.nominalTicksPerFrameBits, memory_order_relaxed));
        snapshot.lastAnchorReceivedAt = atomic_load_explicit(
            &gDriver.publishedClock.lastAnchorReceivedAt, memory_order_relaxed);
        snapshot.anchorTimeoutTicks = atomic_load_explicit(
            &gDriver.publishedClock.anchorTimeoutTicks, memory_order_relaxed);
        snapshot.isClockFollowing = atomic_load_explicit(
            &gDriver.publishedClock.isClockFollowing, memory_order_relaxed) != 0;
        snapshot.seed =
            atomic_load_explicit(&gDriver.publishedClock.seed, memory_order_relaxed);

        UInt64 after =
            atomic_load_explicit(&gDriver.publishedClock.version, memory_order_acquire);
        if (before == after) return snapshot;
    }

    // Property changes are rare and bounded. If all three reads overlap one,
    // a nominal snapshot is safer than either waiting or publishing a mixed
    // followed-clock slope. Every load remains a legal lock-free C access.
    snapshot.anchorHostTime = atomic_load_explicit(
        &gDriver.publishedClock.anchorHostTime, memory_order_relaxed);
    snapshot.nominalTicksPerFrame = Float64FromBits(atomic_load_explicit(
        &gDriver.publishedClock.nominalTicksPerFrameBits, memory_order_relaxed));
    snapshot.hostTicksPerFrame = snapshot.nominalTicksPerFrame;
    snapshot.seed = atomic_load_explicit(&gDriver.publishedClock.seed, memory_order_relaxed);
    return snapshot;
}

static void FillStreamDescription(AudioStreamBasicDescription *description, Float64 sampleRate) {
    description->mSampleRate = sampleRate;
    description->mFormatID = kAudioFormatLinearPCM;
    // The IO callback indexes one stereo frame at a time, so the advertised
    // format has to be exactly native-endian, packed and interleaved.
    description->mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    description->mBytesPerPacket = kDevice_ChannelCount * sizeof(Float32);
    description->mFramesPerPacket = 1;
    description->mBytesPerFrame = kDevice_ChannelCount * sizeof(Float32);
    description->mChannelsPerFrame = kDevice_ChannelCount;
    description->mBitsPerChannel = 32;
    description->mReserved = 0;
}

static bool IsSupportedSampleRate(Float64 rate) {
    if (!isfinite(rate)) return false;
    for (UInt32 index = 0; index < kSupportedSampleRateCount; ++index) {
        if (kSupportedSampleRates[index] == rate) return true;
    }
    return false;
}

static bool IsCanonicalStreamDescription(const AudioStreamBasicDescription *description) {
    if (description == NULL || !IsSupportedSampleRate(description->mSampleRate)) return false;

    AudioStreamBasicDescription expected;
    FillStreamDescription(&expected, description->mSampleRate);
    return description->mFormatID == expected.mFormatID
        && description->mFormatFlags == expected.mFormatFlags
        && description->mBytesPerPacket == expected.mBytesPerPacket
        && description->mFramesPerPacket == expected.mFramesPerPacket
        && description->mBytesPerFrame == expected.mBytesPerFrame
        && description->mChannelsPerFrame == expected.mChannelsPerFrame
        && description->mBitsPerChannel == expected.mBitsPerChannel
        && description->mReserved == expected.mReserved;
}

static UInt64 NextConfigurationGeneration_Locked(void) {
    if (++gDriver.nextConfigurationGeneration == 0) {
        ++gDriver.nextConfigurationGeneration;
    }
    return gDriver.nextConfigurationGeneration;
}

/// Asks the host to stop IO before a rate changes and records exactly which
/// deferred callback may commit it.
static OSStatus RequestSampleRateChange(Float64 requested) {
    bool publishDesiredRate = true;
    OSStatus callerStatus = 0;

    for (;;) {
        pthread_mutex_lock(&gDriver.configurationRequestMutex);
        pthread_mutex_lock(&gDriver.stateMutex);

        if (publishDesiredRate) {
            if (gDriver.sampleRate == requested
                && gDriver.pendingConfigurationGeneration == 0
                && gDriver.configurationRequestInFlightGeneration == 0) {
                pthread_mutex_unlock(&gDriver.stateMutex);
                pthread_mutex_unlock(&gDriver.configurationRequestMutex);
                return 0;
            }
            // One action means "stop IO and apply the latest desired format",
            // not "commit the value captured when the request began".
            gDriver.pendingSampleRate = requested;
            publishDesiredRate = false;
        }

        if (gDriver.pendingConfigurationGeneration != 0
            || gDriver.configurationRequestInFlightGeneration != 0) {
            pthread_mutex_unlock(&gDriver.stateMutex);
            pthread_mutex_unlock(&gDriver.configurationRequestMutex);
            return callerStatus;
        }
        if (!IsSupportedSampleRate(gDriver.pendingSampleRate)) {
            gDriver.pendingSampleRate = 0.0;
            pthread_mutex_unlock(&gDriver.stateMutex);
            pthread_mutex_unlock(&gDriver.configurationRequestMutex);
            return callerStatus != 0 ? callerStatus : kAudioHardwareIllegalOperationError;
        }
        if (gDriver.sampleRate == gDriver.pendingSampleRate) {
            gDriver.pendingSampleRate = 0.0;
            pthread_mutex_unlock(&gDriver.stateMutex);
            pthread_mutex_unlock(&gDriver.configurationRequestMutex);
            return callerStatus;
        }

        AudioServerPlugInHostRef host = gDriver.host;
        if (host == NULL || host->RequestDeviceConfigurationChange == NULL) {
            gDriver.pendingSampleRate = 0.0;
            pthread_mutex_unlock(&gDriver.stateMutex);
            pthread_mutex_unlock(&gDriver.configurationRequestMutex);
            return kAudioHardwareNotReadyError;
        }

        UInt64 generation = NextConfigurationGeneration_Locked();
        UInt64 lifetime = gDriver.configurationLifetimeGeneration;
        Float64 actionRate = gDriver.pendingSampleRate;
        gDriver.pendingConfigurationGeneration = generation;
        gDriver.configurationRequestInFlightGeneration = generation;
        pthread_mutex_unlock(&gDriver.stateMutex);
        pthread_mutex_unlock(&gDriver.configurationRequestMutex);

        // No driver lock may cross this boundary. AudioServerPlugIn hosts are
        // allowed to perform, abort or set another format synchronously.
        OSStatus status = host->RequestDeviceConfigurationChange(
            host, kObjectID_Device, generation, NULL);

        pthread_mutex_lock(&gDriver.configurationRequestMutex);
        pthread_mutex_lock(&gDriver.stateMutex);
        if (gDriver.configurationRequestInFlightGeneration == generation) {
            gDriver.configurationRequestInFlightGeneration = 0;
        }
        if (gDriver.configurationLifetimeGeneration != lifetime) {
            // The action belongs to the preceding host lifetime. Even if that
            // host accepted it, its eventual callback is deliberately a no-op.
            status = kAudioHardwareNotReadyError;
        } else if (status != 0) {
            if (gDriver.pendingConfigurationGeneration == generation) {
                gDriver.pendingConfigurationGeneration = 0;
                if (gDriver.pendingSampleRate == actionRate) {
                    gDriver.pendingSampleRate = 0.0;
                }
            } else if (gDriver.sampleRate == actionRate) {
                // A synchronous commit cannot be rolled back by a contradictory
                // status returned afterwards.
                status = 0;
            }
        }
        if (callerStatus == 0 && status != 0) callerStatus = status;

        if (gDriver.pendingConfigurationGeneration == 0
            && gDriver.configurationRequestInFlightGeneration == 0
            && gDriver.sampleRate == gDriver.pendingSampleRate) {
            gDriver.pendingSampleRate = 0.0;
        }
        bool needsFollowUp =
            gDriver.pendingConfigurationGeneration == 0
            && gDriver.configurationRequestInFlightGeneration == 0
            && IsSupportedSampleRate(gDriver.pendingSampleRate)
            && gDriver.sampleRate != gDriver.pendingSampleRate;
        pthread_mutex_unlock(&gDriver.stateMutex);
        pthread_mutex_unlock(&gDriver.configurationRequestMutex);

        if (!needsFollowUp) return callerStatus;
    }
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
    gDriver.anchorTimeoutTicks = (UInt64)(sTicksPerSecond * kClockAnchorTimeoutSeconds);
    gDriver.hasLastAnchor = false;
    gDriver.isClockFollowing = false;
}

static void ExpireClockAnchorIfStale_Locked(UInt64 now);

/// Folds a new anchor from the application into the measured master rate.
///
/// Two anchors straddle a known number of master frames and a known number of
/// host ticks, which is exactly the master's real sample period — including
/// whatever its crystal is actually doing rather than what it claims. Caller
/// holds stateMutex.
static void ApplyClockAnchor_Locked(Float64 sampleTime, UInt64 hostTime, Float64 sampleRate) {
    UInt64 now = mach_absolute_time();
    ExpireClockAnchorIfStale_Locked(now);
    gDriver.lastAnchorReceivedAt = now;

    if (gDriver.hasLastAnchor) {
        Float64 frameDelta = sampleTime - gDriver.lastAnchorSampleTime;
        Float64 tickDelta = hostTime > gDriver.lastAnchorHostTime
            ? (Float64)(hostTime - gDriver.lastAnchorHostTime) : 0.0;

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
                Float64 oldTicksPerRing =
                    gDriver.hostTicksPerFrame * (Float64)kRingBufferFrames;
                Float64 newTicksPerRing = target * (Float64)kRingBufferFrames;
                gDriver.anchorHostTime = RebasedAnchorHostTime(
                    gDriver.anchorHostTime, oldTicksPerRing, newTicksPerRing, now);

                gDriver.hostTicksPerFrame = target;
                gDriver.isClockFollowing = true;
            }
        }
    }

    gDriver.lastAnchorSampleTime = sampleTime;
    gDriver.lastAnchorHostTime = hostTime;
    gDriver.hasLastAnchor = true;
    PublishClockState_Locked();
}

/// Drops back to the nominal rate when the application stops publishing.
/// Caller holds stateMutex.
static void ExpireClockAnchorIfStale_Locked(UInt64 now) {
    if (!gDriver.isClockFollowing) return;
    if (now <= gDriver.lastAnchorReceivedAt) return;
    if (now - gDriver.lastAnchorReceivedAt < gDriver.anchorTimeoutTicks) return;

    Float64 oldTicksPerRing = gDriver.hostTicksPerFrame * (Float64)kRingBufferFrames;
    Float64 newTicksPerRing = gDriver.nominalTicksPerFrame * (Float64)kRingBufferFrames;
    UInt64 staleAt = gDriver.lastAnchorReceivedAt + gDriver.anchorTimeoutTicks;
    gDriver.anchorHostTime = RebasedAnchorHostTime(
        gDriver.anchorHostTime, oldTicksPerRing, newTicksPerRing, staleAt);

    gDriver.hostTicksPerFrame = gDriver.nominalTicksPerFrame;
    gDriver.isClockFollowing = false;
    gDriver.hasLastAnchor = false;
    PublishClockState_Locked();
}

/// Pulls the three anchor fields out of the dictionary the application set.
static bool ReadAnchorDictionary(CFDictionaryRef dictionary,
                                 Float64 *outSampleTime,
                                 UInt64 *outHostTime,
                                 Float64 *outSampleRate) {
    if (dictionary == NULL || CFGetTypeID(dictionary) != CFDictionaryGetTypeID()
        || outSampleTime == NULL || outHostTime == NULL || outSampleRate == NULL) {
        return false;
    }

    CFNumberRef sampleNumber = (CFNumberRef)CFDictionaryGetValue(
        dictionary, CFSTR(kYunAnchorKey_SampleTime));
    CFNumberRef hostNumber = (CFNumberRef)CFDictionaryGetValue(
        dictionary, CFSTR(kYunAnchorKey_HostTime));
    CFNumberRef rateNumber = (CFNumberRef)CFDictionaryGetValue(
        dictionary, CFSTR(kYunAnchorKey_SampleRate));
    if (sampleNumber == NULL || CFGetTypeID(sampleNumber) != CFNumberGetTypeID()
        || hostNumber == NULL || CFGetTypeID(hostNumber) != CFNumberGetTypeID()
        || rateNumber == NULL || CFGetTypeID(rateNumber) != CFNumberGetTypeID()) {
        return false;
    }

    Float64 sampleTime = 0.0;
    Float64 sampleRate = 0.0;
    if (!CFNumberGetValue(sampleNumber, kCFNumberDoubleType, &sampleTime)
        || !isfinite(sampleTime) || sampleTime < 0.0
        || !CFNumberGetValue(rateNumber, kCFNumberDoubleType, &sampleRate)
        || !isfinite(sampleRate) || sampleRate <= 0.0 || sampleRate > 768000.0) {
        return false;
    }

    SInt64 signedHostTime = 0;
    if (CFNumberIsFloatType(hostNumber)) {
        // Compatibility with publishers from before the SInt64 schema. A
        // floating payload is accepted only when round-tripping through SInt64
        // leaves it byte-for-byte at the same integer value.
        Float64 legacyHostTime = 0.0;
        if (!CFNumberGetValue(hostNumber, kCFNumberDoubleType, &legacyHostTime)
            || !isfinite(legacyHostTime) || legacyHostTime < 0.0
            || legacyHostTime >= 0x1p63 || trunc(legacyHostTime) != legacyHostTime) {
            return false;
        }
        signedHostTime = (SInt64)legacyHostTime;
        if ((Float64)signedHostTime != legacyHostTime) return false;
    } else if (!CFNumberGetValue(hostNumber, kCFNumberSInt64Type, &signedHostTime)
               || signedHostTime < 0) {
        return false;
    }

    *outSampleTime = sampleTime;
    *outHostTime = (UInt64)signedHostTime;
    *outSampleRate = sampleRate;
    return true;
}

#pragma mark - IUnknown

static HRESULT Yun_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (outInterface == NULL) return kAudioHardwareBadObjectError;
    // COM requires a failed query to leave no usable interface behind. A host
    // is allowed to reuse its storage, so merely avoiding a write on failure
    // can hand it a stale pointer into this plug-in.
    *outInterface = NULL;
    if (!IsOurDriver(inDriver)) return kAudioHardwareBadObjectError;

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
        if (gDriver.refCount < UINT32_MAX) ++gDriver.refCount;
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
    // An initialization boundary invalidates every deferred callback from the
    // preceding host lifetime. Keep the generation counter monotonic so none
    // of those callbacks can alias a future request.
    if (++gDriver.configurationLifetimeGeneration == 0) {
        ++gDriver.configurationLifetimeGeneration;
    }
    gDriver.pendingSampleRate = 0.0;
    gDriver.pendingConfigurationGeneration = 0;
    gDriver.configurationRequestInFlightGeneration = 0;
    if (gDriver.ringBuffer == NULL) {
        gDriver.ringBuffer = CreateRingBuffer();
    }
    RefreshTimebase_Locked();
    gDriver.anchorHostTime = mach_absolute_time();
    PublishClockState_Locked();
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

    pthread_mutex_lock(&gDriver.stateMutex);
    if (inChangeAction == 0) {
        pthread_mutex_unlock(&gDriver.stateMutex);
        return kAudioHardwareIllegalOperationError;
    }
    if (inChangeAction != gDriver.pendingConfigurationGeneration) {
        // A deferred callback can legitimately arrive after a newer host
        // lifetime or after the action was synchronously completed. It owns no
        // state now; acknowledging it avoids turning harmless reordering into
        // a stream of errors inside the audio server.
        pthread_mutex_unlock(&gDriver.stateMutex);
        return 0;
    }
    if (!IsSupportedSampleRate(gDriver.pendingSampleRate)) {
        pthread_mutex_unlock(&gDriver.stateMutex);
        return kAudioHardwareIllegalOperationError;
    }

    Float64 newRate = gDriver.pendingSampleRate;
    gDriver.pendingSampleRate = 0.0;
    gDriver.pendingConfigurationGeneration = 0;
    if (gDriver.sampleRate != newRate) {
        gDriver.sampleRate = newRate;
        RefreshTimebase_Locked();
        // Restart the timestamp series: sample time is meaningless across a
        // rate change, and stale anchors make virtual devices crackle.
        gDriver.anchorHostTime = mach_absolute_time();
        if (++gDriver.clockSeed == 0) gDriver.clockSeed = 1;
        PublishClockState_Locked();
        ResetRingBuffer(gDriver.ringBuffer);
    }
    pthread_mutex_unlock(&gDriver.stateMutex);
    return 0;
}

static OSStatus Yun_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                   AudioObjectID inDeviceObjectID,
                                                   UInt64 inChangeAction,
                                                   void *inChangeInfo) {
    (void)inChangeInfo;
    if (!IsOurDriver(inDriver)) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gDriver.stateMutex);
    if (inChangeAction == 0) {
        pthread_mutex_unlock(&gDriver.stateMutex);
        return kAudioHardwareIllegalOperationError;
    }
    if (inChangeAction != gDriver.pendingConfigurationGeneration) {
        pthread_mutex_unlock(&gDriver.stateMutex);
        return 0;
    }
    gDriver.pendingSampleRate = 0.0;
    gDriver.pendingConfigurationGeneration = 0;
    pthread_mutex_unlock(&gDriver.stateMutex);
    return 0;
}

#pragma mark - Property support

static bool IsVolumeControl(AudioObjectID objectID) {
    return objectID == kObjectID_Volume_Input_Master
        || objectID == kObjectID_Volume_Output_Master;
}

static bool IsMuteControl(AudioObjectID objectID) {
    return objectID == kObjectID_Mute_Input_Master
        || objectID == kObjectID_Mute_Output_Master;
}

static bool IsControl(AudioObjectID objectID) {
    return IsVolumeControl(objectID) || IsMuteControl(objectID);
}

static bool ControlIsInput(AudioObjectID objectID) {
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

static bool IsInputOrOutputScope(AudioObjectPropertyScope scope) {
    return scope == kAudioObjectPropertyScopeInput
        || scope == kAudioObjectPropertyScopeOutput;
}

/// Matches the inheritance rules used by the class qualifier on
/// kAudioObjectPropertyOwnedObjects. Returning an unfiltered object list makes
/// the HAL discover streams as controls (and controls as streams), which can
/// poison its object cache even though each object's own class is correct.
static bool ObjectIsClassOrSubclassOf(AudioObjectID objectID,
                                      AudioClassID requestedClass) {
    if (requestedClass == kAudioObjectClassIDWildcard
        || requestedClass == kAudioObjectClassID) {
        return true;
    }
    if (objectID == kObjectID_PlugIn) {
        return requestedClass == kAudioPlugInClassID;
    }
    if (objectID == kObjectID_Device) {
        return requestedClass == kAudioDeviceClassID;
    }
    if (objectID == kObjectID_Stream_Input || objectID == kObjectID_Stream_Output) {
        return requestedClass == kAudioStreamClassID;
    }
    if (IsVolumeControl(objectID)) {
        return requestedClass == kAudioVolumeControlClassID
            || requestedClass == kAudioLevelControlClassID
            || requestedClass == kAudioControlClassID;
    }
    if (IsMuteControl(objectID)) {
        return requestedClass == kAudioMuteControlClassID
            || requestedClass == kAudioBooleanControlClassID
            || requestedClass == kAudioControlClassID;
    }
    return false;
}

static OSStatus ValidateClassQualifier(UInt32 qualifierDataSize,
                                       const void *qualifierData) {
    if (qualifierDataSize == 0) return 0;
    if (qualifierDataSize % sizeof(AudioClassID) != 0) {
        return kAudioHardwareBadPropertySizeError;
    }
    if (qualifierData == NULL) return kAudioHardwareIllegalOperationError;
    return 0;
}

static bool OwnedObjectPassesClassQualifier(AudioObjectID objectID,
                                            UInt32 qualifierDataSize,
                                            const void *qualifierData) {
    if (qualifierDataSize == 0) return true;

    const UInt8 *bytes = (const UInt8 *)qualifierData;
    UInt32 count = qualifierDataSize / sizeof(AudioClassID);
    for (UInt32 index = 0; index < count; ++index) {
        // A qualifier is an opaque byte buffer and need not be naturally
        // aligned. memcpy avoids turning a valid unaligned query into UB.
        AudioClassID requestedClass;
        memcpy(&requestedClass, bytes + index * sizeof(AudioClassID),
               sizeof(requestedClass));
        if (ObjectIsClassOrSubclassOf(objectID, requestedClass)) return true;
    }
    return false;
}

static UInt32 UnfilteredOwnedObjects(AudioObjectID objectID,
                                     AudioObjectPropertyScope scope,
                                     AudioObjectID *outObjectIDs) {
    if (objectID == kObjectID_PlugIn) {
        if (outObjectIDs != NULL) outObjectIDs[0] = kObjectID_Device;
        return 1;
    }
    if (objectID != kObjectID_Device) return 0;

    if (scope == kAudioObjectPropertyScopeInput) {
        if (outObjectIDs != NULL) {
            outObjectIDs[0] = kObjectID_Stream_Input;
            outObjectIDs[1] = kObjectID_Volume_Input_Master;
            outObjectIDs[2] = kObjectID_Mute_Input_Master;
        }
        return 3;
    }
    if (scope == kAudioObjectPropertyScopeOutput) {
        if (outObjectIDs != NULL) {
            outObjectIDs[0] = kObjectID_Stream_Output;
            outObjectIDs[1] = kObjectID_Volume_Output_Master;
            outObjectIDs[2] = kObjectID_Mute_Output_Master;
        }
        return 3;
    }

    if (outObjectIDs != NULL) {
        outObjectIDs[0] = kObjectID_Stream_Input;
        outObjectIDs[1] = kObjectID_Stream_Output;
        outObjectIDs[2] = kObjectID_Volume_Input_Master;
        outObjectIDs[3] = kObjectID_Mute_Input_Master;
        outObjectIDs[4] = kObjectID_Volume_Output_Master;
        outObjectIDs[5] = kObjectID_Mute_Output_Master;
    }
    return 6;
}

static UInt32 FilteredOwnedObjectCount(AudioObjectID objectID,
                                       AudioObjectPropertyScope scope,
                                       UInt32 qualifierDataSize,
                                       const void *qualifierData) {
    AudioObjectID candidates[6];
    UInt32 candidateCount = UnfilteredOwnedObjects(objectID, scope, candidates);
    UInt32 result = 0;
    for (UInt32 index = 0; index < candidateCount; ++index) {
        if (OwnedObjectPassesClassQualifier(
                candidates[index], qualifierDataSize, qualifierData)) {
            ++result;
        }
    }
    return result;
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

typedef CFNumberRef (*YunNumberCreateFunction)(
    CFAllocatorRef, CFNumberType, const void *);

/// Builds the small property-list dictionaries returned by the driver without
/// ever inserting or releasing a null Core Foundation object. Allocation
/// failure is rare, but this code runs inside coreaudiod where a null passed to
/// CFDictionarySetValue would crash system audio rather than only this app.
static CFMutableDictionaryRef CreateTwoNumberDictionary(
    CFStringRef firstKey,
    CFNumberType firstType,
    const void *firstValue,
    CFStringRef secondKey,
    CFNumberType secondType,
    const void *secondValue,
    YunNumberCreateFunction createNumber
) {
    CFMutableDictionaryRef result = CFDictionaryCreateMutable(
        NULL, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (result == NULL) return NULL;

    CFNumberRef first = createNumber(NULL, firstType, firstValue);
    if (first == NULL) {
        CFRelease(result);
        return NULL;
    }
    CFNumberRef second = createNumber(NULL, secondType, secondValue);
    if (second == NULL) {
        CFRelease(first);
        CFRelease(result);
        return NULL;
    }
    CFDictionarySetValue(result, firstKey, first);
    CFDictionarySetValue(result, secondKey, second);
    CFRelease(first);
    CFRelease(second);
    return result;
}

static bool AddSInt64ToDictionary(
    CFMutableDictionaryRef dictionary, CFStringRef key, SInt64 value
) {
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt64Type, &value);
    if (number == NULL) return false;
    CFDictionarySetValue(dictionary, key, number);
    CFRelease(number);
    return true;
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
    if (!Yun_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }

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
        *outIsSettable = IsVolumeControl(inObjectID);
        break;
    case kAudioBooleanControlPropertyValue:
        *outIsSettable = IsMuteControl(inObjectID);
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
    (void)inClientProcessID;
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

    case kAudioObjectPropertyOwnedObjects: {
        OSStatus status = ValidateClassQualifier(
            inQualifierDataSize, inQualifierData);
        if (status != 0) return status;
        UInt32 count = FilteredOwnedObjectCount(
            inObjectID, inAddress->mScope,
            inQualifierDataSize, inQualifierData);
        *outDataSize = count * sizeof(AudioObjectID);
        return 0;
    }

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
    case kAudioDevicePropertyBufferFrameSize:
    case kAudioDevicePropertyUsesVariableBufferFrameSizes:
    case kAudioDevicePropertyZeroTimeStampPeriod:
    case kAudioDevicePropertyIsHidden:
        if (inObjectID != kObjectID_Device) break;
        *outDataSize = sizeof(UInt32);
        return 0;
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
    case kAudioDevicePropertySafetyOffset:
        if (inObjectID != kObjectID_Device
            || !IsInputOrOutputScope(inAddress->mScope)) {
            break;
        }
        *outDataSize = sizeof(UInt32);
        return 0;
    case kAudioDevicePropertyBufferFrameSizeRange:
        if (inObjectID != kObjectID_Device) break;
        *outDataSize = sizeof(AudioValueRange);
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
        if (inObjectID != kObjectID_Device
            || !IsInputOrOutputScope(inAddress->mScope)) {
            break;
        }
        *outDataSize = 2 * sizeof(UInt32);
        return 0;
    case kAudioDevicePropertyPreferredChannelLayout:
        if (inObjectID != kObjectID_Device
            || !IsInputOrOutputScope(inAddress->mScope)) {
            break;
        }
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
            *outDataSize = 2 * sizeof(AudioObjectID);
            break;
        }
        return 0;
    case kAudioObjectPropertyControlList:
        if (inObjectID != kObjectID_Device) break;
        *outDataSize = 4 * sizeof(AudioObjectID);
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
        if (!IsVolumeControl(inObjectID)) break;
        *outDataSize = sizeof(Float32);
        return 0;
    case kAudioLevelControlPropertyDecibelRange:
        if (!IsVolumeControl(inObjectID)) break;
        *outDataSize = sizeof(AudioValueRange);
        return 0;
    case kAudioLevelControlPropertyConvertScalarToDecibels:
    case kAudioLevelControlPropertyConvertDecibelsToScalar:
        if (!IsVolumeControl(inObjectID)) break;
        *outDataSize = sizeof(Float32);
        return 0;
    case kAudioBooleanControlPropertyValue:
        if (!IsMuteControl(inObjectID)) break;
        *outDataSize = sizeof(UInt32);
        return 0;
    case kAudioObjectPropertyCustomPropertyInfoList:
        if (inObjectID != kObjectID_Device) break;
        *outDataSize = 2 * sizeof(AudioServerPlugInCustomPropertyInfo);
        return 0;
    case kYunCustomProperty_ClockAnchor:
    case kYunCustomProperty_IOHealth:
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
        if (inObjectID != kObjectID_Device
            && inObjectID != kObjectID_Stream_Input
            && inObjectID != kObjectID_Stream_Output) {
            break;
        }
        if (inObjectID == kObjectID_Device
            && !IsInputOrOutputScope(inAddress->mScope)) {
            break;
        }
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
    UInt32 advertisedSize = 0;
    status = Yun_GetPropertyDataSize(
        inDriver, inObjectID, inClientProcessID, inAddress,
        inQualifierDataSize, inQualifierData, &advertisedSize);
    if (status != 0) return status;

    switch (inAddress->mSelector) {
    case kAudioObjectPropertyBaseClass:
        YUN_GUARD(inDataSize >= sizeof(AudioClassID), kAudioHardwareBadPropertySizeError, done);
        if (IsVolumeControl(inObjectID)) {
            // The HAL walks the class hierarchy to decide what a control is;
            // a volume whose base class is not the level control is not found
            // by anything looking for a level control.
            *(AudioClassID *)outData = kAudioLevelControlClassID;
        } else if (IsMuteControl(inObjectID)) {
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
        } else if (IsVolumeControl(inObjectID)) {
            *(AudioClassID *)outData = kAudioVolumeControlClassID;
        } else if (IsMuteControl(inObjectID)) {
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
        AudioObjectID candidates[6];
        UInt32 candidateCount = UnfilteredOwnedObjects(
            inObjectID, inAddress->mScope, candidates);
        for (UInt32 index = 0; index < candidateCount && written < capacity; ++index) {
            if (OwnedObjectPassesClassQualifier(
                    candidates[index], inQualifierDataSize, inQualifierData)) {
                ids[written++] = candidates[index];
            }
        }
        *outDataSize = written * sizeof(AudioObjectID);
        break;
    }

    case kAudioPlugInPropertyBoxList:
        *outDataSize = 0;
        break;

    case kAudioObjectPropertyControlList: {
        YUN_GUARD(inDataSize >= 4 * sizeof(AudioObjectID),
                  kAudioHardwareBadPropertySizeError, done);
        AudioObjectID *controls = (AudioObjectID *)outData;
        controls[0] = kObjectID_Volume_Input_Master;
        controls[1] = kObjectID_Mute_Input_Master;
        controls[2] = kObjectID_Volume_Output_Master;
        controls[3] = kObjectID_Mute_Output_Master;
        *outDataSize = 4 * sizeof(AudioObjectID);
        break;
    }

    case kAudioControlPropertyScope:
        YUN_GUARD(inDataSize >= sizeof(AudioObjectPropertyScope),
                  kAudioHardwareBadPropertySizeError, done);
        *(AudioObjectPropertyScope *)outData = ControlIsInput(inObjectID)
            ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
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
        *(Float32 *)outData =
            ControlIsInput(inObjectID) ? gDriver.inputVolume : gDriver.outputVolume;
        pthread_mutex_unlock(&gDriver.stateMutex);
        *outDataSize = sizeof(Float32);
        break;

    case kAudioLevelControlPropertyDecibelValue:
        YUN_GUARD(inDataSize >= sizeof(Float32), kAudioHardwareBadPropertySizeError, done);
        pthread_mutex_lock(&gDriver.stateMutex);
        *(Float32 *)outData = ScalarToDecibels(
            ControlIsInput(inObjectID) ? gDriver.inputVolume : gDriver.outputVolume);
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
        YUN_GUARD(isfinite(*(Float32 *)outData),
                  kAudioHardwareIllegalOperationError, done);
        *(Float32 *)outData = ScalarToDecibels(*(Float32 *)outData);
        *outDataSize = sizeof(Float32);
        break;

    case kAudioLevelControlPropertyConvertDecibelsToScalar:
        YUN_GUARD(inDataSize >= sizeof(Float32), kAudioHardwareBadPropertySizeError, done);
        YUN_GUARD(isfinite(*(Float32 *)outData),
                  kAudioHardwareIllegalOperationError, done);
        *(Float32 *)outData = DecibelsToScalar(*(Float32 *)outData);
        *outDataSize = sizeof(Float32);
        break;

    case kAudioBooleanControlPropertyValue:
        YUN_GUARD(inDataSize >= sizeof(UInt32), kAudioHardwareBadPropertySizeError, done);
        pthread_mutex_lock(&gDriver.stateMutex);
        bool muted = ControlIsInput(inObjectID) ? gDriver.inputMuted : gDriver.outputMuted;
        *(UInt32 *)outData = muted ? 1 : 0;
        pthread_mutex_unlock(&gDriver.stateMutex);
        *outDataSize = sizeof(UInt32);
        break;

    case kAudioObjectPropertyCustomPropertyInfoList: {
        YUN_GUARD(inDataSize >= 2 * sizeof(AudioServerPlugInCustomPropertyInfo),
                  kAudioHardwareBadPropertySizeError, done);
        AudioServerPlugInCustomPropertyInfo *info =
            (AudioServerPlugInCustomPropertyInfo *)outData;
        info[0].mSelector = kYunCustomProperty_ClockAnchor;
        info[0].mPropertyDataType = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;
        info[0].mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
        info[1].mSelector = kYunCustomProperty_IOHealth;
        info[1].mPropertyDataType = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;
        info[1].mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
        *outDataSize = 2 * sizeof(AudioServerPlugInCustomPropertyInfo);
        break;
    }

    case kYunCustomProperty_ClockAnchor: {
        // Reading reports what the clock is actually doing, so the application
        // can show an honest "locked" indicator instead of assuming its own
        // writes took effect.
        YUN_GUARD(inDataSize >= sizeof(CFPropertyListRef),
                  kAudioHardwareBadPropertySizeError, done);

        pthread_mutex_lock(&gDriver.stateMutex);
        ExpireClockAnchorIfStale_Locked(mach_absolute_time());
        Float64 following = gDriver.isClockFollowing ? 1.0 : 0.0;
        Float64 ticksPerFrame = gDriver.hostTicksPerFrame;
        Float64 nominalTicks = gDriver.nominalTicksPerFrame;
        pthread_mutex_unlock(&gDriver.stateMutex);

        // Ratio of actual to nominal: 1.0 means the master is running at its
        // stated rate, 1.00002 means twenty parts per million fast.
        Float64 ratio = (nominalTicks > 0.0) ? (ticksPerFrame / nominalTicks) : 1.0;

        CFMutableDictionaryRef result = CreateTwoNumberDictionary(
            CFSTR("following"), kCFNumberDoubleType, &following,
            CFSTR("rateRatio"), kCFNumberDoubleType, &ratio,
            CFNumberCreate);
        if (result == NULL) {
            status = kAudioHardwareUnspecifiedError;
            goto done;
        }

        *(CFPropertyListRef *)outData = result;
        *outDataSize = sizeof(CFPropertyListRef);
        break;
    }

    case kYunCustomProperty_IOHealth: {
        YUN_GUARD(inDataSize >= sizeof(CFPropertyListRef),
                  kAudioHardwareBadPropertySizeError, done);
        SInt64 unsafeReads = (SInt64)atomic_load_explicit(
            &gDriver.unsafeReadOperations, memory_order_relaxed);
        SInt64 unsafeWrites = (SInt64)atomic_load_explicit(
            &gDriver.unsafeWriteOperations, memory_order_relaxed);
        CFMutableDictionaryRef result = CreateTwoNumberDictionary(
            CFSTR(kYunIOHealthKey_UnsafeReadOperations),
            kCFNumberSInt64Type, &unsafeReads,
            CFSTR(kYunIOHealthKey_UnsafeWriteOperations),
            kCFNumberSInt64Type, &unsafeWrites,
            CFNumberCreate);
        if (result == NULL) {
            status = kAudioHardwareUnspecifiedError;
            goto done;
        }
        if (atomic_load_explicit(
                &gDriver.unsafeReadEvidenceState, memory_order_acquire) == 2) {
            SInt64 readStart = (SInt64)atomic_load_explicit(
                &gDriver.unsafeReadStartFrame, memory_order_relaxed);
            SInt64 readFrames = (SInt64)atomic_load_explicit(
                &gDriver.unsafeReadFrameCount, memory_order_relaxed);
            SInt64 unavailable = (SInt64)atomic_load_explicit(
                &gDriver.unsafeReadUnavailableFrame, memory_order_relaxed);
            UInt64 publishedIdentity = atomic_load_explicit(
                &gDriver.unsafeReadLastPublishedIdentity, memory_order_relaxed);
            SInt64 publishedStart = -1;
            SInt64 publishedFrames = 0;
            if (publishedIdentity != 0) {
                publishedStart = (SInt64)((publishedIdentity
                    >> kRingTransactionFrameBits) - 1);
                publishedFrames = (SInt64)((publishedIdentity
                    & ((UINT64_C(1) << kRingTransactionFrameBits) - 1)) + 1);
            }
            if (!AddSInt64ToDictionary(
                    result, CFSTR(kYunIOHealthKey_UnsafeReadStartFrame), readStart)
                || !AddSInt64ToDictionary(
                    result, CFSTR(kYunIOHealthKey_UnsafeReadFrameCount), readFrames)
                || !AddSInt64ToDictionary(
                    result, CFSTR(kYunIOHealthKey_UnsafeReadUnavailableFrame), unavailable)
                || !AddSInt64ToDictionary(
                    result, CFSTR(kYunIOHealthKey_LastPublishedStartFrame), publishedStart)
                || !AddSInt64ToDictionary(
                    result, CFSTR(kYunIOHealthKey_LastPublishedFrameCount), publishedFrames)) {
                CFRelease(result);
                status = kAudioHardwareUnspecifiedError;
                goto done;
            }
        }
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
        YUN_GUARD(inQualifierData != NULL, kAudioHardwareIllegalOperationError, done);
        YUN_GUARD(inDataSize >= sizeof(AudioObjectID), kAudioHardwareBadPropertySizeError, done);
        CFStringRef uid = *(const CFStringRef *)inQualifierData;
        YUN_GUARD(uid == NULL || CFGetTypeID(uid) == CFStringGetTypeID(),
                  kAudioHardwareIllegalOperationError, done);
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

    case kAudioDevicePropertyBufferFrameSize:
        YUN_GUARD(inDataSize >= sizeof(UInt32), kAudioHardwareBadPropertySizeError, done);
        *(UInt32 *)outData = kDevice_BufferFrameSize;
        *outDataSize = sizeof(UInt32);
        break;

    case kAudioDevicePropertyBufferFrameSizeRange: {
        YUN_GUARD(inDataSize >= sizeof(AudioValueRange),
                  kAudioHardwareBadPropertySizeError, done);
        AudioValueRange *range = (AudioValueRange *)outData;
        range->mMinimum = kDevice_BufferFrameSize;
        range->mMaximum = kDevice_BufferFrameSize;
        *outDataSize = sizeof(AudioValueRange);
        break;
    }

    case kAudioDevicePropertyUsesVariableBufferFrameSizes:
        YUN_GUARD(inDataSize >= sizeof(UInt32), kAudioHardwareBadPropertySizeError, done);
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
        *(UInt32 *)outData = inAddress->mScope == kAudioObjectPropertyScopeInput
            ? kDevice_InputSafetyOffsetFrames
            : kDevice_OutputSafetyOffsetFrames;
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
        pthread_mutex_lock(&gDriver.stateMutex);
        *(UInt32 *)outData = StreamIsInput(inObjectID)
            ? gDriver.inputStreamIsActive : gDriver.outputStreamIsActive;
        pthread_mutex_unlock(&gDriver.stateMutex);
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
        if (!IsVolumeControl(inObjectID)) return kAudioHardwareUnknownPropertyError;
        if (inDataSize != sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
        Float32 value = *(const Float32 *)inData;
        if (!isfinite(value)) return kAudioHardwareIllegalOperationError;
        Float32 scalar =
            (inAddress->mSelector == kAudioLevelControlPropertyScalarValue)
                ? value : DecibelsToScalar(value);
        if (scalar < 0.0f) scalar = 0.0f;
        if (scalar > 1.0f) scalar = 1.0f;

        bool isInput = ControlIsInput(inObjectID);
        pthread_mutex_lock(&gDriver.stateMutex);
        bool changed = (scalar != (isInput ? gDriver.inputVolume : gDriver.outputVolume));
        // Recomputed here rather than on the IO thread, which must not call
        // powf or take this lock.
        if (isInput) {
            gDriver.inputVolume = scalar;
            Float32 gain = gDriver.inputMuted ? 0.0f : ScalarToGain(scalar);
            atomic_store_explicit(
                &gDriver.inputGainBits, Float32Bits(gain), memory_order_release);
        } else {
            gDriver.outputVolume = scalar;
            Float32 gain = gDriver.outputMuted ? 0.0f : ScalarToGain(scalar);
            atomic_store_explicit(
                &gDriver.outputGainBits, Float32Bits(gain), memory_order_release);
        }
        AudioServerPlugInHostRef host = gDriver.host;
        pthread_mutex_unlock(&gDriver.stateMutex);

        // Both representations move together, so both have to be announced or
        // whichever one the observer watches goes stale.
        if (changed && host != NULL && host->PropertiesChanged != NULL) {
            AudioObjectPropertyAddress changes[2] = {
                { kAudioLevelControlPropertyScalarValue,
                  kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                { kAudioLevelControlPropertyDecibelValue,
                  kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
            };
            host->PropertiesChanged(host, inObjectID, 2, changes);
        }
        return 0;
    }

    case kAudioBooleanControlPropertyValue: {
        if (!IsMuteControl(inObjectID)) return kAudioHardwareUnknownPropertyError;
        if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        bool muted = (*(const UInt32 *)inData != 0);

        bool isInput = ControlIsInput(inObjectID);
        pthread_mutex_lock(&gDriver.stateMutex);
        bool changed = (muted != (isInput ? gDriver.inputMuted : gDriver.outputMuted));
        if (isInput) {
            gDriver.inputMuted = muted;
            Float32 gain = muted ? 0.0f : ScalarToGain(gDriver.inputVolume);
            atomic_store_explicit(
                &gDriver.inputGainBits, Float32Bits(gain), memory_order_release);
        } else {
            gDriver.outputMuted = muted;
            Float32 gain = muted ? 0.0f : ScalarToGain(gDriver.outputVolume);
            atomic_store_explicit(
                &gDriver.outputGainBits, Float32Bits(gain), memory_order_release);
        }
        AudioServerPlugInHostRef host = gDriver.host;
        pthread_mutex_unlock(&gDriver.stateMutex);

        if (changed && host != NULL && host->PropertiesChanged != NULL) {
            AudioObjectPropertyAddress change = {
                kAudioBooleanControlPropertyValue,
                kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
            };
            host->PropertiesChanged(host, inObjectID, 1, &change);
        }
        return 0;
    }

    case kAudioDevicePropertyNominalSampleRate: {
        if (inObjectID != kObjectID_Device) return kAudioHardwareUnknownPropertyError;
        if (inDataSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        Float64 requested = *(const Float64 *)inData;
        if (!IsSupportedSampleRate(requested)) return kAudioHardwareIllegalOperationError;
        return RequestSampleRateChange(requested);
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
        if (!IsCanonicalStreamDescription(format)) {
            return kAudioDeviceUnsupportedFormatError;
        }
        return RequestSampleRateChange(format->mSampleRate);
    }

    case kAudioStreamPropertyIsActive:
        if (inObjectID != kObjectID_Stream_Input
            && inObjectID != kObjectID_Stream_Output) {
            return kAudioHardwareUnknownPropertyError;
        }
        if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        bool isInput = StreamIsInput(inObjectID);
        bool active = *(const UInt32 *)inData != 0;
        pthread_mutex_lock(&gDriver.stateMutex);
        bool changed = active != (isInput
            ? gDriver.inputStreamIsActive : gDriver.outputStreamIsActive);
        if (isInput) {
            gDriver.inputStreamIsActive = active;
        } else {
            gDriver.outputStreamIsActive = active;
        }
        AudioServerPlugInHostRef host = gDriver.host;
        pthread_mutex_unlock(&gDriver.stateMutex);

        if (changed && host != NULL && host->PropertiesChanged != NULL) {
            AudioObjectPropertyAddress change = {
                kAudioStreamPropertyIsActive,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain,
            };
            host->PropertiesChanged(host, inObjectID, 1, &change);
        }
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
        gDriver.anchorHostTime = mach_absolute_time();
        RefreshTimebase_Locked();
        if (++gDriver.clockSeed == 0) gDriver.clockSeed = 1;
        PublishClockState_Locked();
        ResetRingBuffer(gDriver.ringBuffer);
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

    YunClockSnapshot clock = ReadPublishedClock();
    UInt64 now = mach_absolute_time();

    if (clock.isClockFollowing
        && now > clock.lastAnchorReceivedAt
        && now - clock.lastAnchorReceivedAt >= clock.anchorTimeoutTicks) {
        Float64 oldTicksPerRing =
            clock.hostTicksPerFrame * (Float64)kRingBufferFrames;
        Float64 nominalTicksPerRing =
            clock.nominalTicksPerFrame * (Float64)kRingBufferFrames;
        UInt64 staleAt = clock.lastAnchorReceivedAt + clock.anchorTimeoutTicks;
        clock.anchorHostTime = RebasedAnchorHostTime(
            clock.anchorHostTime, oldTicksPerRing, nominalTicksPerRing, staleAt);
        clock.hostTicksPerFrame = clock.nominalTicksPerFrame;
    }

    Float64 ticksPerRing = clock.hostTicksPerFrame * (Float64)kRingBufferFrames;
    UInt64 period = TimestampPeriodAtHostTime(clock.anchorHostTime, now, ticksPerRing);
    *outSampleTime = (Float64)period * (Float64)kRingBufferFrames;
    *outHostTime =
        clock.anchorHostTime + (UInt64)((Float64)period * ticksPerRing);
    *outSeed = clock.seed;

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

static bool SampleTimeToFrame(Float64 sampleTime, UInt64 *outFrame) {
    if (outFrame == NULL || !isfinite(sampleTime)
        || sampleTime < 0.0 || sampleTime >= 0x1p64) {
        return false;
    }
    UInt64 frame = (UInt64)sampleTime;
    if ((Float64)frame != sampleTime) return false;
    *outFrame = frame;
    return true;
}

static bool RingSpanCanBeTagged(UInt64 startFrame, UInt32 frames) {
    if (frames == 0) return true;
    if (frames > kRingBufferFrames) return false;
    if (startFrame > kRingTransactionMaximumStart) return false;
    if (startFrame == kRingFrameUnpublished) return false;
    return (UInt64)(frames - 1) < kRingFrameUnpublished - startFrame;
}

static UInt64 RingWriteIdentity(UInt64 startFrame, UInt32 frames) {
    return ((startFrame + 1) << kRingTransactionFrameBits)
        | (UInt64)(frames - 1);
}

typedef enum {
    kRingWriteClaimed,
    kRingWriteCoalesced,
    kRingWriteUnsafe,
} YunRingWriteAdmission;

/// A `WriteMix` buffer is the host's complete mix, not one client's
/// contribution. coreaudiod can nevertheless deliver the same absolute span
/// through overlapping client callbacks. Once that span is fully published,
/// touching its ownership again would briefly turn valid input reads into
/// silence for no change in audio.
static bool RingWriteSpanIsPublished(YunRingFrame *ring,
                                     UInt64 startFrame,
                                     UInt32 frames) {
    for (UInt32 frame = 0; frame < frames; ++frame) {
        UInt64 absoluteFrame = startFrame + frame;
        UInt64 slot = absoluteFrame & kRingBufferMask;
        UInt64 ownerBefore = atomic_load_explicit(
            &ring[slot].owner, memory_order_seq_cst);
        if (ownerBefore != 0) return false;
        UInt64 published = atomic_load_explicit(
            &ring[slot].sampleFrame, memory_order_seq_cst);
        UInt64 ownerAfter = atomic_load_explicit(
            &ring[slot].owner, memory_order_seq_cst);
        if (published != absoluteFrame || ownerAfter != 0) return false;
    }
    return true;
}

static void ReleaseRingWritePrefix(YunRingFrame *ring,
                                   UInt64 startFrame,
                                   UInt32 frames) {
    for (UInt32 frame = 0; frame < frames; ++frame) {
        UInt64 slot = (startFrame + frame) & kRingBufferMask;
        atomic_store_explicit(
            &ring[slot].owner, 0, memory_order_seq_cst);
    }
}

/// Claims every slot before changing a sample. One callback owns the whole
/// block. The first slot carries one atomic, collision-free start/count identity,
/// so an active exact duplicate can coalesce while partial overlap cannot. No
/// retry is deliberate: an IO deadline is a poor place for a spin loop.
static YunRingWriteAdmission ClaimRingWriteSpan(YunRingFrame *ring,
                                                UInt64 startFrame,
                                                UInt32 frames) {
    if (RingWriteSpanIsPublished(ring, startFrame, frames)) {
        return kRingWriteCoalesced;
    }

    UInt64 owner = RingWriteIdentity(startFrame, frames);
    UInt64 firstSlot = startFrame & kRingBufferMask;
    UInt64 unowned = 0;
    if (!atomic_compare_exchange_strong_explicit(
            &ring[firstSlot].owner, &unowned, owner,
            memory_order_seq_cst, memory_order_seq_cst)) {
        return unowned == owner ? kRingWriteCoalesced : kRingWriteUnsafe;
    }

    UInt64 firstPublished = atomic_load_explicit(
        &ring[firstSlot].sampleFrame, memory_order_seq_cst);
    if ((firstPublished == startFrame)
        || (firstPublished != kRingFrameUnpublished
            && firstPublished > startFrame)) {
        ReleaseRingWritePrefix(ring, startFrame, 1);
        return RingWriteSpanIsPublished(ring, startFrame, frames)
            ? kRingWriteCoalesced : kRingWriteUnsafe;
    }

    UInt32 claimed = 1;
    for (; claimed < frames; ++claimed) {
        UInt64 absoluteFrame = startFrame + claimed;
        UInt64 slot = absoluteFrame & kRingBufferMask;
        unowned = 0;
        if (!atomic_compare_exchange_strong_explicit(
                &ring[slot].owner, &unowned, owner,
                memory_order_seq_cst, memory_order_seq_cst)) {
            ReleaseRingWritePrefix(ring, startFrame, claimed);
            return kRingWriteUnsafe;
        }
        UInt64 published = atomic_load_explicit(
            &ring[slot].sampleFrame, memory_order_seq_cst);
        if (published == absoluteFrame) {
            ReleaseRingWritePrefix(ring, startFrame, claimed + 1);
            return kRingWriteUnsafe;
        }
        if (published != kRingFrameUnpublished
            && published > absoluteFrame) {
            ReleaseRingWritePrefix(ring, startFrame, claimed + 1);
            return kRingWriteUnsafe;
        }
    }
    if (claimed == frames) return kRingWriteClaimed;
    return kRingWriteUnsafe;
}

static void PublishRingWrite(YunRingFrame *ring,
                             UInt64 startFrame,
                             UInt32 frames,
                             const Float32 *buffer,
                             Float32 gain) {
    for (UInt32 frame = 0; frame < frames; ++frame) {
        Float32 samples[kDevice_ChannelCount] = {
            buffer[frame * kDevice_ChannelCount],
            buffer[frame * kDevice_ChannelCount + 1],
        };
        if (gain != 1.0f) {
            samples[0] *= gain;
            samples[1] *= gain;
        }
        UInt64 absoluteFrame = startFrame + frame;
        UInt64 slot = absoluteFrame & kRingBufferMask;
        atomic_store_explicit(
            &ring[slot].stereoBits, PackStereoFrame(samples),
            memory_order_seq_cst);
        atomic_store_explicit(
            &ring[slot].sampleFrame, absoluteFrame, memory_order_seq_cst);
    }
    // Keep the first slot's transaction identity until every other owner is
    // gone. An exact duplicate arriving during release then coalesces against
    // that one record; once it disappears, the complete published span is
    // already immutable and the duplicate takes the published fast path.
    for (UInt32 frame = frames; frame > 1; --frame) {
        UInt64 slot = (startFrame + frame - 1) & kRingBufferMask;
        atomic_store_explicit(&ring[slot].owner, 0, memory_order_seq_cst);
    }
    UInt64 firstSlot = startFrame & kRingBufferMask;
    atomic_store_explicit(
        &ring[firstSlot].owner, 0, memory_order_seq_cst);
    atomic_store_explicit(
        &gDriver.lastPublishedIdentity,
        RingWriteIdentity(startFrame, frames), memory_order_seq_cst);

    // Publish the boundary only after the complete first span is immutable.
    // A concurrent reader which arrives earlier sees an unpublished boundary
    // and returns the correct cold-start silence instead of diagnosing a race.
    UInt64 unpublished = kRingFrameUnpublished;
    atomic_compare_exchange_strong_explicit(
        &gDriver.firstPublishedFrame, &unpublished, startFrame,
        memory_order_seq_cst, memory_order_seq_cst);
}

/// The two tag loads bracket the packed stereo load. All ring operations are
/// sequentially consistent so a slot reuse which overwrites the sample must
/// also be visible to the second tag load. Release/acquire publication alone
/// cannot give that guarantee when a reader straddles a later writer's claim.
typedef enum {
    kRingReadExact,
    kRingReadColdStart,
    kRingReadUnsafe,
} YunRingReadResult;

static bool RingReadIsColdStart(UInt64 absoluteFrame) {
    UInt64 first = atomic_load_explicit(
        &gDriver.firstPublishedFrame, memory_order_seq_cst);
    return first == kRingFrameUnpublished || absoluteFrame < first;
}

static YunRingReadResult ReadRingSpan(YunRingFrame *ring,
                                      UInt64 startFrame,
                                      UInt32 frames,
                                      Float32 *buffer,
                                      Float32 gain,
                                      UInt64 *outUnavailableFrame) {
    if (outUnavailableFrame != NULL) {
        *outUnavailableFrame = kRingFrameUnpublished;
    }
    bool includedColdStart = false;
    for (UInt32 frame = 0; frame < frames; ++frame) {
        UInt64 absoluteFrame = startFrame + frame;
        UInt64 slot = absoluteFrame & kRingBufferMask;
        UInt64 ownerBefore = atomic_load_explicit(
            &ring[slot].owner, memory_order_seq_cst);
        if (ownerBefore != 0) {
            if (!RingReadIsColdStart(absoluteFrame)) {
                if (outUnavailableFrame != NULL) *outUnavailableFrame = absoluteFrame;
                return kRingReadUnsafe;
            }
            buffer[frame * kDevice_ChannelCount] = 0;
            buffer[frame * kDevice_ChannelCount + 1] = 0;
            includedColdStart = true;
            continue;
        }
        UInt64 tagBefore = atomic_load_explicit(
            &ring[slot].sampleFrame, memory_order_seq_cst);
        if (tagBefore != absoluteFrame) {
            if (!RingReadIsColdStart(absoluteFrame)) {
                if (outUnavailableFrame != NULL) *outUnavailableFrame = absoluteFrame;
                return kRingReadUnsafe;
            }
            buffer[frame * kDevice_ChannelCount] = 0;
            buffer[frame * kDevice_ChannelCount + 1] = 0;
            includedColdStart = true;
            continue;
        }
        UInt64 bits = atomic_load_explicit(
            &ring[slot].stereoBits, memory_order_seq_cst);
        UInt64 tagAfter = atomic_load_explicit(
            &ring[slot].sampleFrame, memory_order_seq_cst);
        UInt64 ownerAfter = atomic_load_explicit(
            &ring[slot].owner, memory_order_seq_cst);
        if (tagAfter != absoluteFrame || ownerAfter != 0) {
            if (!RingReadIsColdStart(absoluteFrame)) {
                if (outUnavailableFrame != NULL) *outUnavailableFrame = absoluteFrame;
                return kRingReadUnsafe;
            }
            buffer[frame * kDevice_ChannelCount] = 0;
            buffer[frame * kDevice_ChannelCount + 1] = 0;
            includedColdStart = true;
            continue;
        }

        Float32 samples[kDevice_ChannelCount];
        UnpackStereoFrame(bits, samples);
        if (gain == 1.0f) {
            // Unity is the ordinary case and has to stay exactly untouched:
            // multiplying by 1.0f is arithmetic, and this device's claim is
            // that it does none.
            buffer[frame * kDevice_ChannelCount] = samples[0];
            buffer[frame * kDevice_ChannelCount + 1] = samples[1];
        } else {
            buffer[frame * kDevice_ChannelCount] = samples[0] * gain;
            buffer[frame * kDevice_ChannelCount + 1] = samples[1] * gain;
        }
    }
    return includedColdStart ? kRingReadColdStart : kRingReadExact;
}

static void RecordUnsafeReadEvidence(
    UInt64 startFrame, UInt32 frames, UInt64 unavailableFrame
) {
    UInt64 empty = 0;
    if (!atomic_compare_exchange_strong_explicit(
            &gDriver.unsafeReadEvidenceState, &empty, 1,
            memory_order_acq_rel, memory_order_relaxed)) {
        return;
    }
    atomic_store_explicit(
        &gDriver.unsafeReadStartFrame, startFrame, memory_order_relaxed);
    atomic_store_explicit(
        &gDriver.unsafeReadFrameCount, frames, memory_order_relaxed);
    atomic_store_explicit(
        &gDriver.unsafeReadUnavailableFrame, unavailableFrame,
        memory_order_relaxed);
    atomic_store_explicit(
        &gDriver.unsafeReadLastPublishedIdentity,
        atomic_load_explicit(
            &gDriver.lastPublishedIdentity, memory_order_seq_cst),
        memory_order_relaxed);
    atomic_store_explicit(
        &gDriver.unsafeReadEvidenceState, 2, memory_order_release);
}

/// Converts a timing-contract violation into a deterministic silent cycle.
/// Returning an error for every drift-adjusted operation can make the audio
/// server retry continuously; one bounded dropout is safer for the entire
/// machine. Absolute tags make old ring epochs unreadable, so a rejected write
/// changes no storage and cannot disturb a valid concurrent owner.
static void FailSilentIO(bool isRead,
                         Float32 *buffer,
                         UInt32 frames) {
    if (isRead) {
        memset(buffer, 0,
               (size_t)frames * kDevice_ChannelCount * sizeof(Float32));
        atomic_fetch_add_explicit(
            &gDriver.unsafeReadOperations, 1, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(
            &gDriver.unsafeWriteOperations, 1, memory_order_relaxed);
    }
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
    (void)ioSecondaryBuffer;
    if (!IsOurDriver(inDriver)) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    bool isRead = inOperationID == kAudioServerPlugInIOOperationReadInput;
    bool isWrite = inOperationID == kAudioServerPlugInIOOperationWriteMix;
    if (!isRead && !isWrite) return 0;
    if ((isRead && inStreamObjectID != kObjectID_Stream_Input)
        || (isWrite && inStreamObjectID != kObjectID_Stream_Output)) {
        return kAudioHardwareBadStreamError;
    }
    if (inIOCycleInfo == NULL || ioMainBuffer == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    YunRingFrame *ring = gDriver.ringBuffer;
    Float32 *buffer = (Float32 *)ioMainBuffer;
    if (inIOBufferFrameSize == 0) return 0;

    UInt64 inputStart = 0;
    UInt64 outputStart = 0;
    bool inputTimeIsValid = SampleTimeToFrame(
        inIOCycleInfo->mInputTime.mSampleTime, &inputStart);
    bool outputTimeIsValid = SampleTimeToFrame(
        inIOCycleInfo->mOutputTime.mSampleTime, &outputStart);
    if (ring == NULL || !inputTimeIsValid || !outputTimeIsValid
        || !RingSpanCanBeTagged(inputStart, inIOBufferFrameSize)
        || !RingSpanCanBeTagged(outputStart, inIOBufferFrameSize)) {
        FailSilentIO(isRead, buffer, inIOBufferFrameSize);
        return 0;
    }

    YUN_DRIVER_IO_TEST_HOOK(true, inClientID, inOperationID);

    if (isRead) {
        Float32 gain = Float32FromBits(
            atomic_load_explicit(&gDriver.inputGainBits, memory_order_acquire));
        UInt64 unavailableFrame = kRingFrameUnpublished;
        YunRingReadResult result = ReadRingSpan(
            ring, inputStart, inIOBufferFrameSize, buffer, gain,
            &unavailableFrame);
        if (result == kRingReadUnsafe) {
            RecordUnsafeReadEvidence(
                inputStart, inIOBufferFrameSize, unavailableFrame);
            FailSilentIO(true, buffer, inIOBufferFrameSize);
        }
        YUN_DRIVER_IO_TEST_HOOK(false, inClientID, inOperationID);
        return 0;
    }

    if (isWrite) {
        Float32 gain = Float32FromBits(
            atomic_load_explicit(&gDriver.outputGainBits, memory_order_acquire));
        YunRingWriteAdmission admission = ClaimRingWriteSpan(
            ring, outputStart, inIOBufferFrameSize);
        if (admission == kRingWriteClaimed) {
            PublishRingWrite(
                ring, outputStart, inIOBufferFrameSize, buffer, gain);
        } else if (admission == kRingWriteUnsafe) {
            FailSilentIO(false, buffer, inIOBufferFrameSize);
        }
        YUN_DRIVER_IO_TEST_HOOK(false, inClientID, inOperationID);
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
