import CoreAudio
import Dispatch
import Foundation
import Testing

@testable import YunAudioEngine
@testable import YunAudioHAL

@Suite("Bounded echo-cancellation lifecycle", .serialized)
struct EchoCancellationLifecycleTests {
    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ value: String) { lock.withLock { storage.append(value) } }
        var values: [String] { lock.withLock { storage } }
    }

    private final class Probe: @unchecked Sendable {}

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        func increment() { lock.withLock { storage += 1 } }
        var value: Int { lock.withLock { storage } }
    }

    private func makeDisposer(
        quarantine: ProcessLifetimeAudioQuarantine,
        asynchronousTimeout: TimeInterval = 0.03
    ) -> BoundedAudioUnitDisposer {
        BoundedAudioUnitDisposer(
            quarantine: quarantine,
            asynchronousTimeout: asynchronousTimeout,
            label: "com.yuhuanstudio.yunaudio.tests.aec-lifecycle.\(UUID().uuidString)")
    }

    private func state(for step: AudioUnitTeardownStep) -> AudioUnitTeardownState {
        var state = AudioUnitTeardownState()
        switch step {
        case .stop:
            state.didInitialise()
            state.didStart()
        case .uninitialise:
            state.didInitialise()
        case .dispose:
            break
        case .start, .property:
            preconditionFailure("construction steps are not teardown phases")
        }
        return state
    }

    private func captureOwner(
        state: AudioUnitTeardownState,
        deadline: HALTeardownDeadline,
        trace: Trace,
        stop: @escaping () -> OSStatus = { noErr },
        uninitialise: @escaping () -> OSStatus = { noErr },
        dispose: @escaping () -> OSStatus = { noErr },
        aggregate: @escaping () -> HALDestructionResult = { .destroyed },
        rates: @escaping () -> [String] = { [] },
        retainedProbe: Probe = Probe()
    ) -> EchoCancellationCaptureTeardownOwner {
        EchoCancellationCaptureTeardownOwner(
            state: state,
            deadline: deadline,
            operations: EchoCancellationCaptureTeardownOperations(
                stop: {
                    trace.append("consumer.stop")
                    return stop()
                },
                uninitialise: {
                    trace.append("consumer.uninitialise")
                    return uninitialise()
                },
                dispose: {
                    trace.append("consumer.dispose")
                    return dispose()
                },
                clearCallbackBindings: { trace.append("consumer.clear-bindings") },
                destroyAggregate: { _ in
                    trace.append("consumer.destroy-aggregate")
                    return aggregate()
                },
                restoreSampleRates: { _ in
                    trace.append("consumer.restore-rates")
                    return rates()
                },
                releaseStorage: {
                    trace.append("consumer.release-storage")
                    withExtendedLifetime(retainedProbe) {}
                }))
    }

    @Test("each hung VoiceProcessingIO teardown call is bounded and terminal")
    func everyAudioUnitBoundaryIsBounded() throws {
        for step in [
            AudioUnitTeardownStep.stop, .uninitialise, .dispose,
        ] {
            let quarantine = ProcessLifetimeAudioQuarantine()
            let disposer = makeDisposer(quarantine: quarantine)
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let returned = DispatchSemaphore(value: 0)
            let trace = Trace()
            let probe = Probe()
            weak let retainedProbe = probe
            let blocking: () -> OSStatus = {
                entered.signal()
                release.wait()
                returned.signal()
                return noErr
            }
            var owner: EchoCancellationCaptureTeardownOwner? = captureOwner(
                state: state(for: step),
                deadline: HALTeardownDeadline(timeout: 0.025),
                trace: trace,
                stop: step == .stop ? blocking : { noErr },
                uninitialise: step == .uninitialise ? blocking : { noErr },
                dispose: step == .dispose ? blocking : { noErr },
                retainedProbe: probe)
            weak let retainedOwner = owner

            let began = ProcessInfo.processInfo.systemUptime
            let result = disposer.dispose(
                try #require(owner), until: HALTeardownDeadline(timeout: 0.025))
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            #expect(entered.wait(timeout: .now()) == .success)
            #expect(elapsed >= 0.015)
            #expect(elapsed < 0.25)
            #expect(result == .timedOut(step: step, disposedUnits: 0))
            #expect(disposer.transactionCount == 1)
            #expect(disposer.maximumTransactionCount == 1)
            #expect(disposer.activeTransactionCount == 1)
            #expect(quarantine.count == 1)
            #expect(disposer.acquireGraphAdmission(waitingUpTo: 0) == nil)

            owner = nil
            #expect(retainedOwner != nil)
            #expect(retainedProbe != nil)

            // A later owner is retained behind the original transaction. It
            // never starts a replacement worker, even after the first API call
            // eventually returns.
            let laterTrace = Trace()
            let later = captureOwner(
                state: state(for: .dispose),
                deadline: HALTeardownDeadline(timeout: 1), trace: laterTrace)
            disposer.disposeAfterFence(later)
            #expect(disposer.transactionCount == 1)
            #expect(laterTrace.values.isEmpty)
            #expect(quarantine.count == 2)

            release.signal()
            #expect(returned.wait(timeout: .now() + 1) == .success)
            #expect(disposer.transactionCount == 1)
            #expect(disposer.activeTransactionCount == 1)
            #expect(disposer.maximumTransactionCount == 1)
            #expect(laterTrace.values.isEmpty)
            #expect(quarantine.count == 2)
            #expect(retainedOwner != nil)
            #expect(retainedProbe != nil)
        }
    }

    @Test("success fences the consumer before stopping the producer")
    func successHasExactConsumerBeforeProducerOrder() {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let disposer = makeDisposer(quarantine: quarantine)
        let trace = Trace()
        var state = AudioUnitTeardownState()
        state.didInitialise()
        state.didStart()
        let capture = captureOwner(
            state: state, deadline: HALTeardownDeadline(timeout: 1), trace: trace)
        let bridge = EchoCancellationBridgeTeardownOwner(
            capture: capture,
            deadline: HALTeardownDeadline(timeout: 1),
            stopFarEnd: { _ in
                trace.append("producer.stop")
                return .complete
            },
            releaseStorage: { trace.append("bridge.release-storage") })

        let result = disposer.dispose(
            bridge, until: HALTeardownDeadline(timeout: 1))

        #expect(result == .complete(disposedUnits: 1))
        #expect(bridge.teardownResult == .complete)
        #expect(
            trace.values == [
                "consumer.stop", "consumer.uninitialise", "consumer.dispose",
                "consumer.clear-bindings", "consumer.destroy-aggregate",
                "consumer.restore-rates", "producer.stop",
            ])
        #expect(quarantine.count == 0)
        #expect(disposer.activeTransactionCount == 0)
        #expect(disposer.maximumTransactionCount == 1)
    }

    @Test("a consumer failure never starts the far-end producer teardown")
    func failedConsumerRetainsProducerAndSharedStorage() {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let disposer = makeDisposer(quarantine: quarantine)
        let trace = Trace()
        var state = AudioUnitTeardownState()
        state.didInitialise()
        state.didStart()
        var producerCalls = 0
        var bridge: EchoCancellationBridgeTeardownOwner? =
            EchoCancellationBridgeTeardownOwner(
                capture: captureOwner(
                    state: state, deadline: HALTeardownDeadline(timeout: 1),
                    trace: trace, stop: { OSStatus(-79_001) }),
                deadline: HALTeardownDeadline(timeout: 1),
                stopFarEnd: { _ in
                    producerCalls += 1
                    return .complete
                },
                releaseStorage: { trace.append("bridge.release-storage") })
        weak let retainedBridge = bridge

        let result = disposer.dispose(
            bridge!, until: HALTeardownDeadline(timeout: 1))
        bridge = nil

        #expect(
            result
                == .operationFailed(
                    step: .stop, status: OSStatus(-79_001), disposedUnits: 0))
        #expect(producerCalls == 0)
        #expect(retainedBridge != nil)
        #expect(quarantine.count == 1)
        #expect(disposer.activeTransactionCount == 1)
        #expect(!trace.values.contains("consumer.clear-bindings"))
        #expect(!trace.values.contains("bridge.release-storage"))
    }

    @Test("a far-end hang retains the already disposed consumer and both rings")
    func hungProducerKeepsWholeBridgeOwner() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let disposer = makeDisposer(quarantine: quarantine)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        let trace = Trace()
        var state = AudioUnitTeardownState()
        state.didInitialise()
        state.didStart()
        let sharedStorage = Probe()
        weak let retainedStorage = sharedStorage
        var bridge: EchoCancellationBridgeTeardownOwner? =
            EchoCancellationBridgeTeardownOwner(
                capture: captureOwner(
                    state: state, deadline: HALTeardownDeadline(timeout: 0.025),
                    trace: trace),
                deadline: HALTeardownDeadline(timeout: 0.025),
                stopFarEnd: { _ in
                    trace.append("producer.stop")
                    withExtendedLifetime(sharedStorage) {}
                    entered.signal()
                    release.wait()
                    returned.signal()
                    return .complete
                },
                releaseStorage: {
                    trace.append("bridge.release-storage")
                    withExtendedLifetime(sharedStorage) {}
                })
        weak let retainedBridge = bridge

        let began = ProcessInfo.processInfo.systemUptime
        let result = disposer.dispose(
            try #require(bridge), until: HALTeardownDeadline(timeout: 0.025))
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        #expect(entered.wait(timeout: .now()) == .success)
        #expect(elapsed < 0.25)
        #expect(result == .timedOut(step: nil, disposedUnits: 0))
        bridge = nil
        #expect(retainedBridge != nil)
        #expect(retainedStorage != nil)
        #expect(quarantine.count == 1)
        #expect(disposer.transactionCount == 1)
        #expect(!trace.values.contains("bridge.release-storage"))

        release.signal()
        #expect(returned.wait(timeout: .now() + 1) == .success)
        #expect(disposer.activeTransactionCount == 1)
        #expect(quarantine.count == 1)
        #expect(retainedBridge != nil)
        #expect(retainedStorage != nil)
        #expect(!trace.values.contains("bridge.release-storage"))
    }

    @Test("a retained owner is terminal and cannot clear bindings twice")
    func retainedOwnerCannotBeRetried() {
        let trace = Trace()
        let owner = captureOwner(
            state: state(for: .dispose),
            deadline: HALTeardownDeadline(timeout: 1),
            trace: trace,
            aggregate: { .requestFailed(OSStatus(-79_101)) })

        let first = owner.tearDownAudioUnits(using: AudioUnitTeardownGate())
        let second = owner.tearDownAudioUnits(using: AudioUnitTeardownGate())

        #expect(first == .ownerRetained(disposedUnits: 1))
        #expect(second == .ownerRetained(disposedUnits: 0))
        #expect(
            trace.values == [
                "consumer.dispose", "consumer.clear-bindings",
                "consumer.destroy-aggregate",
            ])
    }

    @Test("a returned Start error rolls back before graph admission reopens")
    func returnedStartErrorRollsBackInOneTransaction() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let disposer = makeDisposer(quarantine: quarantine)
        let trace = Trace()
        var state = AudioUnitTeardownState()
        state.didInitialise()
        state.didStart()
        let rollback = captureOwner(
            state: state, deadline: HALTeardownDeadline(timeout: 1), trace: trace)
        var retained: Probe? = Probe()
        weak let released = retained
        var command: EchoCancellationStartCommand? = EchoCancellationStartCommand(
            retaining: retained!,
            start: {
                trace.append("start")
                return OSStatus(-79_201)
            },
            rollback: rollback,
            transferRollbackOwnership: {
                trace.append("transfer")
                // The failed Start and its complete rollback are still one
                // active transaction at this exact boundary.
                #expect(disposer.acquireGraphAdmission(waitingUpTo: 0) == nil)
            })

        let result = disposer.dispose(
            try #require(command), until: HALTeardownDeadline(timeout: 1))
        let startStatus = command?.startStatus
        let rollbackResult = command?.rollbackResult
        command = nil
        retained = nil

        #expect(result == .complete(disposedUnits: 1))
        #expect(startStatus == OSStatus(-79_201))
        #expect(rollbackResult == .complete(disposedUnits: 1))
        #expect(
            trace.values == [
                "start", "transfer", "consumer.stop", "consumer.uninitialise",
                "consumer.dispose", "consumer.clear-bindings",
                "consumer.destroy-aggregate", "consumer.restore-rates",
            ])
        #expect(released == nil)
        #expect(quarantine.count == 0)
        #expect(disposer.activeTransactionCount == 0)
        #expect(disposer.transactionCount == 1)
        #expect(disposer.maximumTransactionCount == 1)

        let admission = disposer.acquireGraphAdmission(waitingUpTo: 0.1)
        #expect(admission != nil)
        admission?.release()

        // A later bridge teardown may encounter this already-complete capture
        // owner. It must observe the terminal result without clearing the raw
        // callback bindings for a second time.
        #expect(
            rollback.tearDownAudioUnits(using: AudioUnitTeardownGate())
                == .complete(disposedUnits: 0))
        #expect(trace.values.filter { $0 == "consumer.clear-bindings" }.count == 1)
    }

    @Test("a Start error whose rollback Stop hangs is bounded and quarantined")
    func returnedStartErrorWithHungRollbackIsTerminal() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let disposer = makeDisposer(quarantine: quarantine)
        let trace = Trace()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        var state = AudioUnitTeardownState()
        state.didInitialise()
        state.didStart()
        let rollback = captureOwner(
            state: state,
            deadline: HALTeardownDeadline(timeout: 0.025),
            trace: trace,
            stop: {
                entered.signal()
                release.wait()
                returned.signal()
                return noErr
            })
        var retained: Probe? = Probe()
        weak let quarantined = retained
        var command: EchoCancellationStartCommand? = EchoCancellationStartCommand(
            retaining: retained!,
            start: {
                trace.append("start")
                return OSStatus(-79_202)
            },
            rollback: rollback,
            transferRollbackOwnership: { trace.append("transfer") })

        let began = ProcessInfo.processInfo.systemUptime
        let result = disposer.dispose(
            try #require(command), until: HALTeardownDeadline(timeout: 0.025))
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let startStatus = command?.startStatus
        command = nil
        retained = nil

        #expect(entered.wait(timeout: .now()) == .success)
        #expect(elapsed >= 0.015)
        #expect(elapsed < 0.25)
        #expect(result == .timedOut(step: .stop, disposedUnits: 0))
        #expect(startStatus == OSStatus(-79_202))
        #expect(quarantined != nil)
        #expect(quarantine.count == 1)
        #expect(disposer.activeTransactionCount == 1)
        #expect(disposer.transactionCount == 1)
        #expect(disposer.maximumTransactionCount == 1)
        #expect(disposer.acquireGraphAdmission(waitingUpTo: 0) == nil)
        #expect(
            trace.values == [
                "start", "transfer", "consumer.stop",
            ])

        release.signal()
        #expect(returned.wait(timeout: .now() + 1) == .success)
        #expect(disposer.activeTransactionCount == 1)
        #expect(quarantine.count == 1)
        #expect(quarantined != nil)
        #expect(!trace.values.contains("consumer.uninitialise"))
        #expect(!trace.values.contains("consumer.dispose"))
        #expect(!trace.values.contains("consumer.clear-bindings"))
    }

    @Test("a lifecycle command queued past its caller never executes late")
    func deferredStartIsCancelledBeforeQueuePromotion() throws {
        let quarantine = ProcessLifetimeAudioQuarantine()
        let disposer = makeDisposer(quarantine: quarantine)
        let admission = try #require(
            disposer.acquireGraphAdmission(waitingUpTo: 0.1))
        let calls = Counter()
        let transfers = Counter()
        let trace = Trace()
        let rollback = captureOwner(
            state: state(for: .dispose),
            deadline: HALTeardownDeadline(timeout: 1), trace: trace)
        let command = EchoCancellationStartCommand(
            retaining: Probe(),
            start: {
                calls.increment()
                return OSStatus(-79_203)
            },
            rollback: rollback,
            transferRollbackOwnership: { transfers.increment() })

        let result = disposer.dispose(
            command, until: HALTeardownDeadline(timeout: 0.025))
        #expect(result == .blockedByRetainedTransaction(retainedUnits: 1))
        #expect(calls.value == 0)
        #expect(transfers.value == 0)

        // Releasing construction promotes the pending command. Cancellation
        // was published under the disposer lock before it entered that queue,
        // so even the promoted worker cannot run Start or rollback.
        admission.release()
        #expect(disposer.transactionCount == 1)
        #expect(disposer.activeTransactionCount == 1)
        #expect(quarantine.count == 1)
        #expect(calls.value == 0)
        #expect(transfers.value == 0)
        #expect(trace.values.isEmpty)
        #expect(disposer.acquireGraphAdmission(waitingUpTo: 0) == nil)
    }

    @Test("pause errors quarantine but ordinary property errors are typed")
    func lifecycleCommandClassifiesReturnedErrors() {
        let pauseQuarantine = ProcessLifetimeAudioQuarantine()
        let pauseDisposer = makeDisposer(quarantine: pauseQuarantine)
        var pauseProbe: Probe? = Probe()
        weak let retainedPauseProbe = pauseProbe
        var pauseCommand: BoundedAudioUnitLifecycleCommand? =
            BoundedAudioUnitLifecycleCommand(
                retaining: pauseProbe!, step: .stop, quarantineOnError: true,
                operation: { OSStatus(-79_204) })

        let pauseResult = pauseDisposer.dispose(
            pauseCommand!, until: HALTeardownDeadline(timeout: 1))
        pauseCommand = nil
        pauseProbe = nil

        #expect(
            pauseResult
                == .operationFailed(
                    step: .stop, status: OSStatus(-79_204), disposedUnits: 0))
        #expect(retainedPauseProbe != nil)
        #expect(pauseQuarantine.count == 1)
        #expect(pauseDisposer.activeTransactionCount == 1)

        let propertyQuarantine = ProcessLifetimeAudioQuarantine()
        let propertyDisposer = makeDisposer(quarantine: propertyQuarantine)
        var propertyProbe: Probe? = Probe()
        weak let releasedPropertyProbe = propertyProbe
        var propertyCommand: BoundedAudioUnitLifecycleCommand? =
            BoundedAudioUnitLifecycleCommand(
                retaining: propertyProbe!, step: .property,
                quarantineOnError: false,
                operation: { OSStatus(-79_205) })

        let propertyResult = propertyDisposer.dispose(
            propertyCommand!, until: HALTeardownDeadline(timeout: 1))
        let propertyStatus = propertyCommand?.completedStatus
        propertyCommand = nil
        propertyProbe = nil

        #expect(propertyResult == .complete(disposedUnits: 0))
        #expect(propertyStatus == OSStatus(-79_205))
        #expect(releasedPropertyProbe == nil)
        #expect(propertyQuarantine.count == 0)
        #expect(propertyDisposer.activeTransactionCount == 0)
    }
}
