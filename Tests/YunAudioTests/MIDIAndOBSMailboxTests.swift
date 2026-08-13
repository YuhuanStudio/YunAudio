import Foundation
import Testing

@testable import YunAudioApp

@Suite("MIDI and OBS event-storm mailboxes", .serialized)
@MainActor
struct MIDIAndOBSMailboxTests {
    private final class ScheduledMIDIDrains: @unchecked Sendable {
        private let lock = NSLock()
        private var operations: [MIDIMainActorDeliveryMailbox.ScheduledOperation] = []

        func schedule(
            _ operation: @escaping MIDIMainActorDeliveryMailbox.ScheduledOperation
        ) {
            lock.withLock { operations.append(operation) }
        }

        var count: Int { lock.withLock { operations.count } }

        @MainActor
        func runNext() {
            let operation = lock.withLock { operations.removeFirst() }
            operation()
        }
    }

    private final class LockedValues<Element: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Element] = []

        func append(contentsOf values: [Element]) {
            lock.withLock { storage.append(contentsOf: values) }
        }

        var values: [Element] { lock.withLock { storage } }
    }

    private actor ControlledApplication<Value: Sendable> {
        private var applied: [Value] = []
        private var waiting: [(Value, CheckedContinuation<Value, Never>)] = []

        func apply(_ value: Value) async -> Value {
            applied.append(value)
            return await withCheckedContinuation { continuation in
                waiting.append((value, continuation))
            }
        }

        func releaseNext() {
            let (value, continuation) = waiting.removeFirst()
            continuation.resume(returning: value)
        }

        var appliedValues: [Value] { applied }
        var waitingCount: Int { waiting.count }
    }

    @MainActor
    private final class PublishedValues<Element: Sendable> {
        var values: [Element] = []
    }

    @Test("one hundred thousand continuous messages schedule one latest delivery")
    func continuousStormIsOneScheduledLatest() {
        let scheduler = ScheduledMIDIDrains()
        let delivered = LockedValues<MIDIMessage>()
        let mailbox = MIDIMainActorDeliveryMailbox(
            schedule: { scheduler.schedule($0) },
            deliver: { _, deliveries in
                delivered.append(contentsOf: deliveries.map(\.message))
            })
        mailbox.activate(generation: 1, targetsByAddress: [:], learningTarget: nil)

        for value in 0..<100_000 {
            mailbox.submit(
                generation: 1,
                messages: [.cc(7, UInt16(value % 128))])
        }

        var statistics = mailbox.statistics
        #expect(scheduler.count == 1)
        #expect(statistics.scheduledDrains == 1)
        #expect(statistics.submittedMessages == 100_000)
        #expect(statistics.supersededContinuousMessages == 99_999)
        #expect(statistics.pendingContinuousAddresses == 1)
        #expect(statistics.maximumObservedPendingContinuousAddresses == 1)
        #expect(statistics.pendingEdges == 0)
        #expect(statistics.continuousAddressOverflows == 0)
        #expect(statistics.edgeOverflows == 0)

        scheduler.runNext()
        statistics = mailbox.statistics
        #expect(delivered.values == [.cc(7, 31)])
        #expect(statistics.deliveredMessages == 1)
        #expect(statistics.pendingContinuousAddresses == 0)
        #expect(statistics.pendingEdges == 0)
        #expect(scheduler.count == 0)
    }

    @Test("continuous keys are finite and old generations cannot deliver")
    func continuousAddressCapacityAndGenerationAreExplicit() {
        let scheduler = ScheduledMIDIDrains()
        let delivered = LockedValues<MIDIMessage>()
        let mailbox = MIDIMainActorDeliveryMailbox(
            maximumPendingContinuousAddresses: 16,
            schedule: { scheduler.schedule($0) },
            deliver: { _, deliveries in
                delivered.append(contentsOf: deliveries.map(\.message))
            })
        mailbox.activate(generation: 4, targetsByAddress: [:], learningTarget: nil)

        for controller in 0..<100 {
            mailbox.submit(
                generation: 4,
                messages: [.cc(UInt8(controller), UInt16(controller))])
        }
        var statistics = mailbox.statistics
        #expect(statistics.pendingContinuousAddresses == 16)
        #expect(statistics.maximumObservedPendingContinuousAddresses == 16)
        #expect(statistics.continuousAddressOverflows == 84)
        #expect(scheduler.count == 1)

        mailbox.activate(generation: 5, targetsByAddress: [:], learningTarget: nil)
        mailbox.submit(generation: 4, messages: [.cc(7, 126)])
        mailbox.submit(generation: 5, messages: [.cc(7, 127)])
        statistics = mailbox.statistics
        #expect(statistics.revokedMessages == 17)
        #expect(statistics.pendingContinuousAddresses == 1)

        scheduler.runNext()
        statistics = mailbox.statistics
        #expect(delivered.values == [.cc(7, 127)])
        #expect(statistics.deliveredMessages == 1)
        #expect(statistics.pendingContinuousAddresses == 0)
        #expect(statistics.scheduledDrains == 1)
    }

    @Test("note and command edges stay ordered or report exact overflow")
    func edgesAreNeverSilentlyCoalesced() {
        let scheduler = ScheduledMIDIDrains()
        let delivered = LockedValues<MIDIMessage>()
        let commandAddress = MIDIAddress(channel: 0, kind: .controlChange(64))
        let mailbox = MIDIMainActorDeliveryMailbox(
            maximumPendingEdges: 66,
            schedule: { scheduler.schedule($0) },
            deliver: { _, deliveries in
                delivered.append(contentsOf: deliveries.map(\.message))
            })
        mailbox.activate(
            generation: 1,
            targetsByAddress: [commandAddress: .command(url: "yunaudio://mute")],
            learningTarget: nil)

        let noteEdges = (0..<32).flatMap { _ in
            [
                MIDIMessage.note(60, velocity: 127),
                MIDIMessage.note(60, velocity: 0),
            ]
        }
        let commandEdges = [MIDIMessage.cc(64, 127), MIDIMessage.cc(64, 0)]
        let expected = noteEdges + commandEdges
        mailbox.submit(generation: 1, messages: expected)

        #expect(mailbox.statistics.pendingEdges == 66)
        #expect(mailbox.statistics.maximumObservedPendingEdges == 66)
        #expect(mailbox.statistics.edgeOverflows == 0)
        scheduler.runNext()
        #expect(delivered.values == expected)
        #expect(mailbox.statistics.deliveredMessages == 66)

        let overflowScheduler = ScheduledMIDIDrains()
        let overflowDelivered = LockedValues<MIDIMessage>()
        let overflow = MIDIMainActorDeliveryMailbox(
            maximumPendingEdges: 8,
            schedule: { overflowScheduler.schedule($0) },
            deliver: { _, deliveries in
                overflowDelivered.append(contentsOf: deliveries.map(\.message))
            })
        overflow.activate(generation: 1, targetsByAddress: [:], learningTarget: nil)
        let tenEdges = (0..<10).map {
            MIDIMessage.note(UInt8($0), velocity: 127)
        }
        overflow.submit(generation: 1, messages: tenEdges)
        #expect(overflow.statistics.pendingEdges == 8)
        #expect(overflow.statistics.edgeOverflows == 2)
        overflowScheduler.runNext()
        #expect(overflowDelivered.values == Array(tenEdges.prefix(8)))
        #expect(overflow.statistics.deliveredMessages == 8)
        #expect(overflow.statistics.edgeOverflows == 2)
    }

    @Test("learning a command preserves the first CC edge")
    func commandLearningDoesNotCoalescePressIntoRelease() {
        let scheduler = ScheduledMIDIDrains()
        let delivered = LockedValues<MIDIMainActorDeliveryMailbox.Delivery>()
        let target = MIDITarget.command(url: "yunaudio://mute")
        let mailbox = MIDIMainActorDeliveryMailbox(
            schedule: { scheduler.schedule($0) },
            deliver: { _, deliveries in
                delivered.append(contentsOf: deliveries)
            })
        mailbox.activate(
            generation: 1, targetsByAddress: [:],
            learningTarget: target)

        let press = MIDIMessage.cc(64, 127)
        let release = MIDIMessage.cc(64, 0)
        mailbox.submit(generation: 1, messages: [press, release])

        #expect(mailbox.statistics.pendingEdges == 2)
        #expect(mailbox.statistics.pendingContinuousAddresses == 0)
        #expect(mailbox.statistics.edgeOverflows == 0)
        scheduler.runNext()
        #expect(delivered.values.map(\.message) == [press, release])
        #expect(delivered.values.map(\.disposition) == [.learning(target), .learning(target)])
        #expect(mailbox.statistics.deliveredMessages == 2)
    }

    @Test("an unbound event stays diagnostic-only when bound before its drain")
    func unboundEventCannotAcquireALaterBinding() {
        let scheduler = ScheduledMIDIDrains()
        let controller = MIDIController()
        controller.diagnosticsAreVisible = true
        var actions = 0
        controller.perform = { _, _ in actions += 1 }
        let mailbox = MIDIMainActorDeliveryMailbox(
            schedule: { scheduler.schedule($0) },
            deliver: { _, deliveries in
                for delivery in deliveries { controller.receive(delivery) }
            })
        mailbox.activate(generation: 1, targetsByAddress: [:], learningTarget: nil)

        let message = MIDIMessage.cc(64, 127)
        let address = message.address
        let laterTarget = MIDITarget.command(url: "yunaudio://mute")
        mailbox.submit(generation: 1, messages: [message])
        controller.bind(address, to: laterTarget)
        mailbox.updatePolicy(
            generation: 1, targetsByAddress: [address: laterTarget], learningTarget: nil)

        #expect(scheduler.count == 1)
        #expect(mailbox.statistics.pendingContinuousAddresses == 1)
        scheduler.runNext()
        #expect(actions == 0)
        #expect(controller.lastMessage == message)
        #expect(controller.diagnosticPublications == 1)
        #expect(mailbox.statistics.deliveredMessages == 1)
        #expect(mailbox.statistics.revokedMessages == 0)
    }

    @Test("a rebind revokes the old action without redirecting it")
    func boundEventCannotActOnAReplacementTarget() {
        let scheduler = ScheduledMIDIDrains()
        let controller = MIDIController()
        let address = MIDIAddress(channel: 0, kind: .note(36))
        let original = MIDITarget.command(url: "yunaudio://mute")
        let replacement = MIDITarget.command(url: "yunaudio://record/start")
        controller.bind(address, to: original)
        controller.diagnosticsAreVisible = true
        var actedTargets: [MIDITarget] = []
        controller.perform = { target, action in
            if action == .press { actedTargets.append(target) }
        }
        let dispositions = LockedValues<MIDIMainActorDeliveryMailbox.Delivery.Disposition>()
        let mailbox = MIDIMainActorDeliveryMailbox(
            schedule: { scheduler.schedule($0) },
            deliver: { _, deliveries in
                dispositions.append(contentsOf: deliveries.map(\.disposition))
                for delivery in deliveries { controller.receive(delivery) }
            })
        mailbox.activate(
            generation: 1, targetsByAddress: [address: original], learningTarget: nil)

        let message = MIDIMessage.note(36, velocity: 127)
        mailbox.submit(generation: 1, messages: [message])
        controller.bind(address, to: replacement)
        mailbox.updatePolicy(
            generation: 1, targetsByAddress: [address: replacement], learningTarget: nil)

        scheduler.runNext()
        #expect(dispositions.values == [.bound(original)])
        #expect(actedTargets.count == 0)
        #expect(!actedTargets.contains(original))
        #expect(!actedTargets.contains(replacement))
        #expect(controller.lastMessage == message)
        #expect(controller.diagnosticPublications == 1)
        #expect(mailbox.statistics.deliveredMessages == 1)
        #expect(mailbox.statistics.revokedMessages == 0)
    }

    @Test("ten thousand OBS mute intents apply first and latest only")
    func obsMuteStormIsOneActiveOneLatest() async {
        let application = ControlledApplication<Bool>()
        let published = PublishedValues<Bool>()
        let mailbox = OBSOneActiveLatestMailbox<Bool, Bool>(
            apply: { await application.apply($0) },
            publish: { _, value, _ in published.values.append(value) })
        mailbox.activate(generation: 1)

        for index in 0..<10_000 {
            mailbox.submit(generation: 1, value: index == 9_999)
        }
        var statistics = mailbox.statistics
        #expect(statistics.submitted == 10_000)
        #expect(statistics.startedApplications == 1)
        #expect(statistics.superseded == 9_998)
        #expect(statistics.activeCount == 1)
        #expect(statistics.pendingCount == 1)
        #expect(statistics.maximumPendingCount == 1)
        #expect(statistics.maximumConcurrentApplications == 1)

        let firstApplicationStarted = await wait {
            await application.waitingCount == 1
        }
        #expect(firstApplicationStarted)
        await application.releaseNext()
        let latestApplicationEntered = await wait {
            await application.appliedValues.count == 2
        }
        #expect(latestApplicationEntered)
        #expect(mailbox.statistics.startedApplications == 2)
        let appliedValues = await application.appliedValues
        #expect(appliedValues == [false, true])
        await application.releaseNext()
        let applicationsCompleted = await wait {
            mailbox.statistics.completedApplications == 2
        }
        #expect(applicationsCompleted)

        statistics = mailbox.statistics
        #expect(statistics.startedApplications == 2)
        #expect(statistics.completedApplications == 2)
        #expect(statistics.activeCount == 0)
        #expect(statistics.pendingCount == 0)
        #expect(statistics.maximumConcurrentApplications == 1)
        #expect(published.values == [false, true])
    }

    @Test("ten thousand link intents become two websocket mute requests")
    func obsMuteStormIsBoundedOnTheWire() async throws {
        let server = try StubOBSServer(password: nil)
        defer { server.stop() }
        let link = OBSLink(
            host: "127.0.0.1", port: Int(server.port), inputName: "Mic/Aux",
            mirrorsMute: true)
        await link.connect()
        #expect(link.isConnected)

        for index in 0..<10_000 {
            link.requestMuteMirror(index == 9_999)
        }
        var statistics = link.muteDeliveryStatistics
        #expect(statistics.submitted == 10_000)
        #expect(statistics.startedApplications == 1)
        #expect(statistics.pendingCount == 1)
        #expect(statistics.maximumPendingCount == 1)
        #expect(statistics.maximumConcurrentApplications == 1)

        let requestsReachedWire = await wait {
            server.requests.filter {
                $0.data["requestType"]?.stringValue == "SetInputMute"
            }.count == 2
        }
        #expect(requestsReachedWire)
        let requestsCompleted = await wait {
            link.muteDeliveryStatistics.completedApplications == 2
        }
        #expect(requestsCompleted)
        statistics = link.muteDeliveryStatistics
        #expect(statistics.startedApplications == 2)
        #expect(statistics.completedApplications == 2)
        #expect(statistics.activeCount == 0)
        #expect(statistics.pendingCount == 0)
        #expect(statistics.maximumConcurrentApplications == 1)

        let muteRequests = server.requests.filter {
            $0.data["requestType"]?.stringValue == "SetInputMute"
        }
        #expect(muteRequests.count == 2)
        #expect(
            muteRequests.map {
                $0.data["requestData"]?["inputMuted"]?.boolValue
            } == [false, true])
        await link.disconnect()
    }

    @Test("an old OBS completion cannot publish into a new connection")
    func obsConnectionGenerationRevokesPendingAndLateResults() async {
        let application = ControlledApplication<Int>()
        let published = PublishedValues<Int>()
        let mailbox = OBSOneActiveLatestMailbox<Int, Int>(
            apply: { await application.apply($0) },
            publish: { _, value, _ in published.values.append(value) })
        mailbox.activate(generation: 1)
        mailbox.submit(generation: 1, value: 10)
        mailbox.submit(generation: 1, value: 11)
        let oldApplicationStarted = await wait {
            await application.waitingCount == 1
        }
        #expect(oldApplicationStarted)

        mailbox.activate(generation: 2)
        mailbox.submit(generation: 2, value: 20)
        #expect(mailbox.statistics.revoked == 1)
        #expect(mailbox.statistics.pendingCount == 1)
        await application.releaseNext()
        let newApplicationStarted = await wait {
            mailbox.statistics.startedApplications == 2
        }
        #expect(newApplicationStarted)
        let appliedValues = await application.appliedValues
        #expect(appliedValues == [10, 20])
        #expect(published.values.isEmpty)

        await application.releaseNext()
        let applicationsCompleted = await wait {
            mailbox.statistics.completedApplications == 2
        }
        #expect(applicationsCompleted)
        let statistics = mailbox.statistics
        #expect(statistics.staleCompletions == 1)
        #expect(statistics.revoked == 1)
        #expect(statistics.maximumPendingCount == 1)
        #expect(statistics.maximumConcurrentApplications == 1)
        #expect(published.values == [20])
    }

    private func wait(
        iterations: Int = 1_000,
        until condition: @escaping @MainActor @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<iterations {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }
}
