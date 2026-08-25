import CoreAudio
import Foundation
import Testing

@testable import YunAudioApp
@testable import YunAudioHAL

@Suite("Route member sample rate")
struct DeviceSampleRateWatcherTests {

    private final class Fake: @unchecked Sendable {
        private let lock = NSLock()
        private var blocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
        private var rates: [AudioObjectID: Double] = [:]
        private(set) var drifts: [(device: AudioObjectID, rate: Double)] = []
        var refusedDevices: Set<AudioObjectID> = []

        func setRate(_ rate: Double, for device: AudioObjectID) {
            lock.withLock { rates[device] = rate }
        }

        /// What Core Audio does when somebody else changes the format.
        func announce(_ rate: Double, for device: AudioObjectID) {
            setRate(rate, for: device)
            let block = lock.withLock { blocks[device] }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            block?(1, &address)
        }

        var installedCount: Int { lock.withLock { blocks.count } }

        /// The block Core Audio would still hold after a removal races a
        /// callback already on its way.
        func blocksForTesting(_ device: AudioObjectID) -> AudioObjectPropertyListenerBlock? {
            lock.withLock { blocks[device] }
        }

        func makeWatcher() -> DeviceSampleRateWatcher {
            DeviceSampleRateWatcher(
                queue: DispatchQueue(label: "test.member-rate"),
                install: { [self] device, block in
                    guard !refusedDevices.contains(device) else { return false }
                    lock.withLock { blocks[device] = block }
                    return true
                },
                remove: { [self] device, _ in
                    _ = lock.withLock { blocks.removeValue(forKey: device) }
                },
                readRate: { [self] device in lock.withLock { rates[device] } },
                onDrift: { [self] device, rate in
                    lock.withLock { drifts.append((device, rate)) }
                })
        }
    }

    /// The Bluetooth case, which is what this exists for.
    ///
    /// A headset is two Core Audio devices. Another application opening the
    /// input one negotiates hands-free mode and takes the output down with it,
    /// so a device already inside our aggregate changes format while the device
    /// list — all `DeviceChangeWatcher` observes — stays exactly the same.
    @Test("a member dropping to hands-free rate is reported")
    func handsFreeDropIsReported() {
        let fake = Fake()
        fake.setRate(44_100, for: 7)
        let watcher = fake.makeWatcher()
        watcher.watch([7], expecting: 44_100)
        #expect(watcher.watchedDeviceCount == 1)

        fake.announce(16_000, for: 7)

        #expect(fake.drifts.count == 1)
        #expect(fake.drifts.first?.device == 7)
        #expect(fake.drifts.first?.rate == 16_000)
    }

    /// Core Audio announces the property on its own account too. Rebuilding a
    /// route because it was told what it already knew would be a route torn
    /// down for nothing.
    @Test("an announcement that changes nothing reports nothing")
    func unchangedRateIsSilent() {
        let fake = Fake()
        fake.setRate(48_000, for: 3)
        let watcher = fake.makeWatcher()
        watcher.watch([3], expecting: 48_000)

        fake.announce(48_000, for: 3)

        #expect(fake.drifts.isEmpty)
    }

    /// Core Audio can deliver a callback after removal returns, and a rebuild
    /// triggered by a route that no longer exists is a route nobody asked for.
    @Test("a callback arriving after the watch stopped is refused")
    func lateCallbackIsRevoked() {
        let fake = Fake()
        fake.setRate(44_100, for: 5)
        let watcher = fake.makeWatcher()
        watcher.watch([5], expecting: 44_100)
        let escaped = fake.blocksForTesting(5)
        watcher.stop()

        // The block Core Audio still holds, delivered after removal.
        fake.setRate(16_000, for: 5)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        escaped?(1, &address)

        #expect(fake.drifts.isEmpty)
    }

    /// A restart must not leave listeners on devices the new route does not use.
    @Test("watching again replaces the previous route's listeners")
    func rewatchReplacesRegistrations() {
        let fake = Fake()
        fake.setRate(48_000, for: 1)
        fake.setRate(48_000, for: 2)
        let watcher = fake.makeWatcher()
        watcher.watch([1, 2], expecting: 48_000)
        #expect(fake.installedCount == 2)

        watcher.watch([2], expecting: 44_100)
        #expect(fake.installedCount == 1)
        #expect(watcher.watchedDeviceCount == 1)

        // The dropped device must be silent even though its rate moved.
        fake.announce(16_000, for: 1)
        #expect(fake.drifts.isEmpty)
    }

    /// One device refusing a listener must not cost the others theirs.
    @Test("a refused registration leaves the rest watching")
    func refusedRegistrationDoesNotStopTheRest() {
        let fake = Fake()
        fake.refusedDevices = [9]
        fake.setRate(48_000, for: 8)
        let watcher = fake.makeWatcher()
        watcher.watch([8, 9], expecting: 48_000)

        #expect(watcher.watchedDeviceCount == 1)
        fake.announce(16_000, for: 8)
        #expect(fake.drifts.count == 1)
    }
}

@MainActor
@Suite("Rebuilds for a member that changes its rate")
struct MemberRateRebuildBudgetTests {

    /// A headset that keeps changing its mind must not hold the route in a
    /// restart loop. An endless restart is worse than a route at the wrong
    /// rate: the wrong rate at least makes a sound.
    @Test("the budget admits a burst and then refuses")
    func budgetBoundsTheRestarts() {
        let model = RouterModel()
        for attempt in 1...RouterModel.memberRateRebuildLimit {
            #expect(model.admitMemberRateRebuild(), "attempt \(attempt) should be admitted")
        }
        #expect(!model.admitMemberRateRebuild())
        #expect(!model.admitMemberRateRebuild())
    }

    /// And the window is a window, not a lifetime cap: a headset that switches
    /// profile once an hour is not the case being defended against.
    @Test("the limit is a rate, not a total")
    func limitIsWithinAWindow() {
        #expect(RouterModel.memberRateRebuildWindow > 0)
        #expect(RouterModel.memberRateRebuildLimit >= 2)
    }
}
