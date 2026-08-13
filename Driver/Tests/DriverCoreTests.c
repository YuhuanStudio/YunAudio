#include <assert.h>
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

// The driver is included into this pure process so its internal clock
// arithmetic is tested without loading it into coreaudiod or opening hardware.
#define YUNAUDIO_DRIVER_TESTING 1
#include "../Sources/YunAudioDriver.c"

static AudioServerPlugInDriverRef TestDriver(void) {
    return (AudioServerPlugInDriverRef)&gInterfacePtr;
}

static void TestQueryInterfaceClearsFailedOutput(void) {
    CFUUIDBytes unsupported = {
        0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0xFE,
        0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
    };
    LPVOID interface = (LPVOID)(uintptr_t)0x1;
    assert(Yun_QueryInterface(TestDriver(), unsupported, &interface) == E_NOINTERFACE);
    assert(interface == NULL);

    interface = (LPVOID)(uintptr_t)0x1;
    assert(Yun_QueryInterface(NULL, unsupported, &interface)
           == kAudioHardwareBadObjectError);
    assert(interface == NULL);

    CFUUIDBytes supported = CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID);
    UInt32 oldRefCount = gDriver.refCount;
    assert(Yun_QueryInterface(TestDriver(), supported, &interface) == S_OK);
    assert(interface == &gInterfacePtr);
    assert(gDriver.refCount == oldRefCount + 1);
    assert(Yun_Release(TestDriver()) == oldRefCount);
}

static void ExpectObjectListMatchesAdvertisedSize(
    AudioObjectID objectID,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope,
    const AudioObjectID *expected,
    UInt32 expectedCount
) {
    AudioObjectPropertyAddress address = {
        selector, scope, kAudioObjectPropertyElementMain,
    };
    UInt32 advertised = 0;
    assert(Yun_GetPropertyDataSize(
        TestDriver(), objectID, 1, &address, 0, NULL, &advertised) == 0);
    assert(advertised == expectedCount * sizeof(AudioObjectID));

    AudioObjectID values[8] = { 0 };
    UInt32 written = 0;
    assert(Yun_GetPropertyData(
        TestDriver(), objectID, 1, &address, 0, NULL,
        advertised, &written, values) == 0);
    assert(written == advertised);
    for (UInt32 index = 0; index < expectedCount; ++index) {
        assert(values[index] == expected[index]);
    }
}

static void TestObjectListSizesMatchTheirGetters(void) {
    const AudioObjectID inputOwned[] = {
        kObjectID_Stream_Input,
        kObjectID_Volume_Input_Master,
        kObjectID_Mute_Input_Master,
    };
    const AudioObjectID outputOwned[] = {
        kObjectID_Stream_Output,
        kObjectID_Volume_Output_Master,
        kObjectID_Mute_Output_Master,
    };
    const AudioObjectID allOwned[] = {
        kObjectID_Stream_Input,
        kObjectID_Stream_Output,
        kObjectID_Volume_Input_Master,
        kObjectID_Mute_Input_Master,
        kObjectID_Volume_Output_Master,
        kObjectID_Mute_Output_Master,
    };
    const AudioObjectID inputStream[] = { kObjectID_Stream_Input };
    const AudioObjectID outputStream[] = { kObjectID_Stream_Output };
    const AudioObjectID allStreams[] = {
        kObjectID_Stream_Input, kObjectID_Stream_Output,
    };

    ExpectObjectListMatchesAdvertisedSize(
        kObjectID_Device, kAudioObjectPropertyOwnedObjects,
        kAudioObjectPropertyScopeInput, inputOwned, 3);
    ExpectObjectListMatchesAdvertisedSize(
        kObjectID_Device, kAudioObjectPropertyOwnedObjects,
        kAudioObjectPropertyScopeOutput, outputOwned, 3);
    ExpectObjectListMatchesAdvertisedSize(
        kObjectID_Device, kAudioObjectPropertyOwnedObjects,
        kAudioObjectPropertyScopeGlobal, allOwned, 6);
    ExpectObjectListMatchesAdvertisedSize(
        kObjectID_Device, kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeInput, inputStream, 1);
    ExpectObjectListMatchesAdvertisedSize(
        kObjectID_Device, kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeOutput, outputStream, 1);
    ExpectObjectListMatchesAdvertisedSize(
        kObjectID_Device, kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeGlobal, allStreams, 2);
}

static void ExpectQualifiedOwnedObjects(
    AudioObjectID owner,
    AudioObjectPropertyScope scope,
    const AudioClassID *qualifier,
    UInt32 qualifierCount,
    const AudioObjectID *expected,
    UInt32 expectedCount
) {
    AudioObjectPropertyAddress address = {
        kAudioObjectPropertyOwnedObjects,
        scope,
        kAudioObjectPropertyElementMain,
    };
    UInt32 qualifierSize = qualifierCount * sizeof(AudioClassID);
    UInt32 advertised = UINT32_MAX;
    assert(Yun_GetPropertyDataSize(
        TestDriver(), owner, 1, &address,
        qualifierSize, qualifier, &advertised) == 0);
    assert(advertised == expectedCount * sizeof(AudioObjectID));

    AudioObjectID actual[8];
    for (UInt32 index = 0; index < 8; ++index) actual[index] = UINT32_MAX;
    UInt32 written = UINT32_MAX;
    assert(Yun_GetPropertyData(
        TestDriver(), owner, 1, &address,
        qualifierSize, qualifier, advertised, &written, actual) == 0);
    assert(written == advertised);
    for (UInt32 index = 0; index < expectedCount; ++index) {
        assert(actual[index] == expected[index]);
    }
    if (expectedCount < 8) assert(actual[expectedCount] == UINT32_MAX);
}

