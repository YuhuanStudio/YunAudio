#include <assert.h>
#include <math.h>
#include <stdio.h>

// The driver is included into this pure process so its internal clock
// arithmetic is tested without loading it into coreaudiod or opening hardware.
#include "../Sources/YunAudioDriver.c"

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
    assert(atomic_is_lock_free(&gDriver.inputGainBits));
    assert(atomic_is_lock_free(&gDriver.outputGainBits));
    assert(atomic_is_lock_free(&gDriver.publishedClock.version));
    assert(atomic_is_lock_free(&gDriver.publishedClock.hostTicksPerFrameBits));
}

static void TestControlChangesPublishOneCoherentEffectiveGain(void) {
    AudioServerPlugInDriverRef driver = (AudioServerPlugInDriverRef)&gInterfacePtr;
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

static void TestSafetyOffsetPublishesOneWholeDevicePeriod(void) {
    AudioServerPlugInDriverRef driver = (AudioServerPlugInDriverRef)&gInterfacePtr;
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
        UInt32 value = 0;
        UInt32 size = sizeof(value);
        assert(Yun_GetPropertyData(
            driver, kObjectID_Device, 1, &safety, 0, NULL, size, &size, &value) == 0);
        assert(value == 512);
        assert((double)value / kDevice_DefaultSampleRate * 1000.0 < 10.67);
    }
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

    gDriver.ringBuffer = calloc(
        (size_t)kRingBufferFrames * kDevice_ChannelCount, sizeof(Float32));
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

int main(void) {
    TestTimestampCatchesUpEveryMissedPeriod();
    TestNominalRebaseKeepsTheTimelineContinuous();
    TestRealtimeAtomicsAreActuallyLockFree();
    TestControlChangesPublishOneCoherentEffectiveGain();
    TestPublishedClockRoundTripsEveryField();
    TestSafetyOffsetPublishesOneWholeDevicePeriod();
    TestSafetyWindowMakesClientOrderIrrelevant();
    puts("driver core: 7 tests passed");
    return 0;
}
