import CoreAudio
import Foundation
import Testing

@testable import YunAudioEngine
@testable import YunAudioHAL
@testable import YunAudioApp

@MainActor
@Suite("Router teardown admission")
struct RouterTeardownAdmissionTests {
    @Test("an incomplete teardown keeps exactly the retrying Stop state")
    func incompleteTeardownIsFailClosed() {
        let model = RouterModel()
        let status = OSStatus(-73_001)

        model.retainFailedTeardown(.ioProcDestroyFailed(status))

        #expect(model.isRunning)
        #expect(!model.isBusy)
        #expect(model.teardownNeedsRetry)
        #expect(model.teardownFailureDetail?.contains("-73001") == true)
        #expect(model.scriptStatus["teardownNeedsRetry"] == .bool(true))
        #expect(model.scriptStatus["teardownFailure"]?.stringValue?.contains("-73001") == true)
        let message = model.lastError

        let outcome = model.performApplicationCommand(.routing(true))
        #expect(outcome.message == message)
        #expect(outcome.failed)

        // Start must be a no-op while the old callback lifetime is uncertain.
        model.start()
        #expect(model.isRunning)
        #expect(model.teardownNeedsRetry)
        #expect(model.lastError == message)
    }
}

@Suite("Core Audio teardown state machines")
struct CoreAudioTeardownStateMachineTests {
    @Test("echo capture delegates teardown and deinit to the sole bounded worker")
    func echoCaptureUsesBoundedLifecycleOwner() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioEngine/EchoCancellingCapture.swift",
            encoding: .utf8)
        let start = try #require(source.range(of: "public func stop(timeout:"))
        let end = try #require(
            source.range(
                of: "/// Exactly-once transfer of every pointer",
                range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]
        #expect(body.contains("BoundedAudioUnitDisposer.shared.dispose(detached"))
        #expect(!body.contains("AudioOutputUnitStop"))
        #expect(!body.contains("AudioUnitUninitialize"))
        #expect(!body.contains("AudioComponentInstanceDispose"))

        let lifecycle = try String(
            contentsOfFile: root
                + "Sources/YunAudioEngine/EchoCancellationLifecycle.swift",
            encoding: .utf8)
        #expect(lifecycle.contains("gate.perform(.stop"))
        #expect(lifecycle.contains("gate.perform(.uninitialise"))
        #expect(lifecycle.contains("gate.perform(.dispose"))

        let deinitialiser = try #require(source.range(of: "deinit {"))
        let startMethod = try #require(
            source.range(
                of: "public func start(",
                range: deinitialiser.upperBound..<source.endIndex))
        let deinitBody = source[deinitialiser.lowerBound..<startMethod.lowerBound]
        #expect(deinitBody.contains("disposeAfterFence(detached)"))
        #expect(!deinitBody.contains("stop()"))
    }

    @Test("far-end IOProc stop and destroy both use deadline admission")
    func farEndCaptureWiresDeadlineAdmission() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioEngine/FarEndCapture.swift",
            encoding: .utf8)
        let start = try #require(source.range(of: "public func stop(until deadline:"))
        let end = try #require(
            source.range(
                of: "/// Drains mono frames",
                range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]

        #expect(body.ranges(of: "deadline.perform").count == 2)
        #expect(body.contains("aggregate.destroyAndWait(until: deadline)"))
        #expect(body.contains("tap.destroyAndWait(until: deadline)"))
    }

    @Test("only teardown failures with live HAL ownership require quarantine")
    func routingQuarantinePolicy() {
        #expect(!RoutingTeardownResult.complete.requiresOwnerQuarantine)
        #expect(
            !RoutingTeardownResult.sampleRatesNotRestored(["device"])
                .requiresOwnerQuarantine)
        #expect(
            !RoutingTeardownResult.audioUnitOwner(
                .timedOut(step: .uninitialise, disposedUnits: 0)
            )
            .requiresOwnerQuarantine)
        #expect(RoutingTeardownResult.ioProcStopFailed(-1).requiresOwnerQuarantine)
        #expect(RoutingTeardownResult.ioProcDestroyFailed(-2).requiresOwnerQuarantine)
        #expect(RoutingTeardownResult.lifecycleQueueTimedOut.requiresOwnerQuarantine)
        #expect(
            RoutingTeardownResult.ioProcTimedOut(step: .destroy)
                .requiresOwnerQuarantine)
        #expect(RoutingTeardownResult.clockPublisherTimedOut.requiresOwnerQuarantine)
        #expect(
            RoutingTeardownResult.aggregate(.timedOut).requiresOwnerQuarantine)
        #expect(
            RoutingTeardownResult.processTap(uid: "tap", result: .timedOut)
                .requiresOwnerQuarantine)
    }

    @Test("RoutingEngine reclaims nothing before the IOProc destroy fence")
    func routingEngineWiresFailureBeforeReclamation() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioEngine/RoutingEngine.swift",
            encoding: .utf8)
        let start = try #require(source.range(of: "private func stopLocked("))
        let end = try #require(
            source.range(
                of: "private func recoverFromClockLockLoss()",
                range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]
        let stopFailure = try #require(body.range(of: "case .stopFailed"))
        let destroyFailure = try #require(body.range(of: "case .destroyFailed"))
        let retirement = try #require(
            body.range(of: "retiredGenerations.detachAndReclaimAll()"))
        let graphFree = try #require(body.range(of: "RTGraph.deallocate"))
        let cellFree = try #require(body.range(of: "yun_rt_cell_free"))
        let echoStop = try #require(body.range(of: "echoBridge.stop(until: deadline)"))
        let echoFailure = try #require(
            body.range(
                of: "guard echoResult.isComplete else",
                range: echoStop.upperBound..<body.endIndex))
        let echoFailureReturn = try #require(
            body.range(
                of: "return result",
                range: echoFailure.upperBound..<retirement.lowerBound))

        #expect(stopFailure.lowerBound < retirement.lowerBound)
        #expect(destroyFailure.lowerBound < retirement.lowerBound)
        #expect(echoStop.lowerBound < echoFailure.lowerBound)
        #expect(echoFailure.lowerBound < echoFailureReturn.lowerBound)
        #expect(echoFailureReturn.lowerBound < retirement.lowerBound)
        #expect(echoFailureReturn.lowerBound < graphFree.lowerBound)
        #expect(retirement.lowerBound < graphFree.lowerBound)
        #expect(retirement.lowerBound < cellFree.lowerBound)
        #expect(body[stopFailure.lowerBound..<retirement.lowerBound].contains("return result"))
        #expect(
            body[destroyFailure.lowerBound..<retirement.lowerBound]
                .contains("return result"))

        let quarantineStart = try #require(
            source.range(of: "private func quarantineFailedTeardown"))
        let quarantineEnd = try #require(
            source.range(
                of: "public var lastTeardownResult",
                range: quarantineStart.upperBound..<source.endIndex))
        let quarantineBody = source[quarantineStart.lowerBound..<quarantineEnd.lowerBound]
        let requiredOwners = [
            "retiredGenerations", "aggregate", "clockPublisher", "echoBridge", "isolationUnit",
            "effectChain", "outputLimiterBank", "recordingLimiter",
            "effectTransitionController", "transitionOldChain", "transitionOldUnit",
            "recorder", "stemRecorders", "lastConfiguration?.taps",
            "pendingTeardownTaps",
        ]
        let requiredRawContext = [
            "ioProcID", "graph", "graphCell", "sharedClock", "selftestBlock",
            "isolationBlock", "isolationFailureCounter", "effectTransitionBlock",
            "transitionOldBlock", "transcriptRings",
        ]
        let missing = (requiredOwners + requiredRawContext).filter {
            !quarantineBody.contains($0)
        }
        #expect(requiredOwners.count == 15)
        #expect(requiredRawContext.count == 10)
        #expect(missing.isEmpty)
    }

    @Test("clock queue fencing is bounded and precedes shared-clock release")
    func clockPublisherFencePrecedesClockRelease() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let publisher = try String(
            contentsOfFile: root + "Sources/YunAudioEngine/ClockAnchorPublisher.swift",
            encoding: .utf8)
        let stop = try #require(
            publisher.range(of: "public func stop(\n        until deadline:"))
        let publish = try #require(
            publisher.range(
                of: "private func publish(_ anchor:",
                range: stop.upperBound..<publisher.endIndex))
        let stopBody = publisher[stop.lowerBound..<publish.lowerBound]
        let start = try #require(
            publisher.range(of: "public func start(anchorSource:"))
        let publisherStartBody = publisher[start.lowerBound..<stop.lowerBound]
        let cancelHandler = try #require(
            publisherStartBody.range(of: "timer.setCancelHandler { drain.finish() }"))
        let resume = try #require(publisherStartBody.range(of: "timer.resume()"))
        let cancel = try #require(stopBody.range(of: "timer.cancel()"))
        let wait = try #require(stopBody.range(of: "guard fence.wait(until: deadline)"))
        let release = try #require(stopBody.range(of: "timer = nil"))

        #expect(!publisher.contains("queue.sync"))
        #expect(!stopBody.contains("queue.async"))
        #expect(cancelHandler.lowerBound < resume.lowerBound)
        #expect(cancel.lowerBound < wait.lowerBound)
        #expect(wait.lowerBound < release.lowerBound)

        let engine = try String(
            contentsOfFile: root + "Sources/YunAudioEngine/RoutingEngine.swift",
            encoding: .utf8)
        let startAttempt = try #require(engine.range(of: "private func startAttempt("))
        let engineStop = try #require(engine.range(of: "private func stopLocked("))
        let startBody = engine[startAttempt.lowerBound..<engineStop.lowerBound]
        let publisherStart = try #require(
            startBody.range(of: "publisher.start(anchorSource:"))
        let startFailure = try #require(
            startBody.range(of: "throw RoutingError.clockPublisherFailedToStart"))
        let install = try #require(startBody.range(of: "clockPublisher = publisher"))
        #expect(publisherStart.lowerBound < startFailure.lowerBound)
        #expect(startFailure.lowerBound < install.lowerBound)

        let engineStopEnd = try #require(
            engine.range(
                of: "private func recoverFromClockLockLoss()",
                range: engineStop.upperBound..<engine.endIndex))
        let engineStopBody = engine[engineStop.lowerBound..<engineStopEnd.lowerBound]
        let fences = engineStopBody.ranges(of: "stopClockPublisherLocked(until: deadline)")
        let sharedClockRelease = try #require(
            engineStopBody.range(of: "sharedClock?.deallocate()"))

        #expect(fences.count == 3)
        #expect(fences.allSatisfy { $0.lowerBound < sharedClockRelease.lowerBound })
        #expect(engineStopBody.ranges(of: "clockPublisherTimedOut").count == 3)
    }

    @Test("structural lint adopts unstarted preparation taps before every Stop census")
    func unstartedPreparationTapsAreAdopted() throws {
        // Exact-once destruction, retry preservation and disjoint live/dead
        // identities are executable in `ProcessTapRetryOwnershipTests`. This
        // source lint checks only that both production owners use that boundary
        // before each terminal Stop path.
        let root = PreferencesCompletenessTests.sourceRootForTests
        let engine = try String(
            contentsOfFile: root + "Sources/YunAudioEngine/RoutingEngine.swift",
            encoding: .utf8)
        let router = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)

        let adoptionStart = try #require(
            engine.range(of: "public func adoptTapsForTeardown"))
        let adoptionEnd = try #require(
            engine.range(
                of: "// MARK: Lifecycle",
                range: adoptionStart.upperBound..<engine.endIndex))
        let adoption = engine[adoptionStart.lowerBound..<adoptionEnd.lowerBound]
        #expect(adoption.contains("ProcessTapRetryOwnership(pending: pendingTeardownTaps)"))
        #expect(adoption.contains("ownership.adopting(taps).pending"))

        let stopStart = try #require(engine.range(of: "private func stopLocked("))
        let stopEnd = try #require(
            engine.range(
                of: "private func recoverFromClockLockLoss()",
                range: stopStart.upperBound..<engine.endIndex))
        let stop = engine[stopStart.lowerBound..<stopEnd.lowerBound]
        let pending = try #require(stop.range(of: "+ pendingTeardownTaps"))
        let census = try #require(
            stop.range(of: "ProcessTap.destroyAllAndWait(uniqueTaps, until: deadline)"))
        let release = try #require(stop.range(of: "pendingTeardownTaps.removeAll()"))
        #expect(pending.lowerBound < census.lowerBound)
        #expect(census.lowerBound < release.lowerBound)

        let preparation = try #require(
            router.range(of: "let preparation = Self.prepareCapture("))
        let handoffEnd = try #require(
            router.range(
                of: "/// Finishes a start made obsolete",
                range: preparation.upperBound..<router.endIndex))
        let handoff = router[preparation.lowerBound..<handoffEnd.lowerBound]
        #expect(
            handoff.ranges(of: "engine.adoptTapsForTeardown(preparation.taps)").count
                == 3)

        let cancelled = try #require(handoff.range(of: "guard !intent.isCancelled else"))
        let empty = try #require(handoff.range(of: "guard !preparation.routes.isEmpty else"))
        let cancellationBranch = handoff[cancelled.lowerBound..<empty.lowerBound]
        let cancelledAdopt = try #require(
            cancellationBranch.range(of: "engine.adoptTapsForTeardown"))
        let cancelledStop = try #require(
            cancellationBranch.range(of: "Self.stopEngineAndRecord(engine)"))
        #expect(cancelledAdopt.lowerBound < cancelledStop.lowerBound)

        let attempt = try #require(handoff.range(of: "engine.allowClockLockRetry()"))
        let emptyBranch = handoff[empty.lowerBound..<attempt.lowerBound]
        let emptyAdopt = try #require(
            emptyBranch.range(of: "engine.adoptTapsForTeardown"))
        let emptyStop = try #require(
            emptyBranch.range(of: "Self.stopEngineAndRecord(engine)"))
        #expect(emptyAdopt.lowerBound < emptyStop.lowerBound)
        #expect(emptyBranch.contains("teardown: teardown"))

        let failedAdopt = try #require(
            handoff.range(
                of: "engine.adoptTapsForTeardown(preparation.taps)",
                range: attempt.upperBound..<handoff.endIndex))
        let failedStop = try #require(
            handoff.range(
                of: "failedStartStop = Self.stopEngineAndRecord(engine)",
                range: failedAdopt.upperBound..<handoff.endIndex))
        #expect(failedAdopt.lowerBound < failedStop.lowerBound)
    }

    @Test("an IOProc stop refusal retains the running phase and retries in order")
    func ioProcStopFailureRetries() {
        var state = AudioIOProcTeardownState()
        state.didCreate()
        state.didStart()
        var calls: [String] = []

        let first = state.tearDown(
            stop: {
                calls.append("stop")
                return OSStatus(-70_001)
            },
            destroy: {
                calls.append("destroy")
                return noErr
            })
        #expect(first == .stopFailed(OSStatus(-70_001)))
        #expect(state.phase == .running)
        #expect(calls == ["stop"])

        let retry = state.tearDown(
            stop: {
                calls.append("stop")
                return noErr
            },
            destroy: {
                calls.append("destroy")
                return noErr
            })
        #expect(retry == .complete)
        #expect(state.phase == .absent)
        #expect(calls == ["stop", "stop", "destroy"])
    }

    @Test("an IOProc destroy refusal retries destroy without stopping twice")
    func ioProcDestroyFailureRetries() {
        var state = AudioIOProcTeardownState()
        state.didCreate()
        state.didStart()
        var stopCalls = 0
        var destroyCalls = 0

        let first = state.tearDown(
            stop: {
                stopCalls += 1
                return noErr
            },
            destroy: {
                destroyCalls += 1
                return OSStatus(-70_002)
            })
        #expect(first == .destroyFailed(OSStatus(-70_002)))
        #expect(state.phase == .stopped)

        let retry = state.tearDown(
            stop: {
                stopCalls += 1
                return noErr
            },
            destroy: {
                destroyCalls += 1
                return noErr
            })
        #expect(retry == .complete)
        #expect(stopCalls == 1)
        #expect(destroyCalls == 2)
        #expect(state.phase == .absent)
    }

    @Test("an absent IOProc teardown is idempotent")
    func absentIOProcIsIdempotent() {
        var state = AudioIOProcTeardownState()
        var calls = 0
        for _ in 0..<3 {
            #expect(
                state.tearDown(
                    stop: {
                        calls += 1
                        return noErr
                    },
                    destroy: {
                        calls += 1
                        return noErr
                    }) == .complete)
        }
        #expect(calls == 0)
        #expect(state.phase == .absent)
    }

    @Test("an expired IOProc deadline starts no operation")
    func expiredIOProcStartsNothing() {
        let now = UInt64(3_000_000_000)
        let deadline = HALTeardownDeadline(
            timeout: 0, nowUptimeNanoseconds: now)
        var state = AudioIOProcTeardownState()
        state.didCreate()
        state.didStart()
        var stopCalls = 0
        var destroyCalls = 0

        let result = state.tearDown(
            stop: {
                deadline.perform(nowUptimeNanoseconds: now) {
                    stopCalls += 1
                    return noErr
                }
            },
            destroy: {
                deadline.perform(nowUptimeNanoseconds: now) {
                    destroyCalls += 1
                    return noErr
                }
            })

        #expect(result == .timedOut(step: .stop))
        #expect(state.phase == .running)
        #expect(stopCalls == 0)
        #expect(destroyCalls == 0)
    }

    @Test("a slow IOProc stop prevents destroy from starting")
    func slowIOProcStopConsumesDeadline() {
        let start = UInt64(4_000_000_000)
        let deadline = HALTeardownDeadline(
            timeout: 1, nowUptimeNanoseconds: start)
        var now = start
        var state = AudioIOProcTeardownState()
        state.didCreate()
        state.didStart()
        var stopCalls = 0
        var destroyCalls = 0

        let result = state.tearDown(
            stop: {
                deadline.perform(nowUptimeNanoseconds: now) {
                    stopCalls += 1
                    now += 1_250_000_000
                    return noErr
                }
            },
            destroy: {
                deadline.perform(nowUptimeNanoseconds: now) {
                    destroyCalls += 1
                    return noErr
                }
            })

        #expect(result == .timedOut(step: .destroy))
        #expect(state.phase == .stopped)
        #expect(stopCalls == 1)
        #expect(destroyCalls == 0)

        let retryStart = UInt64(6_000_000_000)
        let retryDeadline = HALTeardownDeadline(
            timeout: 1, nowUptimeNanoseconds: retryStart)
        let retry = state.tearDown(
            stop: {
                retryDeadline.perform(nowUptimeNanoseconds: retryStart) {
                    stopCalls += 1
                    return noErr
                }
            },
            destroy: {
                retryDeadline.perform(nowUptimeNanoseconds: retryStart) {
                    destroyCalls += 1
                    return noErr
                }
            })
        #expect(retry == .complete)
        #expect(state.phase == .absent)
        #expect(stopCalls == 1)
        #expect(destroyCalls == 1)
    }

    @Test("voice processing closes stop, uninitialise, dispose exactly once")
    func audioUnitStrictOrderAndIdempotency() {
        var state = AudioUnitTeardownState()
        state.didInitialise()
        state.didStart()
        var calls: [AudioUnitTeardownStep] = []

        let result = state.tearDown(
            stop: {
                calls.append(.stop)
                return noErr
            },
            uninitialise: {
                calls.append(.uninitialise)
                return noErr
            },
            dispose: {
                calls.append(.dispose)
                return noErr
            })
        #expect(result == .complete)
        #expect(calls == [.stop, .uninitialise, .dispose])
        #expect(state.phase == .disposed)

        let repeatResult = state.tearDown(
            stop: {
                calls.append(.stop)
                return noErr
            },
            uninitialise: {
                calls.append(.uninitialise)
                return noErr
            },
            dispose: {
                calls.append(.dispose)
                return noErr
            })
        #expect(repeatResult == .complete)
        #expect(calls == [.stop, .uninitialise, .dispose])
    }

    @Test("voice processing resumes at each failed boundary")
    func audioUnitFailuresRetryTheirBoundary() {
        var state = AudioUnitTeardownState()
        state.didInitialise()
        state.didStart()
        var stopAttempts = 0
        var uninitialiseAttempts = 0
        var disposeAttempts = 0

        var result = state.tearDown(
            stop: {
                stopAttempts += 1
                return OSStatus(-71_001)
            },
            uninitialise: {
                uninitialiseAttempts += 1
                return noErr
            },
            dispose: {
                disposeAttempts += 1
                return noErr
            })
        #expect(result == .audioUnit(step: .stop, status: OSStatus(-71_001)))
        #expect(state.phase == .running)

        result = state.tearDown(
            stop: {
                stopAttempts += 1
                return noErr
            },
            uninitialise: {
                uninitialiseAttempts += 1
                return OSStatus(-71_002)
            },
            dispose: {
                disposeAttempts += 1
                return noErr
            })
        #expect(
            result == .audioUnit(step: .uninitialise, status: OSStatus(-71_002)))
        #expect(state.phase == .ready)

        result = state.tearDown(
            stop: {
                stopAttempts += 1
                return noErr
            },
            uninitialise: {
                uninitialiseAttempts += 1
                return noErr
            },
            dispose: {
                disposeAttempts += 1
                return OSStatus(-71_003)
            })
        #expect(result == .audioUnit(step: .dispose, status: OSStatus(-71_003)))
        #expect(state.phase == .uninitialised)

        result = state.tearDown(
            stop: {
                stopAttempts += 1
                return noErr
            },
            uninitialise: {
                uninitialiseAttempts += 1
                return noErr
            },
            dispose: {
                disposeAttempts += 1
                return noErr
            })
        #expect(result == .complete)
        #expect(stopAttempts == 2)
        #expect(uninitialiseAttempts == 2)
        #expect(disposeAttempts == 2)
        #expect(state.phase == .disposed)
    }

    @Test("a never-initialised unit skips stop and uninitialise")
    func uninitialisedSetupFailureDisposesDirectly() {
        var state = AudioUnitTeardownState()
        var calls: [AudioUnitTeardownStep] = []
        let result = state.tearDown(
            stop: {
                calls.append(.stop)
                return noErr
            },
            uninitialise: {
                calls.append(.uninitialise)
                return noErr
            },
            dispose: {
                calls.append(.dispose)
                return noErr
            })
        #expect(result == .complete)
        #expect(calls == [.dispose])
    }

    @Test("a slow Audio Unit stop prevents uninitialise and dispose")
    func slowAudioUnitStopConsumesDeadline() {
        let start = UInt64(5_000_000_000)
        let deadline = HALTeardownDeadline(
            timeout: 1, nowUptimeNanoseconds: start)
        var now = start
        var state = AudioUnitTeardownState()
        state.didInitialise()
        state.didStart()
        var calls: [AudioUnitTeardownStep] = []

        let result = state.tearDown(
            stop: {
                deadline.perform(nowUptimeNanoseconds: now) {
                    calls.append(.stop)
                    now += 1_250_000_000
                    return noErr
                }
            },
            uninitialise: {
                deadline.perform(nowUptimeNanoseconds: now) {
                    calls.append(.uninitialise)
                    return noErr
                }
            },
            dispose: {
                deadline.perform(nowUptimeNanoseconds: now) {
                    calls.append(.dispose)
                    return noErr
                }
            })

        #expect(result == .audioUnitTimedOut(step: .uninitialise))
        #expect(state.phase == .ready)
        #expect(calls == [.stop])

        let retryStart = UInt64(7_000_000_000)
        let retryDeadline = HALTeardownDeadline(
            timeout: 1, nowUptimeNanoseconds: retryStart)
        let retry = state.tearDown(
            stop: {
                retryDeadline.perform(nowUptimeNanoseconds: retryStart) {
                    calls.append(.stop)
                    return noErr
                }
            },
            uninitialise: {
                retryDeadline.perform(nowUptimeNanoseconds: retryStart) {
                    calls.append(.uninitialise)
                    return noErr
                }
            },
            dispose: {
                retryDeadline.perform(nowUptimeNanoseconds: retryStart) {
                    calls.append(.dispose)
                    return noErr
                }
            })
        #expect(retry == .complete)
        #expect(state.phase == .disposed)
        #expect(calls == [.stop, .uninitialise, .dispose])
    }

    @Test("an expired never-initialised Audio Unit is not disposed")
    func expiredAudioUnitStartsNothing() {
        let now = UInt64(6_000_000_000)
        let deadline = HALTeardownDeadline(
            timeout: 0, nowUptimeNanoseconds: now)
        var state = AudioUnitTeardownState()
        var disposeCalls = 0

        let result = state.tearDown(
            stop: { noErr },
            uninitialise: { noErr },
            dispose: {
                deadline.perform(nowUptimeNanoseconds: now) {
                    disposeCalls += 1
                    return noErr
                }
            })

        #expect(result == .audioUnitTimedOut(step: .dispose))
        #expect(state.phase == .instantiated)
        #expect(disposeCalls == 0)
    }
}