static void TestOwnedObjectsHonourEveryClassQualifier(void) {
    const AudioClassID deviceClass[] = { kAudioDeviceClassID };
    const AudioObjectID device[] = { kObjectID_Device };
    ExpectQualifiedOwnedObjects(
        kObjectID_PlugIn, kAudioObjectPropertyScopeGlobal,
        deviceClass, 1, device, 1);

    const AudioClassID streamClass[] = { kAudioStreamClassID };
    const AudioObjectID streams[] = {
        kObjectID_Stream_Input, kObjectID_Stream_Output,
    };
    ExpectQualifiedOwnedObjects(
        kObjectID_Device, kAudioObjectPropertyScopeGlobal,
        streamClass, 1, streams, 2);

    const AudioClassID controlClass[] = { kAudioControlClassID };
    const AudioObjectID controls[] = {
        kObjectID_Volume_Input_Master,
        kObjectID_Mute_Input_Master,
        kObjectID_Volume_Output_Master,
        kObjectID_Mute_Output_Master,
    };
    ExpectQualifiedOwnedObjects(
        kObjectID_Device, kAudioObjectPropertyScopeGlobal,
        controlClass, 1, controls, 4);

    const AudioClassID levelClass[] = { kAudioLevelControlClassID };
    const AudioObjectID levels[] = {
        kObjectID_Volume_Input_Master, kObjectID_Volume_Output_Master,
    };
    ExpectQualifiedOwnedObjects(
        kObjectID_Device, kAudioObjectPropertyScopeGlobal,
        levelClass, 1, levels, 2);

    const AudioClassID booleanClass[] = { kAudioBooleanControlClassID };
    const AudioObjectID booleans[] = {
        kObjectID_Mute_Input_Master, kObjectID_Mute_Output_Master,
    };
    ExpectQualifiedOwnedObjects(
        kObjectID_Device, kAudioObjectPropertyScopeGlobal,
        booleanClass, 1, booleans, 2);

    const AudioClassID volumeClass[] = { kAudioVolumeControlClassID };
    ExpectQualifiedOwnedObjects(
        kObjectID_Device, kAudioObjectPropertyScopeGlobal,
        volumeClass, 1, levels, 2);
    const AudioClassID muteClass[] = { kAudioMuteControlClassID };
    ExpectQualifiedOwnedObjects(
        kObjectID_Device, kAudioObjectPropertyScopeGlobal,
        muteClass, 1, booleans, 2);

    const AudioClassID mixedClasses[] = {
        kAudioStreamClassID, kAudioBooleanControlClassID,
    };
    const AudioObjectID mixed[] = {
        kObjectID_Stream_Input,
        kObjectID_Stream_Output,
        kObjectID_Mute_Input_Master,
        kObjectID_Mute_Output_Master,
    };
    ExpectQualifiedOwnedObjects(
        kObjectID_Device, kAudioObjectPropertyScopeGlobal,
        mixedClasses, 2, mixed, 4);

    const AudioClassID objectClass[] = { kAudioObjectClassID };
    const AudioObjectID inputObjects[] = {
        kObjectID_Stream_Input,
        kObjectID_Volume_Input_Master,
        kObjectID_Mute_Input_Master,
    };
    ExpectQualifiedOwnedObjects(
        kObjectID_Device, kAudioObjectPropertyScopeInput,
        objectClass, 1, inputObjects, 3);
    const AudioClassID wildcardClass[] = { kAudioObjectClassIDWildcard };
    ExpectQualifiedOwnedObjects(
        kObjectID_Device, kAudioObjectPropertyScopeInput,
        wildcardClass, 1, inputObjects, 3);

    const AudioClassID noMatch[] = { kAudioPlugInClassID };
    ExpectQualifiedOwnedObjects(
        kObjectID_Device, kAudioObjectPropertyScopeGlobal,
        noMatch, 1, NULL, 0);

    // The HAL passes qualifiers as opaque buffers. The filter must not rely on
    // AudioClassID alignment supplied by its caller.
    UInt8 unaligned[1 + sizeof(AudioClassID)] = { 0 };
    memcpy(unaligned + 1, streamClass, sizeof(AudioClassID));
    AudioObjectPropertyAddress address = {
        kAudioObjectPropertyOwnedObjects,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 advertised = 0;
    assert(Yun_GetPropertyDataSize(
        TestDriver(), kObjectID_Device, 1, &address,
        sizeof(AudioClassID), unaligned + 1, &advertised) == 0);
    assert(advertised == 2 * sizeof(AudioObjectID));

    assert(Yun_GetPropertyDataSize(
        TestDriver(), kObjectID_Device, 1, &address,
        sizeof(AudioClassID) - 1, streamClass, &advertised)
        == kAudioHardwareBadPropertySizeError);
    assert(Yun_GetPropertyDataSize(
        TestDriver(), kObjectID_Device, 1, &address,
        sizeof(AudioClassID), NULL, &advertised)
        == kAudioHardwareIllegalOperationError);
}

static void TestPropertyAccessIsClosedOverItsObjectMatrix(void) {
    struct {
        AudioObjectID objectID;
        AudioObjectPropertySelector selector;
    } invalid[] = {
        { kObjectID_PlugIn, kAudioDevicePropertyNominalSampleRate },
        { kObjectID_PlugIn, kAudioDevicePropertyLatency },
        { kObjectID_Device, kAudioPlugInPropertyDeviceList },
        { kObjectID_Device, kAudioStreamPropertyDirection },
        { kObjectID_Device, kAudioDevicePropertyLatency },
        { kObjectID_Device, kAudioDevicePropertySafetyOffset },
        { kObjectID_Device, kAudioDevicePropertyDeviceCanBeDefaultDevice },
        { kObjectID_Device, kAudioDevicePropertyPreferredChannelsForStereo },
        { kObjectID_Device, kAudioDevicePropertyPreferredChannelLayout },
        { kObjectID_Stream_Input, kAudioDevicePropertyBufferFrameSize },
        { kObjectID_Volume_Input_Master, kAudioBooleanControlPropertyValue },
        { kObjectID_Mute_Output_Master, kAudioLevelControlPropertyScalarValue },
        { kObjectID_Mute_Output_Master, kAudioDevicePropertyLatency },
    };

    for (UInt32 index = 0; index < sizeof(invalid) / sizeof(invalid[0]); ++index) {
        AudioObjectPropertyAddress address = {
            invalid[index].selector,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain,
        };
        assert(!Yun_HasProperty(
            TestDriver(), invalid[index].objectID, 1, &address));

        UInt32 size = UINT32_MAX;
        assert(Yun_GetPropertyDataSize(
            TestDriver(), invalid[index].objectID, 1, &address,
            0, NULL, &size) == kAudioHardwareUnknownPropertyError);
        assert(size == UINT32_MAX);

        Boolean settable = true;
        assert(Yun_IsPropertySettable(
            TestDriver(), invalid[index].objectID, 1, &address, &settable)
            == kAudioHardwareUnknownPropertyError);
        assert(settable);

        UInt64 value = UINT64_MAX;
        UInt32 written = UINT32_MAX;
        assert(Yun_GetPropertyData(
            TestDriver(), invalid[index].objectID, 1, &address,
            0, NULL, sizeof(value), &written, &value)
            == kAudioHardwareUnknownPropertyError);
        assert(value == UINT64_MAX);
        assert(written == UINT32_MAX);
    }

    AudioObjectPropertyAddress active = {
        kAudioStreamPropertyIsActive,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 enabled = 1;
    assert(Yun_SetPropertyData(
        TestDriver(), kObjectID_Device, 1, &active,
        0, NULL, sizeof(enabled), &enabled)
        == kAudioHardwareUnknownPropertyError);
    assert(Yun_SetPropertyData(
        TestDriver(), kObjectID_Stream_Input, 1, &active,
        0, NULL, sizeof(UInt16), &enabled)
        == kAudioHardwareBadPropertySizeError);
}

static void TestTimestampCatchesUpEveryMissedPeriod(void) {
    assert(TimestampPeriodAtHostTime(1000, 999, 100.0) == 0);
    assert(TimestampPeriodAtHostTime(1000, 1000, 100.0) == 0);
    assert(TimestampPeriodAtHostTime(1000, 1099, 100.0) == 0);
    assert(TimestampPeriodAtHostTime(1000, 1100, 100.0) == 1);
    assert(TimestampPeriodAtHostTime(1000, 2100, 100.0) == 11);
}

static void TestNominalRebaseKeepsTheTimelineContinuous(void) {
    UInt64 rebased = RebasedAnchorHostTime(1000, 100.0, 80.0, 1500);
    assert(rebased == 1100);

    UInt64 period = TimestampPeriodAtHostTime(rebased, 2300, 80.0);
    assert(period == 15);
    assert(rebased + (UInt64)((Float64)period * 80.0) == 2300);
}

static void TestRealtimeAtomicsAreActuallyLockFree(void) {
    YunRingFrame ringFrame;
    atomic_init(&ringFrame.owner, 0);
    atomic_init(&ringFrame.sampleFrame, 0);
    atomic_init(&ringFrame.stereoBits, 0);
    assert(atomic_is_lock_free(&gDriver.inputGainBits));
    assert(atomic_is_lock_free(&gDriver.outputGainBits));
    assert(atomic_is_lock_free(&gDriver.publishedClock.version));
    assert(atomic_is_lock_free(&gDriver.publishedClock.hostTicksPerFrameBits));
    assert(atomic_is_lock_free(&ringFrame.owner));
    assert(atomic_is_lock_free(&ringFrame.sampleFrame));
    assert(atomic_is_lock_free(&ringFrame.stereoBits));
}

static void TestControlChangesPublishOneCoherentEffectiveGain(void) {
    AudioServerPlugInDriverRef driver = TestDriver();
    AudioObjectPropertyAddress volume = {
        kAudioLevelControlPropertyScalarValue,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    Float32 scalar = 0.5f;
    assert(Yun_SetPropertyData(
        driver, kObjectID_Volume_Input_Master, 1, &volume, 0, NULL,
        sizeof(scalar), &scalar) == 0);
    Float32 expected = ScalarToGain(scalar);
    Float32 actual = Float32FromBits(atomic_load_explicit(
        &gDriver.inputGainBits, memory_order_acquire));
    assert(fabsf(actual - expected) < 0.000001f);

    AudioObjectPropertyAddress mute = {
        kAudioBooleanControlPropertyValue,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 muted = 1;
    assert(Yun_SetPropertyData(
        driver, kObjectID_Mute_Input_Master, 1, &mute, 0, NULL,
        sizeof(muted), &muted) == 0);
    assert(Float32FromBits(atomic_load_explicit(
        &gDriver.inputGainBits, memory_order_acquire)) == 0.0f);

    muted = 0;
    assert(Yun_SetPropertyData(
        driver, kObjectID_Mute_Input_Master, 1, &mute, 0, NULL,
        sizeof(muted), &muted) == 0);
    actual = Float32FromBits(atomic_load_explicit(
        &gDriver.inputGainBits, memory_order_acquire));
    assert(fabsf(actual - expected) < 0.000001f);
}

static UInt32 sPropertiesChangedCalls;
static AudioObjectID sChangedObjectIDs[4];
static UInt32 sChangedAddressCounts[4];
static AudioObjectPropertyAddress sChangedAddresses[4][2];

static OSStatus TestPropertiesChanged(
    AudioServerPlugInHostRef host,
    AudioObjectID objectID,
    UInt32 numberAddresses,
    const AudioObjectPropertyAddress *addresses
) {
    (void)host;
    assert(sPropertiesChangedCalls < 4);
    assert(numberAddresses <= 2);
    UInt32 call = sPropertiesChangedCalls++;
    sChangedObjectIDs[call] = objectID;
    sChangedAddressCounts[call] = numberAddresses;
    for (UInt32 index = 0; index < numberAddresses; ++index) {
        sChangedAddresses[call][index] = addresses[index];
    }
    return 0;
}

static void TestPropertyNotificationsAreCompleteAndNullSafe(void) {
    AudioServerPlugInHostRef precedingHost = gDriver.host;
    AudioServerPlugInHostInterface notificationHost = {
        .PropertiesChanged = TestPropertiesChanged,
    };
    sPropertiesChangedCalls = 0;
    gDriver.host = &notificationHost;
    gDriver.inputVolume = 1.0f;
    gDriver.inputMuted = false;
    atomic_store_explicit(
        &gDriver.inputGainBits, Float32Bits(1.0f), memory_order_release);

    AudioObjectPropertyAddress volume = {
        kAudioLevelControlPropertyScalarValue,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    Float32 scalar = 0.25f;
    assert(Yun_SetPropertyData(
        TestDriver(), kObjectID_Volume_Input_Master, 1, &volume,
        0, NULL, sizeof(scalar), &scalar) == 0);
    assert(sPropertiesChangedCalls == 1);
    assert(sChangedObjectIDs[0] == kObjectID_Volume_Input_Master);
    assert(sChangedAddressCounts[0] == 2);
    assert(sChangedAddresses[0][0].mSelector
           == kAudioLevelControlPropertyScalarValue);
    assert(sChangedAddresses[0][1].mSelector
           == kAudioLevelControlPropertyDecibelValue);

    // Idempotent writes do not wake every observer in the audio server.
    assert(Yun_SetPropertyData(
        TestDriver(), kObjectID_Volume_Input_Master, 1, &volume,
        0, NULL, sizeof(scalar), &scalar) == 0);
    assert(sPropertiesChangedCalls == 1);

    AudioObjectPropertyAddress mute = {
        kAudioBooleanControlPropertyValue,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 muted = 1;
    assert(Yun_SetPropertyData(
        TestDriver(), kObjectID_Mute_Input_Master, 1, &mute,
        0, NULL, sizeof(muted), &muted) == 0);
    assert(sPropertiesChangedCalls == 2);
    assert(sChangedObjectIDs[1] == kObjectID_Mute_Input_Master);
    assert(sChangedAddressCounts[1] == 1);
    assert(sChangedAddresses[1][0].mSelector
           == kAudioBooleanControlPropertyValue);

    AudioObjectPropertyAddress streamActive = {
        kAudioStreamPropertyIsActive,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    gDriver.inputStreamIsActive = true;
    UInt32 active = 0;
    assert(Yun_SetPropertyData(
        TestDriver(), kObjectID_Stream_Input, 1, &streamActive,
        0, NULL, sizeof(active), &active) == 0);
    assert(sPropertiesChangedCalls == 3);
    assert(sChangedObjectIDs[2] == kObjectID_Stream_Input);
    assert(sChangedAddressCounts[2] == 1);
    assert(sChangedAddresses[2][0].mSelector
           == kAudioStreamPropertyIsActive);

    UInt32 reportedActive = UINT32_MAX;
    UInt32 written = 0;
    assert(Yun_GetPropertyData(
        TestDriver(), kObjectID_Stream_Input, 1, &streamActive,
        0, NULL, sizeof(reportedActive), &written, &reportedActive) == 0);
    assert(written == sizeof(reportedActive));
    assert(reportedActive == 0);

    assert(Yun_SetPropertyData(
        TestDriver(), kObjectID_Stream_Input, 1, &streamActive,
        0, NULL, sizeof(active), &active) == 0);
    assert(sPropertiesChangedCalls == 3);

    // A malformed host table must not turn a harmless control write into a
    // process-wide null call. The real host supplies this callback, but the
    // guard contains damage if lifecycle state is ever torn down out of order.
    AudioServerPlugInHostInterface missingCallbackHost = { 0 };
    gDriver.host = &missingCallbackHost;
    scalar = 0.5f;
    assert(Yun_SetPropertyData(
        TestDriver(), kObjectID_Volume_Input_Master, 1, &volume,
        0, NULL, sizeof(scalar), &scalar) == 0);
    assert(gDriver.inputVolume == 0.5f);
    assert(sPropertiesChangedCalls == 3);

    gDriver.inputStreamIsActive = true;
    gDriver.host = precedingHost;
}

static void TestNonFiniteControlsNeverReachStoredOrPublishedState(void) {
    AudioObjectPropertyAddress scalarAddress = {
        kAudioLevelControlPropertyScalarValue,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    Float32 belowRange = -1.0f;
    assert(Yun_SetPropertyData(
        TestDriver(), kObjectID_Volume_Output_Master, 1, &scalarAddress,
        0, NULL, sizeof(belowRange), &belowRange) == 0);
    assert(gDriver.outputVolume == 0.0f);
    assert(Float32FromBits(atomic_load_explicit(
        &gDriver.outputGainBits, memory_order_acquire)) == 0.0f);

    Float32 aboveRange = 2.0f;
    assert(Yun_SetPropertyData(
        TestDriver(), kObjectID_Volume_Output_Master, 1, &scalarAddress,
        0, NULL, sizeof(aboveRange), &aboveRange) == 0);
    assert(gDriver.outputVolume == 1.0f);
    assert(Float32FromBits(atomic_load_explicit(
        &gDriver.outputGainBits, memory_order_acquire)) == 1.0f);

    Float32 baseline = 0.25f;
    assert(Yun_SetPropertyData(
        TestDriver(), kObjectID_Volume_Output_Master, 1, &scalarAddress,
        0, NULL, sizeof(baseline), &baseline) == 0);
    UInt32 baselineGain = atomic_load_explicit(
        &gDriver.outputGainBits, memory_order_acquire);

    const Float32 invalidScalars[] = { NAN, INFINITY, -INFINITY };
    for (UInt32 index = 0; index < 3; ++index) {
        Float32 invalid = invalidScalars[index];
        assert(Yun_SetPropertyData(
            TestDriver(), kObjectID_Volume_Output_Master, 1, &scalarAddress,
            0, NULL, sizeof(invalid), &invalid)
            == kAudioHardwareIllegalOperationError);
        assert(gDriver.outputVolume == baseline);
        assert(atomic_load_explicit(
            &gDriver.outputGainBits, memory_order_acquire) == baselineGain);
    }

    AudioObjectPropertyAddress decibelAddress = scalarAddress;
    decibelAddress.mSelector = kAudioLevelControlPropertyDecibelValue;
    Float32 invalidDecibels = INFINITY;
    assert(Yun_SetPropertyData(
        TestDriver(), kObjectID_Volume_Output_Master, 1, &decibelAddress,
        0, NULL, sizeof(invalidDecibels), &invalidDecibels)
        == kAudioHardwareIllegalOperationError);
    assert(gDriver.outputVolume == baseline);

    AudioObjectPropertyAddress conversion = scalarAddress;
    conversion.mSelector = kAudioLevelControlPropertyConvertScalarToDecibels;
    Float32 converted = NAN;
    UInt32 convertedSize = sizeof(converted);
    assert(Yun_GetPropertyData(
        TestDriver(), kObjectID_Volume_Output_Master, 1, &conversion,
        0, NULL, sizeof(converted), &convertedSize, &converted)
        == kAudioHardwareIllegalOperationError);
}

static CFDictionaryRef AnchorDictionaryWithHostNumber(
    Float64 sampleTime, CFNumberRef hostTime, Float64 sampleRate) {
    const void *keys[] = {
        CFSTR(kYunAnchorKey_SampleTime),
        CFSTR(kYunAnchorKey_HostTime),
        CFSTR(kYunAnchorKey_SampleRate),
    };
    CFNumberRef numbers[] = {
        CFNumberCreate(NULL, kCFNumberDoubleType, &sampleTime),
        hostTime,
        CFNumberCreate(NULL, kCFNumberDoubleType, &sampleRate),
    };
    assert(numbers[0] != NULL && numbers[1] != NULL && numbers[2] != NULL);
    CFDictionaryRef dictionary = CFDictionaryCreate(
        NULL, keys, (const void **)numbers, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(numbers[0]);
    CFRelease(numbers[2]);
    assert(dictionary != NULL);
    return dictionary;
}

static CFDictionaryRef AnchorDictionary(
    Float64 sampleTime, Float64 hostTime, Float64 sampleRate
) {
    CFNumberRef hostNumber = CFNumberCreate(NULL, kCFNumberDoubleType, &hostTime);
    assert(hostNumber != NULL);
    CFDictionaryRef dictionary =
        AnchorDictionaryWithHostNumber(sampleTime, hostNumber, sampleRate);
    CFRelease(hostNumber);
    return dictionary;
}

static CFDictionaryRef IntegerAnchorDictionary(
    Float64 sampleTime, SInt64 hostTime, Float64 sampleRate
) {
    CFNumberRef hostNumber = CFNumberCreate(NULL, kCFNumberSInt64Type, &hostTime);
    assert(hostNumber != NULL);
    CFDictionaryRef dictionary =
        AnchorDictionaryWithHostNumber(sampleTime, hostNumber, sampleRate);
    CFRelease(hostNumber);
    return dictionary;
}

static void TestClockAnchorRejectsNonFiniteAndOutOfRangeNumbers(void) {
    Float64 sampleTime = 0.0;
    Float64 sampleRate = 0.0;
    UInt64 hostTime = 0;

    CFDictionaryRef valid = AnchorDictionary(1024.0, 2048.0, 48000.0);
    assert(ReadAnchorDictionary(valid, &sampleTime, &hostTime, &sampleRate));
    assert(sampleTime == 1024.0);
    assert(hostTime == 2048);
    assert(sampleRate == 48000.0);
    CFRelease(valid);

    CFDictionaryRef beyondDoubleInteger =
        IntegerAnchorDictionary(1024.0, INT64_C(9007199254740993), 48000.0);
    assert(ReadAnchorDictionary(
        beyondDoubleInteger, &sampleTime, &hostTime, &sampleRate));
    assert(hostTime == UINT64_C(9007199254740993));
    CFRelease(beyondDoubleInteger);

    CFDictionaryRef signedMaximum =
        IntegerAnchorDictionary(1024.0, INT64_MAX, 48000.0);
    assert(ReadAnchorDictionary(signedMaximum, &sampleTime, &hostTime, &sampleRate));
    assert(hostTime == (UInt64)INT64_MAX);
    CFRelease(signedMaximum);

    CFDictionaryRef negativeInteger =
        IntegerAnchorDictionary(1024.0, -1, 48000.0);
    assert(!ReadAnchorDictionary(
        negativeInteger, &sampleTime, &hostTime, &sampleRate));
    CFRelease(negativeInteger);

    CFDictionaryRef exactLegacy = AnchorDictionary(1024.0, 0x1p53 + 2.0, 48000.0);
    assert(ReadAnchorDictionary(exactLegacy, &sampleTime, &hostTime, &sampleRate));
    assert(hostTime == UINT64_C(9007199254740994));
    CFRelease(exactLegacy);

    CFDictionaryRef fractionalLegacy = AnchorDictionary(1024.0, 2048.5, 48000.0);
    assert(!ReadAnchorDictionary(
        fractionalLegacy, &sampleTime, &hostTime, &sampleRate));
    CFRelease(fractionalLegacy);

    const Float64 invalid[][3] = {
        { NAN, 2048.0, 48000.0 },
        { INFINITY, 2048.0, 48000.0 },
        { -1.0, 2048.0, 48000.0 },
        { 1024.0, INFINITY, 48000.0 },
        { 1024.0, -1.0, 48000.0 },
        { 1024.0, 0x1p63, 48000.0 },
        { 1024.0, 2048.0, NAN },
        { 1024.0, 2048.0, INFINITY },
        { 1024.0, 2048.0, 0.0 },
        { 1024.0, 2048.0, 768001.0 },
    };
    for (UInt32 index = 0; index < sizeof(invalid) / sizeof(invalid[0]); ++index) {
        CFDictionaryRef dictionary = AnchorDictionary(
            invalid[index][0], invalid[index][1], invalid[index][2]);
        assert(!ReadAnchorDictionary(dictionary, &sampleTime, &hostTime, &sampleRate));
        CFRelease(dictionary);
    }
}

static OSStatus sRequestStatus;
static UInt64 sRequestedActions[8];
static UInt32 sRequestCount;
static bool sPerformRequestSynchronously;
static bool sInspectRequestBoundaryLocks;
static bool sRequestBoundaryConfigurationMutexWasFree;
static bool sRequestBoundaryStateMutexWasFree;
static Float64 sReentrantSampleRate;
static OSStatus sReentrantSampleRateStatus;
static bool sReinitializeSynchronously;
static pthread_mutex_t sRequestGateMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t sRequestGateCondition = PTHREAD_COND_INITIALIZER;
static bool sBlockRequestReturn;
static bool sRequestEntered;
static bool sReleaseRequest;

static OSStatus SetNominalSampleRate(Float64 rate);
static AudioServerPlugInHostInterface sTestHost;

static OSStatus TestRequestDeviceConfigurationChange(
    AudioServerPlugInHostRef host,
    AudioObjectID deviceObjectID,
    UInt64 changeAction,
    void *changeInfo
) {
    (void)host;
    assert(deviceObjectID == kObjectID_Device);
    assert(changeInfo == NULL);
    assert(sRequestCount < sizeof(sRequestedActions) / sizeof(sRequestedActions[0]));
    sRequestedActions[sRequestCount++] = changeAction;
    if (sInspectRequestBoundaryLocks) {
        int configurationResult = pthread_mutex_trylock(
            &gDriver.configurationRequestMutex);
        sRequestBoundaryConfigurationMutexWasFree = configurationResult == 0;
        if (configurationResult == 0) {
            pthread_mutex_unlock(&gDriver.configurationRequestMutex);
        }
        int stateResult = pthread_mutex_trylock(&gDriver.stateMutex);
        sRequestBoundaryStateMutexWasFree = stateResult == 0;
        if (stateResult == 0) pthread_mutex_unlock(&gDriver.stateMutex);
    }
    if (sPerformRequestSynchronously) {
        assert(Yun_PerformDeviceConfigurationChange(
            TestDriver(), kObjectID_Device, changeAction, NULL) == 0);
    }
    if (sReentrantSampleRate != 0.0) {
        Float64 reentrantRate = sReentrantSampleRate;
        sReentrantSampleRate = 0.0;
        sReentrantSampleRateStatus = SetNominalSampleRate(reentrantRate);
    }
    if (sReinitializeSynchronously) {
        sReinitializeSynchronously = false;
        assert(Yun_Initialize(TestDriver(), &sTestHost) == 0);
    }
    if (sBlockRequestReturn) {
        pthread_mutex_lock(&sRequestGateMutex);
        sRequestEntered = true;
        pthread_cond_broadcast(&sRequestGateCondition);
        while (!sReleaseRequest) {
            pthread_cond_wait(&sRequestGateCondition, &sRequestGateMutex);
        }
        pthread_mutex_unlock(&sRequestGateMutex);
    }
    return sRequestStatus;
}

static AudioServerPlugInHostInterface sTestHost = {
    .RequestDeviceConfigurationChange = TestRequestDeviceConfigurationChange,
};

static OSStatus SetNominalSampleRate(Float64 rate) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    return Yun_SetPropertyData(
        TestDriver(), kObjectID_Device, 1, &address,
        0, NULL, sizeof(rate), &rate);
}

typedef struct {
    Float64 rate;
    OSStatus result;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    bool entered;
} SampleRateThread;

typedef struct {
    UInt32 mutationCount;
    OSStatus result;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    bool finished;
} SampleRateBurst;

static void *SetSampleRateOnThread(void *context) {
    SampleRateThread *thread = (SampleRateThread *)context;
    pthread_mutex_lock(&thread->mutex);
    thread->entered = true;
    pthread_cond_broadcast(&thread->condition);
    pthread_mutex_unlock(&thread->mutex);
    thread->result = SetNominalSampleRate(thread->rate);
    return NULL;
}

static void *SetSampleRateBurstOnThread(void *context) {
    SampleRateBurst *burst = (SampleRateBurst *)context;
    const Float64 rates[] = { 44100.0, 48000.0, 88200.0, 96000.0 };
    for (UInt32 index = 1; index <= burst->mutationCount; ++index) {
        OSStatus status = SetNominalSampleRate(
            rates[index % (sizeof(rates) / sizeof(rates[0]))]);
        if (burst->result == 0 && status != 0) burst->result = status;
    }
    pthread_mutex_lock(&burst->mutex);
    burst->finished = true;
    pthread_cond_broadcast(&burst->condition);
    pthread_mutex_unlock(&burst->mutex);
    return NULL;
}

static bool WaitForBurstBeforeDeadline(SampleRateBurst *burst, time_t seconds) {
    struct timespec deadline;
    assert(clock_gettime(CLOCK_REALTIME, &deadline) == 0);
    deadline.tv_sec += seconds;

    pthread_mutex_lock(&burst->mutex);
    while (!burst->finished) {
        int status = pthread_cond_timedwait(
            &burst->condition, &burst->mutex, &deadline);
        if (status == ETIMEDOUT) break;
        assert(status == 0);
    }
    bool finished = burst->finished;
    pthread_mutex_unlock(&burst->mutex);
    return finished;
}

static void TestStreamFormatMustMatchTheCallbackLayoutExactly(void) {
    AudioStreamBasicDescription canonical;
    FillStreamDescription(&canonical, kDevice_DefaultSampleRate);
    assert(IsCanonicalStreamDescription(&canonical));
    assert(canonical.mFormatFlags == kAudioFormatFlagsNativeFloatPacked);
    assert(canonical.mBytesPerFrame
           == kDevice_ChannelCount * sizeof(Float32));

    AudioObjectPropertyAddress address = {
        kAudioStreamPropertyVirtualFormat,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    gDriver.sampleRate = kDevice_DefaultSampleRate;
    gDriver.host = NULL;
    assert(Yun_SetPropertyData(
        TestDriver(), kObjectID_Stream_Input, 1, &address,
        0, NULL, sizeof(canonical), &canonical) == 0);

    AudioStreamBasicDescription invalid = canonical;
    invalid.mFormatFlags |= kAudioFormatFlagIsNonInterleaved;
    assert(Yun_SetPropertyData(
        TestDriver(), kObjectID_Stream_Input, 1, &address,
        0, NULL, sizeof(invalid), &invalid) == kAudioDeviceUnsupportedFormatError);

    invalid = canonical;
    invalid.mBytesPerFrame = sizeof(Float32);
    assert(Yun_SetPropertyData(
        TestDriver(), kObjectID_Stream_Output, 1, &address,
        0, NULL, sizeof(invalid), &invalid) == kAudioDeviceUnsupportedFormatError);

    invalid = canonical;
    invalid.mFramesPerPacket = 2;
    assert(Yun_SetPropertyData(
        TestDriver(), kObjectID_Stream_Output, 1, &address,
        0, NULL, sizeof(invalid), &invalid) == kAudioDeviceUnsupportedFormatError);

    invalid = canonical;
    invalid.mSampleRate = NAN;
    assert(Yun_SetPropertyData(
        TestDriver(), kObjectID_Stream_Output, 1, &address,
        0, NULL, sizeof(invalid), &invalid) == kAudioDeviceUnsupportedFormatError);
}

static void TestConfigurationRequestsAreStatusCheckedAndGenerationBound(void) {
    gDriver.host = &sTestHost;
    gDriver.sampleRate = kDevice_DefaultSampleRate;
    gDriver.pendingSampleRate = 0.0;
    gDriver.pendingConfigurationGeneration = 0;
    gDriver.configurationRequestInFlightGeneration = 0;
    gDriver.nextConfigurationGeneration = 100;
    sRequestCount = 0;
    sPerformRequestSynchronously = false;
    sBlockRequestReturn = false;

    sRequestStatus = kAudioHardwareUnspecifiedError;
    assert(SetNominalSampleRate(96000.0) == kAudioHardwareUnspecifiedError);
    assert(sRequestCount == 1);
    assert(gDriver.sampleRate == kDevice_DefaultSampleRate);
    assert(gDriver.pendingSampleRate == 0.0);
    assert(gDriver.pendingConfigurationGeneration == 0);

    sRequestStatus = 0;
    assert(SetNominalSampleRate(44100.0) == 0);
    assert(sRequestCount == 2);
    UInt64 first = sRequestedActions[1];
    assert(first != 0);
    assert(gDriver.pendingSampleRate == 44100.0);
    assert(gDriver.pendingConfigurationGeneration == first);

    // A burst updates the desired value behind the one outstanding host
    // action. It must not orphan the first action by allocating a second
    // generation into the single pending slot.
    assert(SetNominalSampleRate(96000.0) == 0);
    assert(sRequestCount == 2);
    assert(gDriver.pendingSampleRate == 96000.0);
    assert(gDriver.pendingConfigurationGeneration == first);

    UInt64 stale = first + 1;
    assert(Yun_PerformDeviceConfigurationChange(
        TestDriver(), kObjectID_Device, stale, NULL) == 0);
    assert(Yun_AbortDeviceConfigurationChange(
        TestDriver(), kObjectID_Device, stale, NULL) == 0);
    assert(gDriver.sampleRate == kDevice_DefaultSampleRate);
    assert(gDriver.pendingConfigurationGeneration == first);

    assert(Yun_PerformDeviceConfigurationChange(
        TestDriver(), kObjectID_Device, first, NULL) == 0);
    assert(gDriver.sampleRate == 96000.0);
    assert(gDriver.pendingSampleRate == 0.0);
    assert(gDriver.pendingConfigurationGeneration == 0);

    UInt32 beforeNoChange = sRequestCount;
    assert(SetNominalSampleRate(96000.0) == 0);
    assert(sRequestCount == beforeNoChange);

    assert(SetNominalSampleRate(48000.0) == 0);
    UInt64 aborted = sRequestedActions[sRequestCount - 1];
    assert(Yun_AbortDeviceConfigurationChange(
        TestDriver(), kObjectID_Device, aborted, NULL) == 0);
    assert(gDriver.sampleRate == 96000.0);
    assert(gDriver.pendingConfigurationGeneration == 0);

    assert(SetNominalSampleRate(48000.0) == 0);
    UInt64 precedingLifetime = sRequestedActions[sRequestCount - 1];
    assert(Yun_Initialize(TestDriver(), &sTestHost) == 0);
    assert(gDriver.pendingConfigurationGeneration == 0);
    assert(Yun_PerformDeviceConfigurationChange(
        TestDriver(), kObjectID_Device, precedingLifetime, NULL) == 0);
    assert(Yun_AbortDeviceConfigurationChange(
        TestDriver(), kObjectID_Device, precedingLifetime, NULL) == 0);
    assert(gDriver.sampleRate == 96000.0);
    free(gDriver.ringBuffer);
    gDriver.ringBuffer = NULL;

    gDriver.host = NULL;
    assert(SetNominalSampleRate(48000.0) == kAudioHardwareNotReadyError);
    assert(gDriver.pendingConfigurationGeneration == 0);
}

static void TestConfigurationRequestNeverHoldsDriverLocksAcrossHostReentry(void) {
    gDriver.host = &sTestHost;
    gDriver.sampleRate = kDevice_DefaultSampleRate;
    gDriver.pendingSampleRate = 0.0;
    gDriver.pendingConfigurationGeneration = 0;
    gDriver.configurationRequestInFlightGeneration = 0;
    sRequestCount = 0;
    sRequestStatus = 0;
    sPerformRequestSynchronously = false;
    sInspectRequestBoundaryLocks = true;
    sRequestBoundaryConfigurationMutexWasFree = false;
    sRequestBoundaryStateMutexWasFree = false;

    pthread_mutex_lock(&sRequestGateMutex);
    sBlockRequestReturn = true;
    sRequestEntered = false;
    sReleaseRequest = false;
    pthread_mutex_unlock(&sRequestGateMutex);

    SampleRateThread first = {
        .rate = 44100.0,
        .result = -1,
        .mutex = PTHREAD_MUTEX_INITIALIZER,
        .condition = PTHREAD_COND_INITIALIZER,
    };
    SampleRateBurst burst = {
        .mutationCount = 99999,
        .result = 0,
        .mutex = PTHREAD_MUTEX_INITIALIZER,
        .condition = PTHREAD_COND_INITIALIZER,
    };
    pthread_t firstThread;
    pthread_t burstThread;
    assert(pthread_create(&firstThread, NULL, SetSampleRateOnThread, &first) == 0);

    pthread_mutex_lock(&sRequestGateMutex);
    while (!sRequestEntered) {
        pthread_cond_wait(&sRequestGateCondition, &sRequestGateMutex);
    }
    pthread_mutex_unlock(&sRequestGateMutex);

    assert(pthread_create(&burstThread, NULL, SetSampleRateBurstOnThread, &burst) == 0);
    bool burstFinishedBeforeHostReturned = WaitForBurstBeforeDeadline(&burst, 2);

    pthread_mutex_lock(&sRequestGateMutex);
    sReleaseRequest = true;
    pthread_cond_broadcast(&sRequestGateCondition);
    pthread_mutex_unlock(&sRequestGateMutex);

    assert(pthread_join(firstThread, NULL) == 0);
    assert(pthread_join(burstThread, NULL) == 0);
    assert(first.result == 0);
    assert(burst.result == 0);
    assert(burstFinishedBeforeHostReturned);
    assert(sRequestBoundaryConfigurationMutexWasFree);
    assert(sRequestBoundaryStateMutexWasFree);
    // One host request absorbs 100,000 setter mutations and commits the final
    // desired rate. A lock held across the fake host call misses the deadline.
    assert(sRequestCount == 1);
    UInt64 action = sRequestedActions[0];
    assert(gDriver.pendingConfigurationGeneration == action);
    assert(gDriver.pendingSampleRate == 96000.0);
    assert(Yun_PerformDeviceConfigurationChange(
        TestDriver(), kObjectID_Device, action, NULL) == 0);
    assert(gDriver.sampleRate == 96000.0);

    pthread_mutex_lock(&sRequestGateMutex);
    sBlockRequestReturn = false;
    pthread_mutex_unlock(&sRequestGateMutex);

    // RequestDeviceConfigurationChange may synchronously perform an action.
    // The request mutex must not be part of the callback's lock graph.
    gDriver.sampleRate = 48000.0;
    gDriver.pendingSampleRate = 0.0;
    gDriver.pendingConfigurationGeneration = 0;
    gDriver.configurationRequestInFlightGeneration = 0;
    sRequestCount = 0;
    sPerformRequestSynchronously = true;
    sReentrantSampleRate = 44100.0;
    sReentrantSampleRateStatus = -1;
    assert(SetNominalSampleRate(44100.0) == 0);
    assert(sReentrantSampleRateStatus == 0);
    assert(sRequestCount == 1);
    assert(gDriver.sampleRate == 44100.0);
    assert(gDriver.pendingSampleRate == 0.0);

    gDriver.sampleRate = 48000.0;
    sRequestCount = 0;
    sReentrantSampleRate = 96000.0;
    sReentrantSampleRateStatus = -1;
    assert(SetNominalSampleRate(44100.0) == 0);
    assert(sReentrantSampleRateStatus == 0);
    assert(sRequestCount == 2);
    assert(sRequestedActions[0] != sRequestedActions[1]);
    assert(gDriver.sampleRate == 96000.0);
    assert(gDriver.pendingConfigurationGeneration == 0);
    assert(gDriver.configurationRequestInFlightGeneration == 0);
    sPerformRequestSynchronously = false;
    sInspectRequestBoundaryLocks = false;

    gDriver.sampleRate = 48000.0;
    gDriver.pendingSampleRate = 0.0;
    gDriver.pendingConfigurationGeneration = 0;
    gDriver.configurationRequestInFlightGeneration = 0;
    sRequestCount = 0;
    sReinitializeSynchronously = true;
    assert(SetNominalSampleRate(44100.0) == kAudioHardwareNotReadyError);
    assert(sRequestCount == 1);
    assert(gDriver.sampleRate == 48000.0);
    assert(gDriver.pendingSampleRate == 0.0);
    assert(gDriver.pendingConfigurationGeneration == 0);
    assert(gDriver.configurationRequestInFlightGeneration == 0);
    free(gDriver.ringBuffer);
    gDriver.ringBuffer = NULL;

    pthread_mutex_destroy(&first.mutex);
    pthread_cond_destroy(&first.condition);
    pthread_mutex_destroy(&burst.mutex);
    pthread_cond_destroy(&burst.condition);
}

static void TestTranslateUIDRejectsMalformedQualifiers(void) {
    AudioObjectPropertyAddress address = {
        kAudioPlugInPropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioObjectID translated = 99;
    UInt32 written = 0;
    assert(Yun_GetPropertyData(
        TestDriver(), kObjectID_PlugIn, 1, &address,
        sizeof(CFStringRef), NULL, sizeof(translated), &written, &translated)
        == kAudioHardwareIllegalOperationError);
    assert(translated == 99);

    SInt32 numberValue = 7;
    CFNumberRef number = CFNumberCreate(
        NULL, kCFNumberSInt32Type, &numberValue);
    assert(number != NULL);
    CFTypeRef wrongType = number;
    assert(Yun_GetPropertyData(
        TestDriver(), kObjectID_PlugIn, 1, &address,
        sizeof(wrongType), &wrongType,
        sizeof(translated), &written, &translated)
        == kAudioHardwareIllegalOperationError);
    assert(translated == 99);
    CFRelease(number);
}

static void TestPublishedClockRoundTripsEveryField(void) {
    gDriver.anchorHostTime = 123456;
    gDriver.hostTicksPerFrame = 20.25;
    gDriver.nominalTicksPerFrame = 20.5;
    gDriver.lastAnchorReceivedAt = 120000;
    gDriver.anchorTimeoutTicks = 2000;
    gDriver.isClockFollowing = true;
    gDriver.clockSeed = 17;
    PublishClockState_Locked();

    YunClockSnapshot clock = ReadPublishedClock();
    assert(clock.anchorHostTime == 123456);
    assert(clock.hostTicksPerFrame == 20.25);
    assert(clock.nominalTicksPerFrame == 20.5);
    assert(clock.lastAnchorReceivedAt == 120000);
    assert(clock.anchorTimeoutTicks == 2000);
    assert(clock.isClockFollowing);
    assert(clock.seed == 17);
}

static AudioServerPlugInIOCycleInfo CycleAt(Float64 inputTime, Float64 outputTime) {
    AudioServerPlugInIOCycleInfo cycle = { 0 };
    cycle.mInputTime.mSampleTime = inputTime;
    cycle.mOutputTime.mSampleTime = outputTime;
    return cycle;
}

static void FillSignal(Float32 *buffer, UInt32 frames, Float32 offset) {
    for (UInt32 frame = 0; frame < frames; ++frame) {
        buffer[frame * kDevice_ChannelCount] = offset + (Float32)frame / 1024.0f;
        buffer[frame * kDevice_ChannelCount + 1] =
            -offset - (Float32)frame / 2048.0f;
    }
}

static void ExpectSignalEqual(const Float32 *actual,
                              const Float32 *expected,
                              UInt32 frames) {
    for (UInt32 index = 0; index < frames * kDevice_ChannelCount; ++index) {
        assert(actual[index] == expected[index]);
    }
}

static void PutSignalInRing(const Float32 *signal, UInt32 frames, UInt64 startFrame) {
    for (UInt32 frame = 0; frame < frames; ++frame) {
        UInt64 absoluteFrame = startFrame + frame;
        UInt64 slot = absoluteFrame & kRingBufferMask;
        atomic_store_explicit(
            &gDriver.ringBuffer[slot].stereoBits,
            PackStereoFrame(&signal[frame * kDevice_ChannelCount]),
            memory_order_seq_cst);
        atomic_store_explicit(
            &gDriver.ringBuffer[slot].sampleFrame, absoluteFrame,
            memory_order_seq_cst);
    }
}

static void ExpectRingSignal(
    const Float32 *expected, UInt32 frames, UInt64 startFrame
) {
    for (UInt32 frame = 0; frame < frames; ++frame) {
        UInt64 absoluteFrame = startFrame + frame;
        UInt64 slot = absoluteFrame & kRingBufferMask;
        assert(atomic_load_explicit(
            &gDriver.ringBuffer[slot].sampleFrame, memory_order_seq_cst)
            == absoluteFrame);
        Float32 actual[kDevice_ChannelCount];
        UnpackStereoFrame(atomic_load_explicit(
            &gDriver.ringBuffer[slot].stereoBits, memory_order_seq_cst), actual);
        assert(actual[0] == expected[frame * kDevice_ChannelCount]);
        assert(actual[1] == expected[frame * kDevice_ChannelCount + 1]);
    }
}

static void ExpectOrderIndependentAtFrameCount(
    UInt32 frames, UInt32 separation, bool writeFirst
) {
    size_t sampleCount = (size_t)frames * kDevice_ChannelCount;
    Float32 *expectedInput = calloc(sampleCount, sizeof(Float32));
    Float32 *writeBuffer = calloc(sampleCount, sizeof(Float32));
    Float32 *received = calloc(sampleCount, sizeof(Float32));
    assert(expectedInput != NULL && writeBuffer != NULL && received != NULL);
    FillSignal(expectedInput, frames, 0.125f);
    FillSignal(writeBuffer, frames, 0.625f);

    gDriver.ringBuffer = CreateRingBuffer();
    assert(gDriver.ringBuffer != NULL);
    atomic_store_explicit(
        &gDriver.inputGainBits, Float32Bits(1.0f), memory_order_release);
    atomic_store_explicit(
        &gDriver.outputGainBits, Float32Bits(1.0f), memory_order_release);

    UInt64 inputStart = kRingBufferFrames - (frames / 2);
    UInt64 outputStart = inputStart + separation;
    PutSignalInRing(expectedInput, frames, inputStart);
    AudioServerPlugInIOCycleInfo cycle = CycleAt(
        (Float64)inputStart, (Float64)outputStart);

    if (writeFirst) {
        assert(Yun_DoIOOperation(
            TestDriver(), kObjectID_Device, kObjectID_Stream_Output, 1,
            kAudioServerPlugInIOOperationWriteMix, frames,
            &cycle, writeBuffer, NULL) == 0);
    }
    assert(Yun_DoIOOperation(
        TestDriver(), kObjectID_Device, kObjectID_Stream_Input, 2,
        kAudioServerPlugInIOOperationReadInput, frames,
        &cycle, received, NULL) == 0);
    if (!writeFirst) {
        assert(Yun_DoIOOperation(
            TestDriver(), kObjectID_Device, kObjectID_Stream_Output, 1,
            kAudioServerPlugInIOOperationWriteMix, frames,
            &cycle, writeBuffer, NULL) == 0);
    }

    ExpectSignalEqual(received, expectedInput, frames);
    ExpectRingSignal(writeBuffer, frames, outputStart);
    free(gDriver.ringBuffer);
    gDriver.ringBuffer = NULL;
    free(received);
    free(writeBuffer);
    free(expectedInput);
}

static void TestCallbacksOnBothSidesOf512IgnoreOperationOrder(void) {
    const UInt32 frameCounts[] = { 64, 257, kDevice_SafetyOffsetFrames };
    for (UInt32 index = 0; index < sizeof(frameCounts) / sizeof(frameCounts[0]); ++index) {
        ExpectOrderIndependentAtFrameCount(
            frameCounts[index], kDevice_SafetyOffsetFrames, false);
        ExpectOrderIndependentAtFrameCount(
            frameCounts[index], kDevice_SafetyOffsetFrames, true);
    }

    // Drift compensation can make an actual operation larger than the
    // nominal 512-frame period. A wider safety gap remains order-independent.
    ExpectOrderIndependentAtFrameCount(513, 513, false);
    ExpectOrderIndependentAtFrameCount(513, 513, true);
    ExpectOrderIndependentAtFrameCount(769, 769, false);
    ExpectOrderIndependentAtFrameCount(769, 769, true);
}

static void ExpectPublishedOverlapAtFrameCount(UInt32 frames) {
    UInt32 separation = kDevice_SafetyOffsetFrames;
    assert(frames > separation);
    size_t sampleCount = (size_t)frames * kDevice_ChannelCount;
    Float32 *prior = calloc(sampleCount, sizeof(Float32));
    Float32 *written = calloc(sampleCount, sizeof(Float32));
    Float32 *received = calloc(sampleCount, sizeof(Float32));
    assert(prior != NULL && written != NULL && received != NULL);
    FillSignal(prior, frames, 0.125f);
    FillSignal(written, frames, 0.625f);

    gDriver.ringBuffer = CreateRingBuffer();
    assert(gDriver.ringBuffer != NULL);
    atomic_store_explicit(
        &gDriver.inputGainBits, Float32Bits(1.0f), memory_order_release);
    atomic_store_explicit(
        &gDriver.outputGainBits, Float32Bits(1.0f), memory_order_release);
    atomic_store_explicit(
        &gDriver.unsafeReadOperations, 0, memory_order_relaxed);
    atomic_store_explicit(
        &gDriver.unsafeWriteOperations, 0, memory_order_relaxed);

    // Only the prefix precedes this output operation. The tail of the input
    // span is the same absolute timeline as the start of this write, so once
    // the host has delivered WriteMix first it must read those new samples.
    PutSignalInRing(prior, separation, 0);
    AudioServerPlugInIOCycleInfo cycle = CycleAt(0, separation);
    assert(Yun_DoIOOperation(
        TestDriver(), kObjectID_Device, kObjectID_Stream_Output, 1,
        kAudioServerPlugInIOOperationWriteMix, frames,
        &cycle, written, NULL) == 0);
    assert(Yun_DoIOOperation(
        TestDriver(), kObjectID_Device, kObjectID_Stream_Input, 2,
        kAudioServerPlugInIOOperationReadInput, frames,
        &cycle, received, NULL) == 0);

    for (UInt32 frame = 0; frame < separation; ++frame) {
        for (UInt32 channel = 0; channel < kDevice_ChannelCount; ++channel) {
            assert(received[frame * kDevice_ChannelCount + channel]
                   == prior[frame * kDevice_ChannelCount + channel]);
        }
    }
    for (UInt32 frame = separation; frame < frames; ++frame) {
        UInt32 writtenFrame = frame - separation;
        for (UInt32 channel = 0; channel < kDevice_ChannelCount; ++channel) {
            assert(received[frame * kDevice_ChannelCount + channel]
                   == written[writtenFrame * kDevice_ChannelCount + channel]);
        }
    }
    assert(atomic_load_explicit(
        &gDriver.unsafeReadOperations, memory_order_relaxed) == 0);
    assert(atomic_load_explicit(
        &gDriver.unsafeWriteOperations, memory_order_relaxed) == 0);

    free(gDriver.ringBuffer);
    gDriver.ringBuffer = NULL;
    free(received);
    free(written);
    free(prior);
}

static void TestPublishedVariableCallbacksNeedNoDisjointSpanRule(void) {
    ExpectPublishedOverlapAtFrameCount(513);
    ExpectPublishedOverlapAtFrameCount(769);
    printf(
        "driver variable IO: 513 and 769 frames across a %u-frame safety "
        "window, exact and 0 unsafe\n",
        kDevice_SafetyOffsetFrames);
}

static void ExpectUnsafeCallbackFailsSilent(UInt32 frames, bool writeFirst) {
    UInt64 inputStart = kRingBufferFrames - 256;
    UInt64 outputStart = inputStart + kDevice_SafetyOffsetFrames;
    gDriver.ringBuffer = CreateRingBuffer();
    assert(gDriver.ringBuffer != NULL);
    Float32 oldSamples[kDevice_ChannelCount] = { 0.375f, 0.375f };
    for (UInt32 frame = 0; frame < kRingBufferFrames; ++frame) {
        UInt64 absoluteFrame = outputStart + frame;
        UInt64 slot = absoluteFrame & kRingBufferMask;
        atomic_store_explicit(
            &gDriver.ringBuffer[slot].stereoBits,
            PackStereoFrame(oldSamples), memory_order_seq_cst);
        atomic_store_explicit(
            &gDriver.ringBuffer[slot].sampleFrame, absoluteFrame,
            memory_order_seq_cst);
    }

    size_t bufferSamples = (size_t)frames * kDevice_ChannelCount;
    Float32 *writeBuffer = malloc(bufferSamples * sizeof(Float32));
    Float32 *readBuffer = malloc(bufferSamples * sizeof(Float32));
    assert(writeBuffer != NULL && readBuffer != NULL);
    FillSignal(writeBuffer, frames, 0.75f);
    for (size_t index = 0; index < bufferSamples; ++index) {
        readBuffer[index] = -0.25f;
    }
    atomic_store_explicit(&gDriver.unsafeReadOperations, 0, memory_order_relaxed);
    atomic_store_explicit(&gDriver.unsafeWriteOperations, 0, memory_order_relaxed);
    AudioServerPlugInIOCycleInfo cycle = CycleAt(
        (Float64)inputStart, (Float64)outputStart);

    if (writeFirst) {
        assert(Yun_DoIOOperation(
            TestDriver(), kObjectID_Device, kObjectID_Stream_Output, 1,
            kAudioServerPlugInIOOperationWriteMix, frames,
            &cycle, writeBuffer, NULL) == 0);
    }
    assert(Yun_DoIOOperation(
        TestDriver(), kObjectID_Device, kObjectID_Stream_Input, 2,
        kAudioServerPlugInIOOperationReadInput, frames,
        &cycle, readBuffer, NULL) == 0);
    if (!writeFirst) {
        assert(Yun_DoIOOperation(
            TestDriver(), kObjectID_Device, kObjectID_Stream_Output, 1,
            kAudioServerPlugInIOOperationWriteMix, frames,
            &cycle, writeBuffer, NULL) == 0);
    }

    for (size_t index = 0; index < bufferSamples; ++index) {
        assert(readBuffer[index] == 0.0f);
    }
    UInt32 checkedFrames = frames < kRingBufferFrames ? frames : kRingBufferFrames;
    for (UInt32 frame = 0; frame < checkedFrames; ++frame) {
        UInt64 absoluteFrame = outputStart + frame;
        UInt64 slot = absoluteFrame & kRingBufferMask;
        assert(atomic_load_explicit(
            &gDriver.ringBuffer[slot].sampleFrame, memory_order_seq_cst)
            == absoluteFrame);
    }
    if (frames < kRingBufferFrames) {
        UInt64 untouchedFrame = outputStart + checkedFrames;
        UInt64 untouchedSlot = untouchedFrame & kRingBufferMask;
        assert(atomic_load_explicit(
            &gDriver.ringBuffer[untouchedSlot].sampleFrame,
            memory_order_seq_cst) == untouchedFrame);
    }
    assert(atomic_load_explicit(
        &gDriver.unsafeReadOperations, memory_order_relaxed) == 1);
    assert(atomic_load_explicit(
        &gDriver.unsafeWriteOperations, memory_order_relaxed) == 1);

    free(gDriver.ringBuffer);
    gDriver.ringBuffer = NULL;
    free(readBuffer);
    free(writeBuffer);
}

static void TestUnsafeCallbacksFailSilentWithoutAnErrorStorm(void) {
    // One operation cannot visit a physical slot twice. The host is allowed
    // to exceed its nominal 512 frames, but never the one-second ring itself.
    ExpectUnsafeCallbackFailsSilent(kRingBufferFrames + 1, false);
    ExpectUnsafeCallbackFailsSilent(kRingBufferFrames + 1, true);

    enum { frames = 64 };
    Float32 readBuffer[frames * kDevice_ChannelCount];
    Float32 writeBuffer[frames * kDevice_ChannelCount];
    FillSignal(readBuffer, frames, 0.25f);
    FillSignal(writeBuffer, frames, 0.75f);
    gDriver.ringBuffer = CreateRingBuffer();
    assert(gDriver.ringBuffer != NULL);
    Float32 oldSamples[kDevice_ChannelCount] = { 0.375f, 0.375f };
    PutSignalInRing(oldSamples, 1, 0);
    AudioServerPlugInIOCycleInfo nonFinite = CycleAt(0, kDevice_SafetyOffsetFrames);
    nonFinite.mInputTime.mSampleTime = NAN;
    assert(Yun_DoIOOperation(
        TestDriver(), kObjectID_Device, kObjectID_Stream_Input, 2,
        kAudioServerPlugInIOOperationReadInput, frames,
        &nonFinite, readBuffer, NULL) == 0);
    for (UInt32 index = 0; index < frames * kDevice_ChannelCount; ++index) {
        assert(readBuffer[index] == 0.0f);
    }
    nonFinite = CycleAt(0, kDevice_SafetyOffsetFrames);
    nonFinite.mOutputTime.mSampleTime = INFINITY;
    assert(Yun_DoIOOperation(
        TestDriver(), kObjectID_Device, kObjectID_Stream_Output, 1,
        kAudioServerPlugInIOOperationWriteMix, frames,
        &nonFinite, writeBuffer, NULL) == 0);
    ExpectRingSignal(oldSamples, 1, 0);
    free(gDriver.ringBuffer);
    gDriver.ringBuffer = NULL;
}

static void TestFixedBufferContractMatchesTheSafetyWindow(void) {
    AudioServerPlugInDriverRef driver = (AudioServerPlugInDriverRef)&gInterfacePtr;
    AudioObjectPropertyAddress bufferSize = {
        kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 value = 0;
    UInt32 size = sizeof(value);
    assert(Yun_GetPropertyData(
        driver, kObjectID_Device, 1, &bufferSize,
        0, NULL, size, &size, &value) == 0);
    assert(value == kDevice_BufferFrameSize);
    Boolean settable = true;
    assert(Yun_IsPropertySettable(
        driver, kObjectID_Device, 1, &bufferSize, &settable) == 0);
    assert(!settable);

    AudioObjectPropertyAddress rangeAddress = {
        kAudioDevicePropertyBufferFrameSizeRange,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioValueRange range = { 0 };
    size = sizeof(range);
    assert(Yun_GetPropertyData(
        driver, kObjectID_Device, 1, &rangeAddress,
        0, NULL, size, &size, &range) == 0);
    assert(range.mMinimum == kDevice_BufferFrameSize);
    assert(range.mMaximum == kDevice_BufferFrameSize);

    AudioObjectPropertyAddress variableAddress = {
        kAudioDevicePropertyUsesVariableBufferFrameSizes,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    value = 99;
    size = sizeof(value);
    assert(Yun_GetPropertyData(
        driver, kObjectID_Device, 1, &variableAddress,
        0, NULL, size, &size, &value) == 0);
    assert(value == 0);

    AudioObjectPropertyScope scopes[] = {
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyScopeOutput,
    };
    for (UInt32 index = 0; index < 2; ++index) {
        AudioObjectPropertyAddress safety = {
            kAudioDevicePropertySafetyOffset,
            scopes[index],
            kAudioObjectPropertyElementMain,
        };
        value = 0;
        size = sizeof(value);
        assert(Yun_GetPropertyData(
            driver, kObjectID_Device, 1, &safety, 0, NULL, size, &size, &value) == 0);
        assert(value == kDevice_BufferFrameSize);
        assert((double)value / kDevice_DefaultSampleRate * 1000.0 < 10.67);
    }
}

static void TestUnsafeOperationCountsAreObservable(void) {
    AudioObjectPropertyAddress address = {
        kYunCustomProperty_IOHealth,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    CFPropertyListRef value = NULL;
    UInt32 size = sizeof(value);
    assert(Yun_GetPropertyData(
        TestDriver(), kObjectID_Device, 1, &address,
        0, NULL, size, &size, &value) == 0);
    assert(value != NULL && CFGetTypeID(value) == CFDictionaryGetTypeID());
    CFDictionaryRef dictionary = (CFDictionaryRef)value;
    CFNumberRef reads = (CFNumberRef)CFDictionaryGetValue(
        dictionary, CFSTR(kYunIOHealthKey_UnsafeReadOperations));
    CFNumberRef writes = (CFNumberRef)CFDictionaryGetValue(
        dictionary, CFSTR(kYunIOHealthKey_UnsafeWriteOperations));
    SInt64 readCount = 0;
    SInt64 writeCount = 0;
    assert(reads != NULL && writes != NULL);
    assert(CFNumberGetValue(reads, kCFNumberSInt64Type, &readCount));
    assert(CFNumberGetValue(writes, kCFNumberSInt64Type, &writeCount));
    assert(readCount >= 1);
    assert(writeCount >= 1);
    CFRelease(value);

    AudioObjectPropertyAddress infoAddress = {
        kAudioObjectPropertyCustomPropertyInfoList,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioServerPlugInCustomPropertyInfo info[2] = { 0 };
    size = sizeof(info);
    assert(Yun_GetPropertyData(
        TestDriver(), kObjectID_Device, 1, &infoAddress,
        0, NULL, size, &size, info) == 0);
    assert(size == sizeof(info));
    assert(info[0].mSelector == kYunCustomProperty_ClockAnchor);
    assert(info[1].mSelector == kYunCustomProperty_IOHealth);
}

static UInt32 sNumberCreationCalls;
static UInt32 sNumberCreationFailureCall;

static CFNumberRef TestNumberCreate(
    CFAllocatorRef allocator, CFNumberType type, const void *value
) {
    ++sNumberCreationCalls;
    if (sNumberCreationCalls == sNumberCreationFailureCall) return NULL;
    return CFNumberCreate(allocator, type, value);
}

static void TestPropertyDictionaryHandlesEveryNumberAllocationFailure(void) {
    Float64 first = 1.0;
    Float64 second = 2.0;
    for (UInt32 failure = 1; failure <= 2; ++failure) {
        sNumberCreationCalls = 0;
        sNumberCreationFailureCall = failure;
        CFMutableDictionaryRef dictionary = CreateTwoNumberDictionary(
            CFSTR("first"), kCFNumberDoubleType, &first,
            CFSTR("second"), kCFNumberDoubleType, &second,
            TestNumberCreate);
        assert(dictionary == NULL);
        assert(sNumberCreationCalls == failure);
    }

    sNumberCreationCalls = 0;
    sNumberCreationFailureCall = 0;
    CFMutableDictionaryRef dictionary = CreateTwoNumberDictionary(
        CFSTR("first"), kCFNumberDoubleType, &first,
        CFSTR("second"), kCFNumberDoubleType, &second,
        TestNumberCreate);
    assert(dictionary != NULL);
    assert(CFDictionaryGetCount(dictionary) == 2);
    CFRelease(dictionary);
}

static void TestSafetyWindowMakesClientOrderIrrelevant(void) {
    enum { frames = kDevice_SafetyOffsetFrames };
    Float32 first[frames * kDevice_ChannelCount];
    Float32 second[frames * kDevice_ChannelCount];
    Float32 third[frames * kDevice_ChannelCount];
    Float32 received[frames * kDevice_ChannelCount];
    FillSignal(first, frames, 0.125f);
    FillSignal(second, frames, 0.375f);
    FillSignal(third, frames, 0.625f);

    gDriver.ringBuffer = CreateRingBuffer();
    assert(gDriver.ringBuffer != NULL);
    atomic_store_explicit(
        &gDriver.inputGainBits, Float32Bits(1.0f), memory_order_release);
    atomic_store_explicit(
        &gDriver.outputGainBits, Float32Bits(1.0f), memory_order_release);
    AudioServerPlugInDriverRef driver = (AudioServerPlugInDriverRef)&gInterfacePtr;

    AudioServerPlugInIOCycleInfo priming = CycleAt(0, frames);
    assert(Yun_DoIOOperation(
        driver, kObjectID_Device, kObjectID_Stream_Output, 1,
        kAudioServerPlugInIOOperationWriteMix, frames, &priming, first, NULL) == 0);

    // The following cycle deliberately reads before it writes. The safety
    // window keeps the two operations on disjoint ring spans, so an external
    // client such as Discord cannot observe whether CoreAudio chose this order
    // or the reverse one.
    AudioServerPlugInIOCycleInfo next = CycleAt(frames, frames * 2);
    assert(Yun_DoIOOperation(
        driver, kObjectID_Device, kObjectID_Stream_Input, 2,
        kAudioServerPlugInIOOperationReadInput, frames, &next, received, NULL) == 0);
    assert(Yun_DoIOOperation(
        driver, kObjectID_Device, kObjectID_Stream_Output, 1,
        kAudioServerPlugInIOOperationWriteMix, frames, &next, second, NULL) == 0);
    ExpectSignalEqual(received, first, frames);

    // Reverse the callback order on the following cycle. Its write is still
    // one safety window ahead of its read and therefore cannot overwrite the
    // second signal before the external client has consumed it.
    AudioServerPlugInIOCycleInfo final = CycleAt(frames * 2, frames * 3);
    assert(Yun_DoIOOperation(
        driver, kObjectID_Device, kObjectID_Stream_Output, 1,
        kAudioServerPlugInIOOperationWriteMix, frames, &final, third, NULL) == 0);
    memset(received, 0, sizeof(received));
    assert(Yun_DoIOOperation(
        driver, kObjectID_Device, kObjectID_Stream_Input, 2,
        kAudioServerPlugInIOOperationReadInput, frames, &final, received, NULL) == 0);
    ExpectSignalEqual(received, second, frames);

    memset(received, 0, sizeof(received));
    AudioServerPlugInIOCycleInfo draining = CycleAt(frames * 3, frames * 4);
    assert(Yun_DoIOOperation(
        driver, kObjectID_Device, kObjectID_Stream_Input, 2,
        kAudioServerPlugInIOOperationReadInput, frames, &draining, received, NULL) == 0);
    ExpectSignalEqual(received, third, frames);

    free(gDriver.ringBuffer);
    gDriver.ringBuffer = NULL;
}

enum {
    kConcurrentClientCount = 8,
    kConcurrentCallbacksPerClient = 125000,
};

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    UInt32 required;
    UInt32 arrived;
    bool released;
    bool timedOut;
} IOStartGate;

typedef struct {
    UInt32 clientID;
    bool writes;
    UInt64 exactReads;
    UInt64 silentReads;
    UInt64 invalidReads;
    UInt64 threadID;
} ConcurrentIOClient;

static IOStartGate sIOStartGate = {
    .mutex = PTHREAD_MUTEX_INITIALIZER,
    .condition = PTHREAD_COND_INITIALIZER,
};
static _Atomic UInt32 sIOFirstEntries;
static _Atomic UInt32 sIOActiveCallbacks;
static _Atomic UInt32 sIOMaximumActiveCallbacks;

static void PrepareIOStartGate(UInt32 required) {
    sIOStartGate.required = required;
    sIOStartGate.arrived = 0;
    sIOStartGate.released = false;
    sIOStartGate.timedOut = false;
    atomic_store_explicit(&sIOFirstEntries, 0, memory_order_relaxed);
    atomic_store_explicit(&sIOActiveCallbacks, 0, memory_order_relaxed);
    atomic_store_explicit(&sIOMaximumActiveCallbacks, 0, memory_order_relaxed);
}

static void AwaitIOStartGate(void) {
    struct timespec deadline;
    assert(clock_gettime(CLOCK_REALTIME, &deadline) == 0);
    deadline.tv_sec += 2;

    pthread_mutex_lock(&sIOStartGate.mutex);
    ++sIOStartGate.arrived;
    if (sIOStartGate.arrived == sIOStartGate.required) {
        sIOStartGate.released = true;
        pthread_cond_broadcast(&sIOStartGate.condition);
    }
    while (!sIOStartGate.released) {
        int status = pthread_cond_timedwait(
            &sIOStartGate.condition, &sIOStartGate.mutex, &deadline);
        if (status == ETIMEDOUT) {
            sIOStartGate.timedOut = true;
            sIOStartGate.released = true;
            pthread_cond_broadcast(&sIOStartGate.condition);
            break;
        }
        assert(status == 0);
    }
    pthread_mutex_unlock(&sIOStartGate.mutex);
}

static void RecordIOCallbackMaximum(UInt32 active) {
    UInt32 observed = atomic_load_explicit(
        &sIOMaximumActiveCallbacks, memory_order_relaxed);
    while (observed < active
           && !atomic_compare_exchange_weak_explicit(
               &sIOMaximumActiveCallbacks, &observed, active,
               memory_order_relaxed, memory_order_relaxed)) {}
}

static void ConcurrentIOTestHook(
    bool entering, UInt32 clientID, UInt32 operationID
) {
    (void)clientID;
    (void)operationID;
    if (entering) {
        UInt32 active = atomic_fetch_add_explicit(
            &sIOActiveCallbacks, 1, memory_order_relaxed) + 1;
        RecordIOCallbackMaximum(active);
        UInt32 entry = atomic_fetch_add_explicit(
            &sIOFirstEntries, 1, memory_order_relaxed);
        if (entry < kConcurrentClientCount) AwaitIOStartGate();
    } else {
        UInt32 preceding = atomic_fetch_sub_explicit(
            &sIOActiveCallbacks, 1, memory_order_relaxed);
        assert(preceding > 0);
    }
}

static void *RunConcurrentIOClient(void *context) {
    ConcurrentIOClient *client = (ConcurrentIOClient *)context;
    assert(pthread_threadid_np(NULL, &client->threadID) == 0);

    for (UInt32 iteration = 0;
         iteration < kConcurrentCallbacksPerClient; ++iteration) {
        Float32 magnitude = (Float32)(iteration + 1);
        Float32 buffer[kDevice_ChannelCount] = { magnitude, -magnitude };
        if (client->writes) {
            AudioServerPlugInIOCycleInfo cycle = CycleAt(
                iteration + kDevice_SafetyOffsetFrames, iteration);
            assert(Yun_DoIOOperation(
                TestDriver(), kObjectID_Device, kObjectID_Stream_Output,
                client->clientID, kAudioServerPlugInIOOperationWriteMix,
                1, &cycle, buffer, NULL) == 0);
            continue;
        }

        buffer[0] = NAN;
        buffer[1] = NAN;
        AudioServerPlugInIOCycleInfo cycle = CycleAt(
            iteration, iteration + kDevice_SafetyOffsetFrames);
        assert(Yun_DoIOOperation(
            TestDriver(), kObjectID_Device, kObjectID_Stream_Input,
            client->clientID, kAudioServerPlugInIOOperationReadInput,
            1, &cycle, buffer, NULL) == 0);
        if (buffer[0] == magnitude && buffer[1] == -magnitude) {
            ++client->exactReads;
        } else if (buffer[0] == 0.0f && buffer[1] == 0.0f) {
            ++client->silentReads;
        } else {
            ++client->invalidReads;
        }
    }
    return NULL;
}

static void TestEightClientsCanOverlapWithoutTornAudio(void) {
    const UInt64 expectedCallbacks =
        (UInt64)kConcurrentClientCount * kConcurrentCallbacksPerClient;
    gDriver.ringBuffer = CreateRingBuffer();
    assert(gDriver.ringBuffer != NULL);
    atomic_store_explicit(
        &gDriver.inputGainBits, Float32Bits(1.0f), memory_order_release);
    atomic_store_explicit(
        &gDriver.outputGainBits, Float32Bits(1.0f), memory_order_release);

    PrepareIOStartGate(kConcurrentClientCount);
    gYunDriverIOTestHook = ConcurrentIOTestHook;

    ConcurrentIOClient clients[kConcurrentClientCount] = { 0 };
    pthread_t threads[kConcurrentClientCount];
    for (UInt32 index = 0; index < kConcurrentClientCount; ++index) {
        clients[index].clientID = index + 1;
        clients[index].writes = index == 0;
        assert(pthread_create(
            &threads[index], NULL, RunConcurrentIOClient, &clients[index]) == 0);
    }
    for (UInt32 index = 0; index < kConcurrentClientCount; ++index) {
        assert(pthread_join(threads[index], NULL) == 0);
    }
    gYunDriverIOTestHook = NULL;

    assert(!sIOStartGate.timedOut);
    assert(sIOStartGate.arrived == kConcurrentClientCount);
    assert(atomic_load_explicit(
        &sIOActiveCallbacks, memory_order_relaxed) == 0);
    assert(atomic_load_explicit(
        &sIOMaximumActiveCallbacks, memory_order_relaxed)
        == kConcurrentClientCount);
    for (UInt32 left = 0; left < kConcurrentClientCount; ++left) {
        assert(clients[left].threadID != 0);
        for (UInt32 right = left + 1; right < kConcurrentClientCount; ++right) {
            assert(clients[left].threadID != clients[right].threadID);
        }
    }

    UInt64 exactReads = 0;
    UInt64 silentReads = 0;
    UInt64 invalidReads = 0;
    for (UInt32 index = 1; index < kConcurrentClientCount; ++index) {
        exactReads += clients[index].exactReads;
        silentReads += clients[index].silentReads;
        invalidReads += clients[index].invalidReads;
    }
    assert(exactReads + silentReads + invalidReads
           == expectedCallbacks - kConcurrentCallbacksPerClient);
    assert(invalidReads == 0);
    printf(
        "driver concurrent IO: %llu callbacks, %u clients on %u distinct "
        "threads, max overlap %u, %llu exact reads, %llu silent reads, "
        "%llu invalid reads\n",
        expectedCallbacks, kConcurrentClientCount, kConcurrentClientCount,
        atomic_load_explicit(
            &sIOMaximumActiveCallbacks, memory_order_relaxed),
        exactReads, silentReads, invalidReads);

    free(gDriver.ringBuffer);
    gDriver.ringBuffer = NULL;
}

enum { kConcurrentOwnershipFrames = kDevice_BufferFrameSize };

typedef struct {
    UInt32 clientID;
    UInt64 threadID;
    Float32 samples[kConcurrentOwnershipFrames * kDevice_ChannelCount];
} ConcurrentRingWriter;

static void *RunConcurrentRingWriter(void *context) {
    ConcurrentRingWriter *writer = (ConcurrentRingWriter *)context;
    assert(pthread_threadid_np(NULL, &writer->threadID) == 0);
    AudioServerPlugInIOCycleInfo cycle = CycleAt(
        kConcurrentOwnershipFrames, 0);
    assert(Yun_DoIOOperation(
        TestDriver(), kObjectID_Device, kObjectID_Stream_Output,
        writer->clientID, kAudioServerPlugInIOOperationWriteMix,
        kConcurrentOwnershipFrames, &cycle, writer->samples, NULL) == 0);
    return NULL;
}

static bool SignalsAreEqual(const Float32 *left,
                            const Float32 *right,
                            UInt32 frames) {
    for (UInt32 index = 0; index < frames * kDevice_ChannelCount; ++index) {
        if (left[index] != right[index]) return false;
    }
    return true;
}

static void TestAWriterKeepsOwnershipUntilItsWholeBlockIsPublished(void) {
    enum { frames = kDevice_BufferFrameSize };
    gDriver.ringBuffer = CreateRingBuffer();
    assert(gDriver.ringBuffer != NULL);
    Float32 first[frames * kDevice_ChannelCount];
    Float32 wrapped[frames * kDevice_ChannelCount];
    Float32 received[frames * kDevice_ChannelCount];
    FillSignal(first, frames, 0.125f);
    FillSignal(wrapped, frames, 0.625f);

    assert(ClaimRingWriteSpan(gDriver.ringBuffer, 0, frames)
           == kRingWriteClaimed);
    // Simulate a publisher part-way through its block. A callback one ring
    // later addresses the same physical slots but must not steal the prefix
    // which already carries samples while the suffix is still being built.
    atomic_store_explicit(
        &gDriver.ringBuffer[0].stereoBits, PackStereoFrame(first),
        memory_order_seq_cst);
    atomic_store_explicit(
        &gDriver.ringBuffer[0].sampleFrame, 0, memory_order_seq_cst);
    assert(ClaimRingWriteSpan(
        gDriver.ringBuffer, kRingBufferFrames, frames)
        == kRingWriteUnsafe);
    for (UInt32 frame = 0; frame < frames; ++frame) {
        assert(atomic_load_explicit(
            &gDriver.ringBuffer[frame].owner, memory_order_seq_cst) == 1);
    }

    PublishRingWrite(gDriver.ringBuffer, 0, frames, first, 1.0f);
    assert(ReadRingSpan(
        gDriver.ringBuffer, 0, frames, received, 1.0f));
    ExpectSignalEqual(received, first, frames);
    assert(ClaimRingWriteSpan(gDriver.ringBuffer, 0, frames)
           == kRingWriteCoalesced);

    assert(ClaimRingWriteSpan(
        gDriver.ringBuffer, kRingBufferFrames, frames)
        == kRingWriteClaimed);
    PublishRingWrite(
        gDriver.ringBuffer, kRingBufferFrames, frames, wrapped, 1.0f);
    assert(ReadRingSpan(
        gDriver.ringBuffer, kRingBufferFrames, frames, received, 1.0f));
    ExpectSignalEqual(received, wrapped, frames);

    free(gDriver.ringBuffer);
    gDriver.ringBuffer = NULL;
}

static void TestPartialWriterOverlapNeverCoalesces(void) {
    enum {
        shortFrames = kDevice_BufferFrameSize,
        longFrames = kDevice_BufferFrameSize + 257,
    };
    gDriver.ringBuffer = CreateRingBuffer();
    assert(gDriver.ringBuffer != NULL);
    assert(ClaimRingWriteSpan(gDriver.ringBuffer, 0, shortFrames)
           == kRingWriteClaimed);
    assert(ClaimRingWriteSpan(gDriver.ringBuffer, 0, longFrames)
           == kRingWriteUnsafe);
    for (UInt32 frame = 0; frame < shortFrames; ++frame) {
        assert(atomic_load_explicit(
            &gDriver.ringBuffer[frame].owner, memory_order_seq_cst) == 1);
    }
    for (UInt32 frame = shortFrames; frame < longFrames; ++frame) {
        assert(atomic_load_explicit(
            &gDriver.ringBuffer[frame].owner, memory_order_seq_cst) == 0);
    }

    UInt64 offsetStart = shortFrames / 2;
    assert(ClaimRingWriteSpan(
        gDriver.ringBuffer, offsetStart, shortFrames)
        == kRingWriteUnsafe);
    for (UInt32 frame = 0; frame < shortFrames; ++frame) {
        assert(atomic_load_explicit(
            &gDriver.ringBuffer[frame].owner, memory_order_seq_cst) == 1);
    }
    for (UInt32 frame = shortFrames;
         frame < offsetStart + shortFrames; ++frame) {
        assert(atomic_load_explicit(
            &gDriver.ringBuffer[frame].owner, memory_order_seq_cst) == 0);
    }

    Float32 shortSignal[shortFrames * kDevice_ChannelCount];
    Float32 received[longFrames * kDevice_ChannelCount];
    FillSignal(shortSignal, shortFrames, 0.125f);
    PublishRingWrite(
        gDriver.ringBuffer, 0, shortFrames, shortSignal, 1.0f);
    assert(!ReadRingSpan(
        gDriver.ringBuffer, 0, longFrames, received, 1.0f));

    free(gDriver.ringBuffer);
    gDriver.ringBuffer = NULL;
    puts("driver partial overlap: 512/769 same-start and offset spans unsafe");
}

static void TestStaleWriterCannotOverwriteACompletedRingWrap(void) {
    enum { frames = 64 };
    gDriver.ringBuffer = CreateRingBuffer();
    assert(gDriver.ringBuffer != NULL);
    Float32 newer[frames * kDevice_ChannelCount];
    Float32 received[frames * kDevice_ChannelCount];
    FillSignal(newer, frames, 0.625f);
    PutSignalInRing(newer, frames, kRingBufferFrames);

    assert(ClaimRingWriteSpan(gDriver.ringBuffer, 0, frames)
           == kRingWriteUnsafe);
    assert(ReadRingSpan(
        gDriver.ringBuffer, kRingBufferFrames,
        frames, received, 1.0f));
    ExpectSignalEqual(received, newer, frames);

    free(gDriver.ringBuffer);
    gDriver.ringBuffer = NULL;
    printf(
        "driver stale wrap: %u newer frames preserved after stale rejection\n",
        frames);
}

static void TestCompletedFullMixCallbacksCoalesceWithoutDropout(void) {
    gDriver.ringBuffer = CreateRingBuffer();
    assert(gDriver.ringBuffer != NULL);
    atomic_store_explicit(
        &gDriver.outputGainBits, Float32Bits(1.0f), memory_order_release);
    atomic_store_explicit(
        &gDriver.inputGainBits, Float32Bits(1.0f), memory_order_release);
    atomic_store_explicit(
        &gDriver.unsafeReadOperations, 0, memory_order_relaxed);
    atomic_store_explicit(
        &gDriver.unsafeWriteOperations, 0, memory_order_relaxed);
    Float32 published[kConcurrentOwnershipFrames * kDevice_ChannelCount];
    FillSignal(published, kConcurrentOwnershipFrames, 0.375f);
    PutSignalInRing(published, kConcurrentOwnershipFrames, 0);
    PrepareIOStartGate(kConcurrentClientCount);
    gYunDriverIOTestHook = ConcurrentIOTestHook;

    ConcurrentRingWriter writers[kConcurrentClientCount] = { 0 };
    pthread_t threads[kConcurrentClientCount];
    for (UInt32 index = 0; index < kConcurrentClientCount; ++index) {
        writers[index].clientID = index + 1;
        FillSignal(
            writers[index].samples, kConcurrentOwnershipFrames,
            0.375f);
        assert(pthread_create(
            &threads[index], NULL, RunConcurrentRingWriter,
            &writers[index]) == 0);
    }
    for (UInt32 index = 0; index < kConcurrentClientCount; ++index) {
        assert(pthread_join(threads[index], NULL) == 0);
    }
    gYunDriverIOTestHook = NULL;

    assert(!sIOStartGate.timedOut);
    assert(sIOStartGate.arrived == kConcurrentClientCount);
    assert(atomic_load_explicit(
        &sIOMaximumActiveCallbacks, memory_order_relaxed)
        == kConcurrentClientCount);
    assert(atomic_load_explicit(
        &gDriver.unsafeWriteOperations, memory_order_relaxed) == 0);
    for (UInt32 left = 0; left < kConcurrentClientCount; ++left) {
        assert(writers[left].threadID != 0);
        for (UInt32 right = left + 1; right < kConcurrentClientCount; ++right) {
            assert(writers[left].threadID != writers[right].threadID);
        }
    }

    Float32 received[kConcurrentOwnershipFrames * kDevice_ChannelCount] = { 0 };
    AudioServerPlugInIOCycleInfo readCycle = CycleAt(
        0, kConcurrentOwnershipFrames);
    assert(Yun_DoIOOperation(
        TestDriver(), kObjectID_Device, kObjectID_Stream_Input, 99,
        kAudioServerPlugInIOOperationReadInput, kConcurrentOwnershipFrames,
        &readCycle, received, NULL) == 0);
    assert(SignalsAreEqual(
        received, writers[0].samples, kConcurrentOwnershipFrames));
    assert(atomic_load_explicit(
        &gDriver.unsafeReadOperations, memory_order_relaxed) == 0);
    printf(
        "driver completed full mix: %u overlapping callbacks, "
        "0 unsafe, %u exact frames\n",
        kConcurrentClientCount,
        kConcurrentOwnershipFrames);

    free(gDriver.ringBuffer);
    gDriver.ringBuffer = NULL;
}

typedef struct {
    UInt32 clientID;
    bool writes;
    UInt64 exactReads;
    UInt64 silentReads;
    UInt64 invalidReads;
    UInt64 threadID;
} PublishedSpanClient;

static void *RunPublishedSpanClient(void *context) {
    PublishedSpanClient *client = (PublishedSpanClient *)context;
    assert(pthread_threadid_np(NULL, &client->threadID) == 0);
    AudioServerPlugInIOCycleInfo cycle = CycleAt(
        0, kDevice_SafetyOffsetFrames);

    for (UInt32 iteration = 0;
         iteration < kConcurrentCallbacksPerClient; ++iteration) {
        Float32 buffer[kDevice_ChannelCount] = { 0.375f, -0.375f };
        UInt32 operation = client->writes
            ? kAudioServerPlugInIOOperationWriteMix
            : kAudioServerPlugInIOOperationReadInput;
        AudioObjectID stream = client->writes
            ? kObjectID_Stream_Output
            : kObjectID_Stream_Input;
        assert(Yun_DoIOOperation(
            TestDriver(), kObjectID_Device, stream, client->clientID,
            operation, 1, &cycle, buffer, NULL) == 0);
        if (client->writes) continue;

        if (buffer[0] == 0.375f && buffer[1] == -0.375f) {
            ++client->exactReads;
        } else if (buffer[0] == 0.0f && buffer[1] == 0.0f) {
            ++client->silentReads;
        } else {
            ++client->invalidReads;
        }
    }
    return NULL;
}

static void TestPublishedFullMixStaysReadableAcrossDuplicateCallbacks(void) {
    gDriver.ringBuffer = CreateRingBuffer();
    assert(gDriver.ringBuffer != NULL);
    atomic_store_explicit(
        &gDriver.outputGainBits, Float32Bits(1.0f), memory_order_release);
    atomic_store_explicit(
        &gDriver.inputGainBits, Float32Bits(1.0f), memory_order_release);
    atomic_store_explicit(
        &gDriver.unsafeReadOperations, 0, memory_order_relaxed);
    atomic_store_explicit(
        &gDriver.unsafeWriteOperations, 0, memory_order_relaxed);
    Float32 signal[kDevice_ChannelCount] = { 0.375f, -0.375f };
    PutSignalInRing(signal, 1, 0);
    assert(RingWriteSpanIsPublished(gDriver.ringBuffer, 0, 1));
    assert(ClaimRingWriteSpan(gDriver.ringBuffer, 0, 1)
           == kRingWriteCoalesced);
    assert(atomic_load_explicit(
        &gDriver.ringBuffer[0].owner, memory_order_seq_cst) == 0);

    PrepareIOStartGate(kConcurrentClientCount);
    gYunDriverIOTestHook = ConcurrentIOTestHook;
    PublishedSpanClient clients[kConcurrentClientCount] = { 0 };
    pthread_t threads[kConcurrentClientCount];
    for (UInt32 index = 0; index < kConcurrentClientCount; ++index) {
        clients[index].clientID = index + 1;
        clients[index].writes = index < kConcurrentClientCount / 2;
        assert(pthread_create(
            &threads[index], NULL, RunPublishedSpanClient,
            &clients[index]) == 0);
    }
    for (UInt32 index = 0; index < kConcurrentClientCount; ++index) {
        assert(pthread_join(threads[index], NULL) == 0);
    }
    gYunDriverIOTestHook = NULL;

    assert(!sIOStartGate.timedOut);
    assert(sIOStartGate.arrived == kConcurrentClientCount);
    assert(atomic_load_explicit(
        &sIOMaximumActiveCallbacks, memory_order_relaxed)
        == kConcurrentClientCount);
    UInt64 exactReads = 0;
    UInt64 silentReads = 0;
    UInt64 invalidReads = 0;
    for (UInt32 index = kConcurrentClientCount / 2;
         index < kConcurrentClientCount; ++index) {
        exactReads += clients[index].exactReads;
        silentReads += clients[index].silentReads;
        invalidReads += clients[index].invalidReads;
    }
    assert(exactReads
           == (UInt64)(kConcurrentClientCount / 2)
               * kConcurrentCallbacksPerClient);
    assert(silentReads == 0);
    assert(invalidReads == 0);
    assert(atomic_load_explicit(
        &gDriver.unsafeReadOperations, memory_order_relaxed) == 0);
    assert(atomic_load_explicit(
        &gDriver.unsafeWriteOperations, memory_order_relaxed) == 0);
    printf(
        "driver duplicate full mix: %llu exact concurrent reads, "
        "0 silent, 0 invalid, 0 unsafe\n",
        exactReads);

    free(gDriver.ringBuffer);
    gDriver.ringBuffer = NULL;
}

#if defined(YUNAUDIO_DRIVER_PERFORMANCE_TESTS)
enum {
    kCallbackTailWarmupCycles = 1000,
    kCallbackTailMeasuredCycles = 50000,
    kCallbackTailCount = 2 * kCallbackTailMeasuredCycles,
};

static UInt64 MonotonicTimeNanoseconds(void) {
    struct timespec time;
    assert(clock_gettime(CLOCK_MONOTONIC_RAW, &time) == 0);
    return (UInt64)time.tv_sec * 1000000000ULL + (UInt64)time.tv_nsec;
}

static int CompareUInt64(const void *left, const void *right) {
    UInt64 lhs = *(const UInt64 *)left;
    UInt64 rhs = *(const UInt64 *)right;
    return (lhs > rhs) - (lhs < rhs);
}

static UInt64 Percentile(
    const UInt64 *sorted, size_t count, UInt64 numerator, UInt64 denominator
) {
    size_t index = (size_t)(((UInt64)count * numerator + denominator - 1)
                            / denominator - 1);
    assert(index < count);
    return sorted[index];
}

static void TestVariableAndDuplicateCallbackCPUTail(void) {
    enum {
        frames = kDevice_BufferFrameSize + 257,
        warmupCycles = 1000,
        measuredCycles = 50000,
    };
    const size_t durationCount = 2 * measuredCycles;
    gDriver.ringBuffer = CreateRingBuffer();
    assert(gDriver.ringBuffer != NULL);
    atomic_store_explicit(
        &gDriver.outputGainBits, Float32Bits(1.0f), memory_order_release);
    Float32 written[frames * kDevice_ChannelCount];
    FillSignal(written, frames, 0.375f);
    UInt64 *durations = malloc(durationCount * sizeof(*durations));
    assert(durations != NULL);
    size_t durationIndex = 0;

    UInt32 totalCycles = warmupCycles + measuredCycles;
    for (UInt32 cycleIndex = 0; cycleIndex < totalCycles; ++cycleIndex) {
        UInt64 outputStart = (UInt64)cycleIndex * frames;
        AudioServerPlugInIOCycleInfo cycle = CycleAt(
            (Float64)(outputStart + kDevice_SafetyOffsetFrames),
            (Float64)outputStart);
        UInt64 before = MonotonicTimeNanoseconds();
        assert(Yun_DoIOOperation(
            TestDriver(), kObjectID_Device, kObjectID_Stream_Output, 1,
            kAudioServerPlugInIOOperationWriteMix, frames,
            &cycle, written, NULL) == 0);
        UInt64 variableDuration = MonotonicTimeNanoseconds() - before;

        before = MonotonicTimeNanoseconds();
        assert(Yun_DoIOOperation(
            TestDriver(), kObjectID_Device, kObjectID_Stream_Output, 2,
            kAudioServerPlugInIOOperationWriteMix, frames,
            &cycle, written, NULL) == 0);
        UInt64 duplicateDuration = MonotonicTimeNanoseconds() - before;
        if (cycleIndex >= warmupCycles) {
            durations[durationIndex++] = variableDuration;
            durations[durationIndex++] = duplicateDuration;
        }
    }
    assert(durationIndex == durationCount);
    qsort(durations, durationIndex, sizeof(*durations), CompareUInt64);

    UInt64 p999 = Percentile(durations, durationIndex, 999, 1000);
    UInt64 p99999 = Percentile(durations, durationIndex, 99999, 100000);
    UInt64 deadline = (UInt64)(
        (Float64)frames / kDevice_DefaultSampleRate * 1000000000.0);
    assert(p999 * 4 <= deadline);
    assert(p99999 * 2 <= deadline);
    printf(
        "driver variable callback tail: %zu callbacks x %u frames, "
        "p99.9 %.3f ms <= %.3f ms, p99.999 %.3f ms <= %.3f ms\n",
        durationCount, frames,
        (double)p999 / 1000000.0, (double)deadline / 4000000.0,
        (double)p99999 / 1000000.0, (double)deadline / 2000000.0);

    free(durations);
    free(gDriver.ringBuffer);
    gDriver.ringBuffer = NULL;
}

static void TestAtomicRingCallbackCPUTail(void) {
    enum { frames = kDevice_BufferFrameSize };
    gDriver.ringBuffer = CreateRingBuffer();
    assert(gDriver.ringBuffer != NULL);
    atomic_store_explicit(
        &gDriver.outputGainBits, Float32Bits(1.0f), memory_order_release);
    atomic_store_explicit(
        &gDriver.inputGainBits, Float32Bits(1.0f), memory_order_release);

    Float32 written[frames * kDevice_ChannelCount];
    Float32 received[frames * kDevice_ChannelCount];
    FillSignal(written, frames, 0.375f);
    UInt64 *durations = malloc(kCallbackTailCount * sizeof(*durations));
    assert(durations != NULL);
    size_t durationIndex = 0;

    UInt32 totalCycles = kCallbackTailWarmupCycles + kCallbackTailMeasuredCycles;
    for (UInt32 cycleIndex = 0; cycleIndex < totalCycles; ++cycleIndex) {
        UInt64 outputStart = (UInt64)cycleIndex * frames;
        AudioServerPlugInIOCycleInfo writeCycle = CycleAt(
            (Float64)(outputStart + frames), (Float64)outputStart);
        UInt64 before = MonotonicTimeNanoseconds();
        OSStatus writeStatus = Yun_DoIOOperation(
            TestDriver(), kObjectID_Device, kObjectID_Stream_Output, 1,
            kAudioServerPlugInIOOperationWriteMix, frames,
            &writeCycle, written, NULL);
        UInt64 writeDuration = MonotonicTimeNanoseconds() - before;
        assert(writeStatus == 0);

        AudioServerPlugInIOCycleInfo readCycle = CycleAt(
            (Float64)outputStart, (Float64)(outputStart + frames));
        before = MonotonicTimeNanoseconds();
        OSStatus readStatus = Yun_DoIOOperation(
            TestDriver(), kObjectID_Device, kObjectID_Stream_Input, 2,
            kAudioServerPlugInIOOperationReadInput, frames,
            &readCycle, received, NULL);
        UInt64 readDuration = MonotonicTimeNanoseconds() - before;
        assert(readStatus == 0);
        ExpectSignalEqual(received, written, frames);

        if (cycleIndex >= kCallbackTailWarmupCycles) {
            durations[durationIndex++] = writeDuration;
            durations[durationIndex++] = readDuration;
        }
    }
    assert(durationIndex == kCallbackTailCount);
    qsort(durations, durationIndex, sizeof(*durations), CompareUInt64);

    UInt64 p999 = Percentile(durations, durationIndex, 999, 1000);
    UInt64 p99999 = Percentile(durations, durationIndex, 99999, 100000);
    UInt64 deadline = (UInt64)(
        (Float64)frames / kDevice_DefaultSampleRate * 1000000000.0);
    assert(p999 * 4 <= deadline);
    assert(p99999 * 2 <= deadline);
    printf(
        "driver callback wall tail: %u callbacks x %u frames, "
        "p99.9 %.3f ms <= %.3f ms, p99.999 %.3f ms <= %.3f ms\n",
        kCallbackTailCount, frames,
        (double)p999 / 1000000.0, (double)deadline / 4000000.0,
        (double)p99999 / 1000000.0, (double)deadline / 2000000.0);

    free(durations);
    free(gDriver.ringBuffer);
    gDriver.ringBuffer = NULL;
}
#endif

int main(void) {
    TestQueryInterfaceClearsFailedOutput();
    TestObjectListSizesMatchTheirGetters();
    TestOwnedObjectsHonourEveryClassQualifier();
    TestPropertyAccessIsClosedOverItsObjectMatrix();
    TestTimestampCatchesUpEveryMissedPeriod();
    TestNominalRebaseKeepsTheTimelineContinuous();
    TestRealtimeAtomicsAreActuallyLockFree();
    TestControlChangesPublishOneCoherentEffectiveGain();
    TestPropertyNotificationsAreCompleteAndNullSafe();
    TestNonFiniteControlsNeverReachStoredOrPublishedState();
    TestClockAnchorRejectsNonFiniteAndOutOfRangeNumbers();
    TestStreamFormatMustMatchTheCallbackLayoutExactly();
    TestConfigurationRequestsAreStatusCheckedAndGenerationBound();
    TestConfigurationRequestNeverHoldsDriverLocksAcrossHostReentry();
    TestTranslateUIDRejectsMalformedQualifiers();
    TestPublishedClockRoundTripsEveryField();
    TestFixedBufferContractMatchesTheSafetyWindow();
    TestCallbacksOnBothSidesOf512IgnoreOperationOrder();
    TestPublishedVariableCallbacksNeedNoDisjointSpanRule();
    TestUnsafeCallbacksFailSilentWithoutAnErrorStorm();
    TestUnsafeOperationCountsAreObservable();
    TestPropertyDictionaryHandlesEveryNumberAllocationFailure();
    TestSafetyWindowMakesClientOrderIrrelevant();
    TestEightClientsCanOverlapWithoutTornAudio();
    TestAWriterKeepsOwnershipUntilItsWholeBlockIsPublished();
    TestPartialWriterOverlapNeverCoalesces();
    TestStaleWriterCannotOverwriteACompletedRingWrap();
    TestCompletedFullMixCallbacksCoalesceWithoutDropout();
    TestPublishedFullMixStaysReadableAcrossDuplicateCallbacks();
#if defined(YUNAUDIO_DRIVER_PERFORMANCE_TESTS)
    TestVariableAndDuplicateCallbackCPUTail();
    TestAtomicRingCallbackCPUTail();
    puts("driver core: 31 tests passed");
#else
    puts("driver core: 29 tests passed");
#endif
    return 0;
}
