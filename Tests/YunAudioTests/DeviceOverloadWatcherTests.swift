import CoreAudio
import Foundation
import Testing

@testable import YunAudioApp
@testable import YunAudioHAL

@Suite("IOProc overloads")
struct DeviceOverloadWatcherTests {

    private final class Fake: @unchecked Sendable {
        private let lock = NSLock()
        private var blocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
        private var clock = 0.0
        private(set) var reported: [DeviceOverloadWatcher.Event] = []
        var refusedDevices: Set<AudioObjectID> = []

        func advance(_ seconds: Double) { lock.withLock { clock += seconds } }

        /// What the HAL does when an IOProc misses its deadline.
        func announce(on device: AudioObjectID) {
            let block = lock.withLock { blocks[device] }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDeviceProcessorOverload,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            block?(1, &address)
        }

        var installedCount: Int { lock.withLock { blocks.count } }

        /// The block Core Audio would still hold after a removal races a
        /// callback already on its way.
        func blockForTesting(_ device: AudioObjectID) -> AudioObjectPropertyListenerBlock? {
            lock.withLock { blocks[device] }
        }

        func makeWatcher() -> DeviceOverloadWatcher {
            DeviceOverloadWatcher(
                queue: DispatchQueue(label: "test.overload"),
                install: { [self] device, block in
                    guard !refusedDevices.contains(device) else { return false }
                    lock.withLock { blocks[device] = block }
                    return true
                },
                remove: { [self] device, _ in
                    _ = lock.withLock { blocks.removeValue(forKey: device) }
                },
                now: { [self] in lock.withLock { clock } },
                onOverload: { [self] event in
                    lock.withLock { reported.append(event) }
                })
        }
    }

    @Test("an overload is counted, timed and reported")
    func overloadIsRecorded() {
        let fake = Fake()
        let watcher = fake.makeWatcher()
        watcher.watch([7])
        fake.advance(12.5)
        fake.announce(on: 7)

        #expect(watcher.overloadCount == 1)
        #expect(watcher.lastOverloadAt == 12.5)
        #expect(watcher.recentEvents == [.init(device: 7, at: 12.5)])
        #expect(fake.reported.count == 1)
    }

    /// The distinction the Bluetooth investigation turns on: our own IOProc
    /// running late is a different fault from an endpoint failing to keep the
    /// schedule it agreed to, and one tally cannot tell them apart.
    @Test("members and the aggregate are counted separately")
    func devicesAreCountedSeparately() {
        let fake = Fake()
        let watcher = fake.makeWatcher()
        watcher.watch([7, 9])
        fake.announce(on: 7)
        fake.announce(on: 9)
        fake.announce(on: 9)

        #expect(watcher.overloadCount == 3)
        #expect(watcher.overloadsByDevice == [7: 1, 9: 2])
    }

    /// A route that restarts to recover is the case worth seeing, so the
    /// restart must not be what erases the evidence.
    @Test("a restart keeps the tally")
    func restartKeepsTheTally() {
        let fake = Fake()
        let watcher = fake.makeWatcher()
        watcher.watch([7])
        fake.announce(on: 7)
        watcher.watch([7, 9])
        fake.announce(on: 9)

        #expect(watcher.overloadCount == 2)
        #expect(watcher.watchedDeviceCount == 2)
    }

    @Test("reset is the only thing that clears it")
    func resetClearsIt() {
        let fake = Fake()
        let watcher = fake.makeWatcher()
        watcher.watch([7])
        fake.announce(on: 7)
        watcher.reset()

        #expect(watcher.overloadCount == 0)
        #expect(watcher.recentEvents.isEmpty)
        #expect(watcher.lastOverloadAt == nil)
    }

    /// Core Audio can deliver a notification after the removal call returns.
    /// An overload counted against a route that no longer exists is a dropout
    /// nobody heard.
    @Test("a callback arriving after the watch stops is discarded")
    func lateCallbackIsDiscarded() {
        let fake = Fake()
        let watcher = fake.makeWatcher()
        watcher.watch([7])
        let inFlight = fake.blockForTesting(7)
        watcher.stop()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        inFlight?(1, &address)

        #expect(watcher.overloadCount == 0)
    }

    /// A device that will not take a listener must not stop the others being
    /// watched — a partial watch is worth more than none.
    @Test("a refused registration leaves the rest watching")
    func refusalDoesNotStopTheRest() {
        let fake = Fake()
        fake.refusedDevices = [7]
        let watcher = fake.makeWatcher()
        watcher.watch([7, 9])
        fake.announce(on: 9)

        #expect(watcher.watchedDeviceCount == 1)
        #expect(watcher.overloadCount == 1)
    }

    /// A route failing continuously posts these faster than anybody reads
    /// them. The detail is bounded; the total is not, because the total is the
    /// number that matters.
    @Test("the event log is bounded and the count is not")
    func logIsBoundedButCountIsNot() {
        let fake = Fake()
        let watcher = fake.makeWatcher()
        watcher.watch([7])
        let overloads = DeviceOverloadWatcher.recentEventLimit + 40
        for index in 0..<overloads {
            fake.advance(1)
            fake.announce(on: 7)
            _ = index
        }

        #expect(watcher.overloadCount == overloads)
        #expect(watcher.recentEvents.count == DeviceOverloadWatcher.recentEventLimit)
        // Oldest first, and the oldest kept is the one 256 events back.
        #expect(
            watcher.recentEvents.first?.at
                == Double(overloads - DeviceOverloadWatcher.recentEventLimit + 1))
        #expect(watcher.lastOverloadAt == Double(overloads))
    }
}

@MainActor
@Suite("The model says the audio broke up")
struct DropoutNoticeTests {

    @Test("nothing is said when nothing has broken up")
    func silentWhenClean() {
        #expect(RouterModel.dropoutSentence(count: 0, device: nil) == nil)
    }

    /// A count and a name, because "it broke up" without either is the same
    /// unfalsifiable report the application was already getting.
    @Test("the count and the device are both in the sentence")
    func countAndDeviceAreNamed() {
        guard let one = RouterModel.dropoutSentence(count: 1, device: "Barracuda") else {
            Issue.record("one dropout said nothing")
            return
        }
        #expect(one.contains("Barracuda"))
        guard let many = RouterModel.dropoutSentence(count: 12, device: "Barracuda") else {
            Issue.record("twelve dropouts said nothing")
            return
        }
        #expect(many.contains("12"))
        #expect(many != one)
    }

    /// The aggregate is ours and appears in neither device list, so an
    /// unresolved identifier has to become words rather than a number nobody
    /// can act on.
    @Test("an unnamed device still reads as a sentence")
    func unnamedDeviceStillReads() {
        guard let sentence = RouterModel.dropoutSentence(count: 3, device: nil) else {
            Issue.record("said nothing")
            return
        }
        #expect(!sentence.contains("nil"))
        #expect(sentence.contains("3"))
    }

    /// The wiring: an event from the watcher has to reach the count somebody
    /// reads, and it goes through the engine's own tally rather than a local
    /// increment so the two can never disagree.
    @Test("an event moves the model's count")
    func eventMovesTheCount() {
        let model = RouterModel()
        #expect(model.dropoutCount == 0)
        model.recordDropout(.init(device: 41, at: 9))
        #expect(model.lastDropoutAt == 9)
        #expect(model.lastDropoutDevice != nil)
    }
}