@Suite("HAL destruction ownership")
struct HALDestructionOwnershipTests {
    @Test("aggregate deinit confirms absence before releasing tap dependencies")
    func aggregateFallbackPreservesTapOrder() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioHAL/AggregateDevice.swift",
            encoding: .utf8)
        let start = try #require(source.range(of: "deinit {"))
        let end = try #require(
            source.range(
                of: "public func destroy()",
                range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]
        let deadline = try #require(body.range(of: "HALTeardownDeadline(timeout: 2)"))
        let dependencyClosure = try #require(body.range(of: "destroyDependencies: {"))
        let tapBatch = try #require(
            body.range(
                of: "ProcessTap.destroyAllAndWait(taps, until: deadline)",
                range: dependencyClosure.upperBound..<body.endIndex))
        let cleanupStart = try #require(body.range(of: "static func cleanUpRawAggregate("))
        let cleanup = body[cleanupStart.lowerBound..<body.endIndex]
        let census = try #require(cleanup.range(of: "aggregateIsAbsent"))
        let absenceFence = try #require(
            cleanup.range(
                of: "guard aggregateIsAbsent", range: census.upperBound..<cleanup.endIndex))
        let releaseDependencies = try #require(
            cleanup.range(
                of: "return destroyDependencies()",
                range: absenceFence.upperBound..<cleanup.endIndex))

        #expect(deadline.lowerBound < dependencyClosure.lowerBound)
        #expect(dependencyClosure.lowerBound < tapBatch.lowerBound)
        #expect(census.lowerBound < absenceFence.lowerBound)
        #expect(absenceFence.lowerBound < releaseDependencies.lowerBound)
        #expect(body.contains("BoundedHALDeinitCleanup.quarantine"))
        #expect(!body.contains("for tap in taps"))
        #expect(!body.contains("destroyAndWait(timeout:"))
    }

    @Test("quarantine retains one capsule until its explicit release")
    func quarantineOwnership() {
        final class Probe {}

        let quarantine = ProcessLifetimeAudioQuarantine()
        var owner: Probe? = Probe()
        weak let weakOwner = owner
        let token = quarantine.retain(owner!, reason: "injected callback fence")
        owner = nil

        #expect(weakOwner != nil)
        #expect(quarantine.count == 1)
        #expect(quarantine.reasons == ["injected callback fence"])

        quarantine.release(token)
        #expect(weakOwner == nil)
        #expect(quarantine.count == 0)
    }

    @Test("a refused request retries, an accepted request does not")
    func requestRetryAndIdempotency() {
        var state = HALDestructionRequestState()
        var calls = 0
        let refused = state.request {
            calls += 1
            return OSStatus(-72_001)
        }
        #expect(refused == OSStatus(-72_001))
        #expect(!state.wasAccepted)

        let accepted = state.request {
            calls += 1
            return noErr
        }
        #expect(accepted == noErr)
        #expect(state.wasAccepted)

        let repeatStatus = state.request {
            calls += 1
            return OSStatus(-72_002)
        }
        #expect(repeatStatus == noErr)
        #expect(calls == 2)
    }

    @Test("a timeout does not resend an accepted destructive request")
    func acceptedTimeoutPollsAgainWithoutReissuing() {
        var state = HALDestructionRequestState()
        var requests = 0
        #expect(
            state.request {
                requests += 1
                return noErr
            } == noErr)
        #expect(
            !HALRemovalWaiter.wait(
                maximumAttempts: 2, betweenAttempts: {}, isPresent: { true }))
        #expect(
            state.request {
                requests += 1
                return noErr
            } == noErr)
        #expect(requests == 1)
    }

    @Test("aggregate absence is the UID translation returning unknown")
    func aggregateCensusUsesUID() throws {
        var translatedUID: String?
        let present = try AggregateDevice.censusContains(uid: "route") { uid in
            translatedUID = uid
            return AudioObjectID(42)
        }
        #expect(present)
        #expect(translatedUID == "route")

        let absent = try AggregateDevice.censusContains(uid: "route") { _ in nil }
        #expect(!absent)
    }

    @Test("tap absence requires both its object and UID to disappear")
    func processTapCensusUsesObjectAndUID() throws {
        let byObject = try ProcessTap.censusContains(
            id: 7, uid: "owned", tapIDs: { [7, 8] },
            tapUID: { $0 == 7 ? "owned" : "unrelated" })
        #expect(byObject)

        let byUID = try ProcessTap.censusContains(
            id: 7, uid: "owned", tapIDs: { [8] },
            tapUID: { _ in "owned" })
        #expect(byUID)

        let absent = try ProcessTap.censusContains(
            id: 7, uid: "owned", tapIDs: { [8] },
            tapUID: { _ in "unrelated" })
        #expect(!absent)

        let recycledID = try ProcessTap.censusContains(
            id: 7, uid: "owned", tapIDs: { [7] },
            tapUID: { _ in "new-owner" })
        #expect(!recycledID)
    }

    @Test("a failed tap census cannot be mistaken for absence")
    func processTapCensusPropagatesFailure() {
        enum CensusError: Error { case unavailable }
        #expect(throws: CensusError.self) {
            _ = try ProcessTap.censusContains(
                id: 7, uid: "owned", tapIDs: { [8] },
                tapUID: { _ in throw CensusError.unavailable })
        }
    }

    @Test("one absolute deadline shrinks as teardown phases consume it")
    func sharedDeadlineHasOneBudget() {
        let start = UInt64(10_000_000_000)
        let deadline = HALTeardownDeadline(
            timeout: 2, nowUptimeNanoseconds: start)

        #expect(deadline.remainingTimeInterval(nowUptimeNanoseconds: start) == 2)
        #expect(
            deadline.remainingTimeInterval(
                nowUptimeNanoseconds: start + 1_250_000_000) == 0.75)
        #expect(
            deadline.remainingTimeInterval(
                nowUptimeNanoseconds: start + 2_000_000_000) == 0)
        #expect(
            deadline.remainingTimeInterval(
                nowUptimeNanoseconds: start + 9_000_000_000) == 0)
    }

    @Test("an expired deadline admits zero synchronous operations")
    func expiredDeadlineAdmitsNothing() {
        let now = UInt64(20_000_000_000)
        let deadline = HALTeardownDeadline(
            timeout: 0, nowUptimeNanoseconds: now)
        var calls = 0

        let result: OSStatus? = deadline.perform(nowUptimeNanoseconds: now) {
            calls += 1
            return noErr
        }

        #expect(result == nil)
        #expect(calls == 0)
    }

    @Test("an expired removal wait starts zero census reads")
    func expiredRemovalWaitStartsNoCensus() {
        var censusCalls = 0
        var sleeps = 0
        let absent = HALRemovalWaiter.wait(
            pollInterval: 0.01,
            remaining: { 0 },
            betweenAttempts: { _ in sleeps += 1 },
            isPresent: {
                censusCalls += 1
                return false
            })

        #expect(!absent)
        #expect(censusCalls == 0)
        #expect(sleeps == 0)
    }

    @Test("a slow HAL census consumes the deadline without another retry")
    func slowCensusStopsAtAbsoluteDeadline() {
        var remaining = 2.0
        var censusCalls = 0
        var sleeps = 0
        let absent = HALRemovalWaiter.wait(
            pollInterval: 0.01,
            remaining: { remaining },
            betweenAttempts: { interval in
                sleeps += 1
                remaining -= interval
            },
            isPresent: {
                censusCalls += 1
                // A synchronous property read cannot be cancelled. Its cost
                // still consumes the transaction and forbids a second read.
                remaining -= 2.1
                return true
            })

        #expect(!absent)
        #expect(censusCalls == 1)
        #expect(sleeps == 0)
    }

    @Test("thirty-two taps share one bounded sequence of HAL list reads")
    func batchTapCensusDoesNotMultiplyPollingByTapCount() throws {
        let identities = (0..<32).map {
            ProcessTap.CensusIdentity(id: AudioObjectID($0 + 1), uid: "tap-\($0)")
        }
        var listReads = 0
        var sleeps = 0
        let absent = HALRemovalWaiter.wait(
            maximumAttempts: 5,
            betweenAttempts: { sleeps += 1 },
            isPresent: {
                listReads += 1
                let present = try! ProcessTap.censusPresentUIDs(
                    identities: identities,
                    tapIDs: { identities.map(\.id) },
                    tapUID: { id in
                        identities.first { $0.id == id }!.uid
                    })
                return !present.isEmpty
            })

        #expect(!absent)
        #expect(listReads == 6)
        #expect(sleeps == 5)

        var expiredListReads = 0
        var expiredUIDReads = 0
        do {
            _ = try ProcessTap.censusPresentUIDs(
                identities: identities,
                tapIDs: {
                    expiredListReads += 1
                    return identities.map(\.id)
                },
                tapUID: { _ in
                    expiredUIDReads += 1
                    return "unreachable"
                },
                shouldContinue: { false })
            Issue.record("an expired batch continued reading tap UIDs")
        } catch {}
        #expect(expiredListReads == 0)
        #expect(expiredUIDReads == 0)
    }

    @Test("RoutingEngine passes one deadline through every blocking phase")
    func routingTeardownUsesOneDeadline() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioEngine/RoutingEngine.swift",
            encoding: .utf8)
        let start = try #require(source.range(of: "public func stop(timeout:"))
        let end = try #require(
            source.range(
                of: "private func recoverFromClockLockLoss()",
                range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]

        #expect(body.ranges(of: "HALTeardownDeadline(timeout: timeout)").count == 1)
        #expect(body.contains("echoBridge.stop(until: deadline)"))
        #expect(body.contains("aggregate.destroyAndWait(until: deadline)"))
        #expect(body.contains("ProcessTap.destroyAllAndWait(uniqueTaps, until: deadline)"))
        #expect(body.contains("originalSampleRates, until: deadline"))
        #expect(body.contains("clockPublisher.stop(until: deadline)"))
        #expect(!body.contains("tap.destroyAndWait()"))
        #expect(body.ranges(of: "deadline.perform").count == 2)
    }

    @Test("a refused IOProc stop keeps clock publication and recovery alive")
    func clockPublisherSurvivesRunningStopFailure() throws {
        let source = try String(
            contentsOfFile: PreferencesCompletenessTests.sourceRootForTests
                + "Sources/YunAudioEngine/RoutingEngine.swift",
            encoding: .utf8)
        let start = try #require(source.range(of: "private func stopLocked("))
        let end = try #require(
            source.range(
                of: "private func stopClockPublisherLocked(",
                range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]
        let stopFailure = try #require(body.range(of: "case .stopFailed"))
        let destroyFailure = try #require(body.range(of: "case .destroyFailed"))
        let invalidOwner = try #require(body.range(of: "} else if ioProcID != nil"))

        let runningFailure = body[stopFailure.lowerBound..<destroyFailure.lowerBound]
        #expect(runningFailure.contains("return result"))
        #expect(!runningFailure.contains("stopClockPublisherLocked(until: deadline)"))

        let stoppedFailure = body[destroyFailure.lowerBound..<invalidOwner.lowerBound]
        #expect(stoppedFailure.contains("stopClockPublisherLocked(until: deadline)"))
        #expect(stoppedFailure.contains("return result"))

        let successfulFence = try #require(
            body.range(
                of: "stopClockPublisherLocked(until: deadline)",
                range: invalidOwner.upperBound..<body.endIndex))
        #expect(invalidOwner.lowerBound < successfulFence.lowerBound)
        #expect(body.ranges(of: "stopClockPublisherLocked(until: deadline)").count == 3)
    }
}
