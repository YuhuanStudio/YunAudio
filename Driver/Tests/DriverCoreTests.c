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

int main(void) {
    TestTimestampCatchesUpEveryMissedPeriod();
    TestNominalRebaseKeepsTheTimelineContinuous();
    TestRealtimeAtomicsAreActuallyLockFree();
    TestControlChangesPublishOneCoherentEffectiveGain();
    TestPublishedClockRoundTripsEveryField();
    puts("driver core: 5 tests passed");
    return 0;
}
