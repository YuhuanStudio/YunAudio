import CoreAudio
import Foundation
import Testing

@testable import YunAudioHAL

@Suite("Aggregate-device creation ownership", .serialized)
struct AggregateDeviceCreationOwnershipTests {
    @Test("status and out parameter classify independent ownership facts")
    func ownershipClassification() {
        let created = AggregateDeviceCreationOwnership(
            status: noErr, returnedDeviceID: 41)
        #expect(created.createdDeviceID == 41)
        #expect(created.orphanedDeviceID == nil)

        let orphaned = AggregateDeviceCreationOwnership(
            status: kAudioHardwareUnspecifiedError, returnedDeviceID: 42)
        #expect(orphaned.createdDeviceID == nil)
        #expect(orphaned.orphanedDeviceID == 42)

        let emptyFailure = AggregateDeviceCreationOwnership(
            status: kAudioHardwareUnspecifiedError,
            returnedDeviceID: kAudioObjectUnknown)
        #expect(emptyFailure.createdDeviceID == nil)
        #expect(emptyFailure.orphanedDeviceID == nil)

        let malformedSuccess = AggregateDeviceCreationOwnership(
            status: noErr, returnedDeviceID: kAudioObjectUnknown)
        #expect(malformedSuccess.createdDeviceID == nil)
        #expect(malformedSuccess.orphanedDeviceID == nil)
    }

    @Test("an error-side ID is handed off exactly once and never returned")
    func failedCreationHandsOffBeforeThrowing() {
        var handedOff: [AudioObjectID] = []
        var thrownStatus: OSStatus?

        do {
            _ = try AggregateDevice.resolveCreationAttempt(
                create: { deviceID in
                    deviceID = 73
                    return kAudioHardwareUnspecifiedError
                },
                handOffOrphan: { handedOff.append($0) })
            Issue.record("failed aggregate creation returned an owned device ID")
        } catch AggregateError.creationFailed(let status) {
            thrownStatus = status
        } catch {
            Issue.record("failed aggregate creation reported an unrelated error")
        }

        #expect(handedOff == [73])
        #expect(thrownStatus == kAudioHardwareUnspecifiedError)
    }

    @Test("a successful ID is returned without entering orphan cleanup")
    func successfulCreationPublishesOnlyCreatedID() throws {
        var handedOff: [AudioObjectID] = []

        let created = try AggregateDevice.resolveCreationAttempt(
            create: { deviceID in
                deviceID = 91
                return noErr
            },
            handOffOrphan: { handedOff.append($0) })

        #expect(created == 91)
        #expect(handedOff.isEmpty)
    }

    @Test("raw cleanup proves aggregate absence before touching dependencies")
    func rawCleanupOrder() {
        let state = RawAggregateCleanupState(requestWasAccepted: false)
        var trace: [String] = []

        let result = AggregateDevice.cleanUpRawAggregate(
            until: HALTeardownDeadline(timeout: 1),
            state: state,
            destroy: {
                trace.append("destroy")
                return noErr
            },
            isPresent: {
                trace.append("census")
                return false
            },
            destroyDependencies: {
                trace.append("dependencies")
                return true
            })

        #expect(result)
        #expect(trace == ["destroy", "census", "dependencies"])
    }

    @Test("a retry never resubmits an accepted asynchronous destroy")
    func acceptedDestroyIsNotResubmitted() {
        let state = RawAggregateCleanupState(requestWasAccepted: false)
        var trace: [String] = []

        let first = AggregateDevice.cleanUpRawAggregate(
            until: HALTeardownDeadline(timeout: 1),
            state: state,
            destroy: {
                trace.append("destroy")
                return noErr
            },
            isPresent: {
                trace.append("first-census")
                return false
            },
            destroyDependencies: {
                trace.append("first-dependencies")
                return false
            })
        let second = AggregateDevice.cleanUpRawAggregate(
            until: HALTeardownDeadline(timeout: 1),
            state: state,
            destroy: {
                trace.append("destroy-again")
                return noErr
            },
            isPresent: {
                trace.append("second-census")
                return false
            },
            destroyDependencies: {
                trace.append("second-dependencies")
                return true
            })

        #expect(!first)
        #expect(second)
        #expect(
            trace
                == [
                    "destroy", "first-census", "first-dependencies",
                    "second-dependencies",
                ])
    }

    @Test("an error status can still be closed by an exact absence census")
    func errorWithProvenAbsenceCompletes() {
        let state = RawAggregateCleanupState(requestWasAccepted: false)
        var trace: [String] = []

        let result = AggregateDevice.cleanUpRawAggregate(
            until: HALTeardownDeadline(timeout: 1),
            state: state,
            destroy: {
                trace.append("destroy-error")
                return kAudioHardwareBadObjectError
            },
            isPresent: {
                trace.append("census")
                return false
            },
            destroyDependencies: {
                trace.append("dependencies")
                return true
            })

        #expect(result)
        #expect(trace == ["destroy-error", "census", "dependencies"])
    }

    @Test("an error with a present UID never starts dependency cleanup")
    func errorWithPresentUIDRemainsOwned() {
        let state = RawAggregateCleanupState(requestWasAccepted: false)
        var dependencies = 0

        let result = AggregateDevice.cleanUpRawAggregate(
            until: HALTeardownDeadline(timeout: 0.001),
            state: state,
            destroy: { kAudioHardwareUnspecifiedError },
            isPresent: { true },
            destroyDependencies: {
                dependencies += 1
                return true
            })

        #expect(!result)
        #expect(dependencies == 0)
        #expect(!state.hasConfirmedAbsence)
    }

    @Test("a confirmed absence retry touches dependencies only")
    func dependencyRetryDoesNotReuseAggregateID() {
        let state = RawAggregateCleanupState(requestWasAccepted: false)
        var destroys = 0
        var censuses = 0
        var dependencies = 0
        func attempt() -> Bool {
            AggregateDevice.cleanUpRawAggregate(
                until: HALTeardownDeadline(timeout: 1),
                state: state,
                destroy: {
                    destroys += 1
                    return kAudioHardwareUnspecifiedError
                },
                isPresent: {
                    censuses += 1
                    return false
                },
                destroyDependencies: {
                    dependencies += 1
                    return dependencies == 2
                })
        }

        #expect(!attempt())
        #expect(attempt())
        #expect(destroys == 1)
        #expect(censuses == 1)
        #expect(dependencies == 2)
    }
}
