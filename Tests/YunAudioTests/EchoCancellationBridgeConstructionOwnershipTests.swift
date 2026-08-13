import CoreAudio
import Foundation
import Testing

@testable import YunAudioEngine
@testable import YunAudioHAL

@Suite("Echo-cancellation bridge construction ownership", .serialized)
struct EchoCancellationBridgeConstructionOwnershipTests {
    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ value: String) { lock.withLock { storage.append(value) } }
        var values: [String] { lock.withLock { storage } }
    }

    private final class Submission: @unchecked Sendable {
        private let lock = NSLock()
        private var storedOwner: (any AudioUnitTeardownOwner)?
        private var storedCount = 0

        func accept(_ owner: any AudioUnitTeardownOwner) {
            lock.withLock {
                storedCount += 1
                storedOwner = owner
            }
        }

        var owner: (any AudioUnitTeardownOwner)? { lock.withLock { storedOwner } }
        var count: Int { lock.withLock { storedCount } }
    }

    @Test("a failed constructor submits capture then far end exactly once")
    func failedConstructionHasOneOrderedOwner() throws {
        let trace = Trace()
        let submission = Submission()
        let owner = EchoCancellationBridgePartialConstructionOwner(
            submit: { submission.accept($0) })
        owner.adoptFarEnd { _ in
            trace.append("far-end")
            return true
        }
        owner.adoptCapture { _, _ in
            trace.append("capture")
            return .complete(disposedUnits: 1)
        }

        owner.disposeAfterConstruction()
        owner.disposeAfterConstruction()
        let submitted = try #require(submission.owner)
        let result = submitted.tearDownAudioUnits(using: AudioUnitTeardownGate())

        #expect(submission.count == 1)
        #expect(result == .complete(disposedUnits: 1))
        #expect(trace.values == ["capture", "far-end"])
        #expect(!submitted.hasTeardownWork)
        #expect(submitted.audioUnitCount == 0)
    }

    @Test("a capture refusal never starts far-end HAL teardown")
    func captureFailureRetainsTheCompletePartialGraph() throws {
        let trace = Trace()
        let submission = Submission()
        let owner = EchoCancellationBridgePartialConstructionOwner(
            submit: { submission.accept($0) })
        owner.adoptFarEnd { _ in
            trace.append("far-end")
            return true
        }
        owner.adoptCapture { _, _ in
            trace.append("capture")
            return .operationFailed(
                step: .dispose, status: OSStatus(-79_211), disposedUnits: 0)
        }

        owner.disposeAfterConstruction()
        let submitted = try #require(submission.owner)
        let result = submitted.tearDownAudioUnits(using: AudioUnitTeardownGate())

        #expect(
            result
                == .operationFailed(
                    step: .dispose, status: OSStatus(-79_211), disposedUnits: 0))
        #expect(trace.values == ["capture"])
        #expect(submitted.hasTeardownWork)
        #expect(submitted.audioUnitCount == 1)
    }

    @Test("cancellation after capture refuses every later HAL operation")
    func cancellationBetweenOwnersFailsClosed() throws {
        let trace = Trace()
        let submission = Submission()
        let owner = EchoCancellationBridgePartialConstructionOwner(
            submit: { submission.accept($0) })
        owner.adoptFarEnd { _ in
            trace.append("far-end")
            return true
        }
        owner.adoptCapture { gate, _ in
            trace.append("capture")
            _ = gate.cancel()
            return .complete(disposedUnits: 1)
        }

        owner.disposeAfterConstruction()
        let submitted = try #require(submission.owner)
        let result = submitted.tearDownAudioUnits(using: AudioUnitTeardownGate())

        #expect(result == .timedOut(step: nil, disposedUnits: 1))
        #expect(trace.values == ["capture"])
        #expect(submitted.hasTeardownWork)
        #expect(submitted.audioUnitCount == 0)
    }

    @Test("a rejected mismatched far end belongs only to its independent disposer")
    func relinquishedFarEndIsNotTornDownTwice() throws {
        let trace = Trace()
        let submission = Submission()
        let owner = EchoCancellationBridgePartialConstructionOwner(
            submit: { submission.accept($0) })
        owner.adoptFarEnd { _ in
            trace.append("far-end")
            return true
        }
        owner.relinquishFarEnd()
        owner.adoptCapture { _, _ in
            trace.append("capture")
            return .complete(disposedUnits: 1)
        }

        owner.disposeAfterConstruction()
        let submitted = try #require(submission.owner)
        let result = submitted.tearDownAudioUnits(using: AudioUnitTeardownGate())

        #expect(result == .complete(disposedUnits: 1))
        #expect(trace.values == ["capture"])
        #expect(!submitted.hasTeardownWork)
    }

    @Test("a far-end-only partial graph is still submitted without an Audio Unit")
    func farEndOnlyFailureStillHasTeardownWork() throws {
        let trace = Trace()
        let submission = Submission()
        let owner = EchoCancellationBridgePartialConstructionOwner(
            submit: { submission.accept($0) })
        owner.adoptFarEnd { _ in
            trace.append("far-end")
            return true
        }

        owner.disposeAfterConstruction()
        let submitted = try #require(submission.owner)
        let result = submitted.tearDownAudioUnits(using: AudioUnitTeardownGate())

        #expect(submission.count == 1)
        #expect(result == .complete(disposedUnits: 0))
        #expect(trace.values == ["far-end"])
        #expect(!submitted.hasTeardownWork)
        #expect(submitted.audioUnitCount == 0)
    }

    @Test("production wiring registers cleanup before constructing either inner owner")
    func bridgeRegistersAfterReturnCleanupBeforeItsFirstResource() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioEngine/EchoCancellationBridge.swift",
            encoding: .utf8)
        let start = try #require(
            source.range(of: "    init(\n        microphoneUID:"))
        let end = try #require(
            source.range(of: "\n    deinit {", range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]
        let registration = try #require(body.range(of: "deferCleanupAfterCancellation"))
        let farEnd = try #require(body.range(of: "FarEndCapture("))
        let adoptFarEnd = try #require(
            body.range(of: "partialOwner.adopt(candidateReference)"))
        let capture = try #require(body.range(of: "try EchoCancellingCapture("))
        let adoptCapture = try #require(body.range(of: "partialOwner.adopt(capture)"))
        let publication = try #require(body.range(of: "constructionCompleted = true"))

        #expect(registration.lowerBound < farEnd.lowerBound)
        #expect(farEnd.lowerBound < adoptFarEnd.lowerBound)
        #expect(adoptFarEnd.lowerBound < capture.lowerBound)
        #expect(capture.lowerBound < adoptCapture.lowerBound)
        #expect(adoptCapture.lowerBound < publication.lowerBound)
        #expect(body.contains("partialOwner.disposeAfterConstruction()"))
        #expect(body.contains("withExtendedLifetime(cleanupRegistration)"))
        #expect(!body.contains("retainAfterCancellation"))
        #expect(!body.contains("cleanupRegistration?.cancel()"))
    }
}
