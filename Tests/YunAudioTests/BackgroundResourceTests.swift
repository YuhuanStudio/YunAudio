import Foundation
import Testing
import YunAudioRT

@testable import YunAudioApp
@testable import YunAudioEngine
@testable import YunAudioHAL

@Suite("Background resource use")
struct BackgroundResourceTests {
    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.withLock { value += 1 }
        }

        var current: Int {
            lock.withLock { value }
        }
    }

    private final class Values<Element: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Element] = []

        func append(_ value: Element) {
            lock.withLock { values.append(value) }
        }

        var snapshot: [Element] {
            lock.withLock { values }
        }
    }

    @Test("a hundred HAL notifications become one device refresh")
    func deviceChangeBurstIsCoalesced() throws {
        let queue = DispatchQueue(label: "yunaudio.test.device-change")
        let delivered = DispatchSemaphore(value: 0)
        let count = Count()
        let coalescer = DeviceChangeCoalescer(
            queue: queue, delay: .milliseconds(50)
        ) {
            count.increment()
            delivered.signal()
        }

        for _ in 0..<100 { coalescer.signal() }
        // Put every signal into the fixed window before its deadline. Without
        // the coalescer this barrier would leave 100 expensive refreshes queued.
        queue.sync {}
        #expect(delivered.wait(timeout: .now() + 1) == .success)
        queue.sync {}
        #expect(count.current == 1)

        // Coalescing is per burst, not a once-only gate.
        coalescer.signal()
        queue.sync {}
        #expect(delivered.wait(timeout: .now() + 1) == .success)
        queue.sync {}
        #expect(count.current == 2)
    }

    @MainActor
    @Test("a hundred control changes become one preferences write")
    func preferenceWritesAreCoalesced() async throws {
        var written: [Int] = []
        let writer = CoalescedPreferenceWriter<Int>(delay: .milliseconds(50)) {
            written.append($0)
        }

        for value in 0..<100 { writer.submit(value) }
        #expect(writer.pendingValue == 99)
        #expect(written.isEmpty)

        try await Task.sleep(for: .milliseconds(100))
        #expect(written == [99])
        #expect(writer.pendingValue == nil)

        // Quit does not wait for the window, so its flush has to write exactly
        // once and cancel the scheduled duplicate.
        writer.submit(100)
        writer.flush()
        try await Task.sleep(for: .milliseconds(100))
        #expect(written == [99, 100])
    }

    @MainActor
    @Test("a hundred control changes build one preferences snapshot")
    func preferenceSnapshotsAreCoalesced() async throws {
        let captured = Set(["com.example.music"])
        let excluded = Set(["com.example.private"])
        let effects: Set<EffectKind> = [.gate, .compressor]
        let roles = ["com.example.music": LevelCalibration.Role.background]
        let bindings = [
            MIDITarget.fader(.master):
                MIDIAddress(channel: 0, kind: .controlChange(7))
        ]
        var snapshotsBuilt = 0
        var written: [Int] = []
        let writer = CoalescedPreferenceWriter<PendingPreferencesSnapshot>(
            delay: .milliseconds(50)
        ) {
            snapshotsBuilt += 1
            written.append($0.materialised().monoChannel)
        }

        for value in 0..<100 {
            var preferences = Preferences.default
            preferences.monoChannel = value
            writer.submit(
                PendingPreferencesSnapshot(
                    preferences,
                    capturedAppBundleIDs: captured,
                    excludedAppBundleIDs: excluded,
                    enabledEffects: effects,
                    sourceRoles: roles,
                    midiBindings: bindings))
        }

        #expect(snapshotsBuilt == 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(snapshotsBuilt == 1)
        #expect(written == [99])
    }

    @MainActor
    @Test("a hundred expensive publications apply the first and latest values only")
    func latestValuePublication() async throws {
        let queue = DispatchQueue(label: "yunaudio.test.latest-value")
        let applied = Values<Int>()
        var published: [Int] = []
        let applier = LatestValueApplier<Int, Int>(
            queue: queue,
            apply: { value in
                applied.append(value)
                return value
            },
            publish: { published.append($0) })

        // One MainActor turn means the first completion cannot publish between
        // submissions. That makes the coalescing assertion independent of how
        // busy the test machine is or how its scheduler interleaves queues.
        for value in 0..<100 { applier.submit(value) }

        for _ in 0..<100 where published != [99] {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(applied.snapshot == [0, 99])
        #expect(published == [99])
    }

    @Test("a correction snapshot builds only its named buses")
    func correctionSnapshot() {
        let profile = ParametricEQ(
            name: "Headphones",
            filters: [.init(kind: .peaking, hertz: 1000, decibels: -2, q: 1)])
        let snapshot = RouterModel.CorrectionSnapshot(
            busIDs: ["send", "monitor", "gone"],
            graphic: [
                "send": [0, 0, 0, 0, 0, 4, 0, 0, 0, 0],
                "monitor": [Float](repeating: 0, count: 10),
            ],
            profileNames: ["monitor": "Headphones", "gone": "Missing"],
            profiles: [profile])

        let curves = RouterModel.correctionCurves(from: snapshot)
        #expect(Set(curves.keys) == ["send", "monitor"])
        #expect(
            abs((curves["send"]?.response(atHertz: 1000, sampleRate: 48000) ?? 0) - 4)
                < 0.4)
        #expect(
            abs((curves["monitor"]?.response(atHertz: 1000, sampleRate: 48000) ?? 0) + 2)
                < 0.2)
    }

    /// The UI is responsive only if the expensive half stays behind the
    /// coalescer. The engine check closes the other end: moving it to a queue
    /// but continuing to ask HAL for the graph's fixed format on every value
    /// would still waste the shared audio server.
    @Test("EQ gestures neither install on MainActor nor re-read their graph format")
    func correctionGestureBoundary() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let model = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let setterStart = try #require(
            model.range(
                of: "func setGraphicBand(_ decibels: Float, at index: Int, forBus id: String)"
            ))
        let setterEnd = try #require(
            model.range(
                of: "func headphoneProfileName(forBus",
                range: setterStart.upperBound..<model.endIndex))
        let setters = model[setterStart.lowerBound..<setterEnd.lowerBound]
        #expect(setters.ranges(of: "scheduleCorrections()").count == 2)
        #expect(setters.ranges(of: "applyCorrections()").count == 0)
        #expect(setters.ranges(of: "engine.setCorrections").count == 0)

        let engine = try String(
            contentsOfFile: root + "Sources/YunAudioEngine/RoutingEngine.swift",
            encoding: .utf8)
        let correctionStart = try #require(
            engine.range(of: "public func setCorrections("))
        let correctionEnd = try #require(
            engine.range(
                of: "public func setAnalysisEnabled",
                range: correctionStart.upperBound..<engine.endIndex))
        let correction = engine[correctionStart.lowerBound..<correctionEnd.lowerBound]
        #expect(correction.ranges(of: "currentSampleRate").count == 0)
        #expect(correction.ranges(of: "graphSampleRate").count == 1)

        let effectsStart = try #require(engine.range(of: "public func updateEffects("))
        let effectsEnd = try #require(
            engine.range(
                of: "// MARK: Live control",
                range: effectsStart.upperBound..<engine.endIndex))
        let effects = engine[effectsStart.lowerBound..<effectsEnd.lowerBound]
        #expect(effects.ranges(of: "currentSampleRate").count == 0)
        #expect(effects.ranges(of: "currentBufferFrameSize").count == 0)
    }

    /// A second toggle used to enter `restartIfRunning` while the first live
    /// chain swap owned `isBusy`; because it was not a start, that function
    /// recorded nothing and the new state never reached audio. This is a
    /// placement bug, so assert the ordering around the asynchronous boundary.
    @Test("effect changes arriving during a chain build are coalesced and replayed")
    func effectSwapIsLatestWins() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let start = try #require(source.range(of: "private func swapChainIfPossible()"))
        let end = try #require(
            source.range(
                of: "private var activeEffectStageCache",
                range: start.upperBound..<source.endIndex))
        let swap = source[start.lowerBound..<end.lowerBound]

        let busy = try #require(swap.range(of: "guard !isBusy else { return false }"))
        let pending = try #require(swap.range(of: "if effectSwapIsInFlight"))
        #expect(pending.lowerBound < busy.lowerBound)
        #expect(swap.ranges(of: "effectSwapIsPending = true").count == 1)
        #expect(swap.ranges(of: "effectSwapIsPending = false").count == 3)
        #expect(swap.ranges(of: "swapChainIfPossible()").count == 2)

        let replay = try #require(swap.range(of: "if self.effectSwapIsPending"))
        let staleResult = try #require(
            swap.range(
                of: "guard swapped else",
                range: replay.upperBound..<swap.endIndex))
        #expect(replay.lowerBound < staleResult.lowerBound)
    }

    @Test("a deferred snapshot keeps the state from the user event")
    func preferenceSnapshotHasValueSemantics() {
        var preferences = Preferences.default
        preferences.inputDecibels = -3
        var captured = Set(["event"])
        var excluded = Set(["private"])
        var effects: Set<EffectKind> = [.gate]
        var roles = ["event": LevelCalibration.Role.voice]
        var bindings = [
            MIDITarget.fader(.master):
                MIDIAddress(channel: 0, kind: .controlChange(7))
        ]
        let snapshot = PendingPreferencesSnapshot(
            preferences,
            capturedAppBundleIDs: captured,
            excludedAppBundleIDs: excluded,
            enabledEffects: effects,
            sourceRoles: roles,
            midiBindings: bindings)

        // These stand in for a later automatic adjustment, restore or
        // verification mutation whose own `persist()` call is suppressed.
        preferences.inputDecibels = -30
        captured.insert("automatic")
        excluded.insert("automatic")
        effects.insert(.compressor)
        roles["event"] = .background
        bindings[.fader(.master)] = MIDIAddress(channel: 0, kind: .controlChange(8))

        let materialised = snapshot.materialised()
        #expect(materialised.inputDecibels == -3)
        #expect(Set(materialised.capturedAppBundleIDs) == ["event"])
        #expect(Set(materialised.excludedAppBundleIDs ?? []) == ["private"])
        #expect(Set(materialised.enabledEffects) == [EffectKind.gate.rawValue])
        #expect(materialised.sourceRoles == ["event": LevelCalibration.Role.voice.rawValue])
        #expect(materialised.midiBindings == ["fader:master": "0.cc.7"])
    }

    /// The regression was structural: `engine.start` was already queued, while
    /// the 27–118 ms application enumeration and every ProcessTap constructor
    /// still ran before the dispatch. Measuring a fake engine would pass while
    /// that exact placement was wrong, so assert the boundary itself and count
    /// the synchronous resources on each side of it.
    @Test("capture preflight belongs wholly to the engine queue")
    func capturePreflightIsNotOnTheMainActor() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let start = try #require(source.range(of: "func start(selftest: Bool)"))
        let worker = try #require(
            source.range(
                of: "private func beginStartOnEngineQueue",
                range: start.upperBound..<source.endIndex))
        let mainActorBody = source[start.upperBound..<worker.lowerBound]
        #expect(mainActorBody.ranges(of: "AudioApplications.grouped").count == 0)
        #expect(mainActorBody.ranges(of: "ProcessTap(").count == 0)
        #expect(mainActorBody.ranges(of: "beginStartOnEngineQueue(").count == 1)

        let finish = try #require(
            source.range(
                of: "private func finishCancelledStart",
                range: worker.upperBound..<source.endIndex))
        let workerBody = source[worker.lowerBound..<finish.lowerBound]
        #expect(workerBody.ranges(of: "engineQueue.async").count == 1)
        #expect(workerBody.ranges(of: "Self.prepareCapture(").count == 1)
        #expect(workerBody.ranges(of: "try engine.start(").count == 1)
    }

    @Test("one workspace enumeration supplies both application maps")
    func workspaceIsReadOncePerGrouping() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioHAL/AudioApplication.swift",
            encoding: .utf8)
        let snapshot = try #require(source.range(of: "public static func workspaceSnapshot()"))
        let end = try #require(
            source.range(
                of: "private static func baseIdentifier",
                range: snapshot.upperBound..<source.endIndex))
        let body = source[snapshot.lowerBound..<end.lowerBound]
        #expect(body.ranges(of: "NSWorkspace.shared.runningApplications").count == 1)
        #expect(body.ranges(of: "foreground[bundle] = info").count == 1)
        #expect(body.ranges(of: "named[bundle] = info").count == 1)
    }

    @Test("an interface refresh leaves HAL enumeration on the engine queue")
    func applicationRefreshDoesNotBlockMainActor() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let refresh = try #require(source.range(of: "func refreshApps()"))
        let queue = try #require(
            source.range(
                of: "engineQueue.async",
                range: refresh.upperBound..<source.endIndex))
        let verification = try #require(
            source.range(
                of: "func refreshAppsForVerification()",
                range: queue.upperBound..<source.endIndex))
        let mainActor = source[refresh.lowerBound..<queue.lowerBound]
        let worker = source[queue.lowerBound..<verification.lowerBound]

        #expect(mainActor.ranges(of: "AudioApplications.workspaceSnapshot()").count == 1)
        #expect(mainActor.ranges(of: "AudioApplications.grouped").count == 0)
        #expect(worker.ranges(of: "AudioApplications.grouped").count == 1)
        #expect(source.ranges(of: "guard !appRefreshInFlight else { return }").count == 1)
        #expect(source.ranges(of: "appRefreshPending = true").count == 2)
    }

    @MainActor
    @Test("the AppKit half left on MainActor stays below one frame")
    func workspaceSnapshotFitsAFrame() {
        let iterations = 20
        let started = DispatchTime.now().uptimeNanoseconds
        var entries = 0
        for _ in 0..<iterations {
            entries &+= AudioApplications.workspaceSnapshot().named.count
        }
        let average = (DispatchTime.now().uptimeNanoseconds - started) / UInt64(iterations)
        print("workspace snapshot: \(average) ns average, \(entries / iterations) apps")
        #expect(entries >= iterations)
        #expect(average < 16_000_000)
    }

    @Test("echo reference never falls back through an application exclusion")
    func excludedEchoReferencesStayExcluded() {
        let playing = AudioApplication(
            bundleID: "com.example.playing",
            name: "Playing",
            bundleURL: nil,
            isPlaying: true,
            isRecording: false,
            processIDs: [11, 12],
            isBackground: false)
        let quiet = AudioApplication(
            bundleID: "com.example.quiet",
            name: "Quiet",
            bundleURL: nil,
            isPlaying: false,
            isRecording: false,
            processIDs: [13],
            isBackground: false)

        #expect(
            RouterModel.echoReferenceProcessIDs(
                in: [playing, quiet],
                excluding: ["com.example.playing"]
            ).isEmpty)
        #expect(
            RouterModel.echoReferenceProcessIDs(in: [playing, quiet], excluding: [])
                == [11, 12])
    }

    @MainActor
    @Test("tuner jitter publishes at the four-hertz score cadence")
    func singerPitchPublicationIsBounded() {
        var displayed: Float = 220
        var publications = 0
        for poll in 0..<80 {
            let measured = Float(220 + sin(Double(poll) * 0.7) * 2)
            let previous = RouterModel.Singer(
                uid: "mic",
                name: "Singer",
                hertz: displayed,
                score: .none)
            let next = RouterModel.singerDisplayHertz(
                measured: measured,
                previous: previous,
                rescore: poll.isMultiple(of: 5))
            if next != displayed {
                publications += 1
                displayed = next
            }
        }
        // Four seconds at a twenty-hertz poll: at most sixteen score rounds,
        // rather than eighty raw autocorrelation readings.
        #expect(publications <= 16)

        let previous = RouterModel.Singer(
            uid: "mic",
            name: "Singer",
            hertz: 220,
            score: .none)
        #expect(
            RouterModel.singerDisplayHertz(
                measured: 235,
                previous: previous,
                rescore: false) == 235)
    }

    @Test("singing motion is isolated from the whole window")
    func singingMotionHasItsOwnObservationBoundary() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let window = try String(
            contentsOfFile: root + "Sources/YunAudioApp/MainWindow.swift",
            encoding: .utf8)
        let singing = try String(
            contentsOfFile: root + "Sources/YunAudioApp/SingingPanel.swift",
            encoding: .utf8)
        #expect(window.ranges(of: "SingingPanel(model: model)").count == 1)
        #expect(window.ranges(of: "model.lyricProgress").count == 0)
        #expect(window.ranges(of: "model.singers").count == 0)
        #expect(singing.ranges(of: "BodyCount.tick(\"SingingPanel\")").count == 1)
        #expect(singing.ranges(of: "model.lyricProgress").count >= 2)
        #expect(singing.ranges(of: "model.singers").count == 1)
    }

    @Test("the remaining live readings have child observation boundaries")
    func liveReadingsStayOutOfParentViews() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let panelSource = try String(
            contentsOfFile: root + "Sources/YunAudioApp/PanelView.swift",
            encoding: .utf8)
        let panelStart = try #require(panelSource.range(of: "struct PanelView: View"))
        let liveStart = try #require(
            panelSource.range(
                of: "private struct PanelLiveCard",
                range: panelStart.upperBound..<panelSource.endIndex))
        let panel = panelSource[panelStart.lowerBound..<liveStart.lowerBound]
        let live = panelSource[liveStart.lowerBound..<panelSource.endIndex]
        #expect(panel.ranges(of: "PanelLiveCard(model: model)").count == 1)
        #expect(panel.ranges(of: "model.peakLevel").count == 0)
        #expect(live.ranges(of: "BodyCount.tick(\"PanelLiveCard\")").count == 1)
        #expect(live.ranges(of: "model.peakLevel").count == 2)

        let windowSource = try String(
            contentsOfFile: root + "Sources/YunAudioApp/MainWindow.swift",
            encoding: .utf8)
        let windowStart = try #require(windowSource.range(of: "struct MainWindow: View"))
        let childStart = try #require(
            windowSource.range(
                of: "private struct GainReductionRow",
                range: windowStart.upperBound..<windowSource.endIndex))
        let window = windowSource[windowStart.lowerBound..<childStart.lowerBound]
        #expect(window.ranges(of: "ClockLockRows(model: model)").count == 1)
        #expect(window.ranges(of: "model.measuredRateRatio").count == 0)
        #expect(
            windowSource.ranges(of: "BodyCount.tick(\"ClockLockRows\")").count == 1)

        let stripSource = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouteStrip.swift",
            encoding: .utf8)
        let stripStart = try #require(stripSource.range(of: "struct RouteStrip: View"))
        let meterStart = try #require(
            stripSource.range(
                of: "private struct SourceLevelMeter",
                range: stripStart.upperBound..<stripSource.endIndex))
        let strip = stripSource[stripStart.lowerBound..<meterStart.lowerBound]
        let meter = stripSource[meterStart.lowerBound..<stripSource.endIndex]
        #expect(strip.ranges(of: "SourceLevelMeter(").count == 1)
        #expect(strip.ranges(of: "model.meter(of: group)").count == 0)
        #expect(meter.ranges(of: "BodyCount.tick(\"SourceLevelMeter\")").count == 1)
        #expect(meter.ranges(of: "model.meter(of: group)").count == 1)
    }

    /// `AudioDevice.hasFallenToCallQuality` reads the live sample rate through
    /// HAL. The status strip is invalidated by meters, recording state and
    /// pills, so putting that read in its body silently moved synchronous IPC
    /// onto the main actor at the poll cadence.
    @Test("status pills read the cached headset verdict only")
    func statusPillsDoNotReadHAL() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let pills = try String(
            contentsOfFile: root + "Sources/YunAudioApp/StatusPills.swift",
            encoding: .utf8)
        let model = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)

        #expect(pills.ranges(of: "model.headsetInCallQuality").count == 1)
        #expect(pills.ranges(of: ".hasFallenToCallQuality").count == 0)
        #expect(pills.ranges(of: ".currentSampleRate").count == 0)
        #expect(
            model.ranges(of: "private(set) var headsetInCallQuality: AudioDevice?").count
                == 1)
        #expect(model.ranges(of: "publish(headset, to: \\.headsetInCallQuality)").count == 2)

        let latencyStart = try #require(
            model.range(of: "var monitorLatencyMilliseconds: Double"))
        let latencyEnd = try #require(
            model.range(
                of: "private func applyMonitorGain",
                range: latencyStart.upperBound..<model.endIndex))
        let latency = model[latencyStart.lowerBound..<latencyEnd.lowerBound]
        #expect(latency.ranges(of: ".latencyFrames(").count == 0)
        #expect(latency.ranges(of: "monitorLatencyFrames").count == 2)
    }

    @Test("one source meter pass returns all three channel reductions")
    func sourceMeterReduction() {
        let meter = RouterModel.sourceMeter(
            routeIndices: [-1, 0, 2, 99],
            levels: [0.2, 0.9, 0.7],
            peakHolds: [0.5, 0.6, 0.8],
            clipped: [false, false, true])
        #expect(meter.level == 0.7)
        #expect(meter.peakHold == 0.8)
        #expect(meter.isClipped)

        #expect(
            RouterModel.sourceMeter(
                routeIndices: [],
                levels: [],
                peakHolds: [],
                clipped: [])
                == RouterModel.SourceMeter(level: 0, peakHold: 0, isClipped: false))
    }

    @Test("source grouping preserves first-seen order and every route")
    func sourceGrouping() {
        let routes = [
            Route(
                source: ChannelRef(deviceUID: "mic", channel: 0),
                destination: ChannelRef(deviceUID: "out", channel: 0)),
            Route(
                source: ChannelRef(deviceUID: "mic", channel: 1),
                destination: ChannelRef(deviceUID: "out", channel: 1)),
            Route(
                source: ChannelRef(deviceUID: "player", channel: 0),
                destination: ChannelRef(deviceUID: "out", channel: 0)),
            Route(
                source: ChannelRef(deviceUID: "mic", channel: 0),
                destination: ChannelRef(deviceUID: "monitor", channel: 0)),
        ]

        #expect(
            RouterModel.groupRoutes(routes) == [
                RouterModel.SourceGroup(uid: "mic", routes: [0, 1, 3]),
                RouterModel.SourceGroup(uid: "player", routes: [2]),
            ])
    }

    @Test("source taps are reused only while their engine rings still exist")
    func sourceTapReuse() {
        let sources = ["microphone", "player"]
        #expect(
            RouterModel.reusableSourceTapCount(
                isOpen: true, openedCount: 2, openedFor: sources, wanted: sources) == 2)
        #expect(
            RouterModel.reusableSourceTapCount(
                isOpen: true, openedCount: 0, openedFor: sources, wanted: sources) == nil)
        #expect(
            RouterModel.reusableSourceTapCount(
                isOpen: false, openedCount: 2, openedFor: sources, wanted: sources) == nil)
        #expect(
            RouterModel.reusableSourceTapCount(
                isOpen: true, openedCount: 2, openedFor: sources, wanted: ["player"]) == nil)
    }

    @Test("new transcript lines stay chronological and are never duplicated")
    func incrementalTranscriptMerge() {
        let late = Transcriber.Line(
            speaker: "Player", text: "later", start: 10, duration: 1)
        let early = Transcriber.Line(
            speaker: "Singer", text: "early", start: 2, duration: 1)
        let sameTime = Transcriber.Line(
            speaker: "Singer", text: "same time", start: 10, duration: 1)
        var transcript: [Transcriber.Line] = []

        #expect(RouterModel.insertTranscriptLine(late, into: &transcript))
        #expect(RouterModel.insertTranscriptLine(early, into: &transcript))
        #expect(RouterModel.insertTranscriptLine(sameTime, into: &transcript))
        #expect(!RouterModel.insertTranscriptLine(late, into: &transcript))
        #expect(transcript.map(\.text) == ["early", "later", "same time"])
    }

    /// The old poll created twenty Tasks per second, crossed every transcriber
    /// actor and sorted the complete transcript even when no line had changed.
    /// Keep both the event boundary and the full-stop invalidation structural:
    /// a fake performance test would otherwise miss their placement.
    @Test("the source poll neither scans transcript history nor trusts stopped taps")
    func sourceTapPollingIsEventDriven() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/RouterModel.swift",
            encoding: .utf8)
        let pumpStart = try #require(source.range(of: "private func pumpSourceTaps()"))
        let pumpEnd = try #require(
            source.range(
                of: "private func recognitionApplication",
                range: pumpStart.upperBound..<source.endIndex))
        let pump = source[pumpStart.lowerBound..<pumpEnd.lowerBound]
        #expect(pump.ranges(of: "collectTranscript").count == 0)
        #expect(pump.ranges(of: "Task {").count == 0)

        let openStart = try #require(source.range(of: "private func openSourceTaps()"))
        let openEnd = try #require(
            source.range(
                of: "private func invalidateSourceTaps",
                range: openStart.upperBound..<source.endIndex))
        let open = source[openStart.lowerBound..<openEnd.lowerBound]
        #expect(open.ranges(of: "engine.transcriptTapCount").count == 0)

        let stopStart = try #require(source.range(of: "private func finishStop()"))
        let stopEnd = try #require(
            source.range(
                of: "func toggle()",
                range: stopStart.upperBound..<source.endIndex))
        let stop = source[stopStart.lowerBound..<stopEnd.lowerBound]
        #expect(stop.ranges(of: "invalidateSourceTaps()").count == 1)
        #expect(
            source.ranges(
                of: "guard generation == transcriptSessionGeneration else { return }"
            ).count == 2)
    }
}

/// The write coalescer is only useful if it also avoids the allocations needed
/// to turn the model's sets and typed dictionaries into their Codable shape.
@Suite("Preference snapshot performance", .serialized)
struct PreferenceSnapshotPerformanceTests {
    #if DEBUG
        @Test(
            "coalescing avoids intermediate collection allocations",
            .disabled("allocation and timing evidence requires an optimised build"))
    #else
        @Test("coalescing avoids intermediate collection allocations")
    #endif
    func deferredCollections() throws {
        let captured = Set((0..<64).map { "com.example.captured.\($0)" })
        let excluded = Set((0..<64).map { "com.example.excluded.\($0)" })
        let effects = Set(EffectKind.allCases)
        let roles: [String: LevelCalibration.Role] = Dictionary(
            uniqueKeysWithValues: (0..<64).map {
                ("source-\($0)", $0.isMultiple(of: 2) ? .voice : .background)
            })
        let bindings = Dictionary(
            uniqueKeysWithValues: (0..<64).map {
                (
                    MIDITarget.sourceFader(uid: "source-\($0)"),
                    MIDIAddress(
                        channel: UInt8($0 / 16),
                        kind: .controlChange(UInt8($0 % 16)))
                )
            })
        let snapshots = (0..<100).map { value in
            var preferences = Preferences.default
            preferences.monoChannel = value
            return PendingPreferencesSnapshot(
                preferences,
                capturedAppBundleIDs: captured,
                excludedAppBundleIDs: excluded,
                enabledEffects: effects,
                sourceRoles: roles,
                midiBindings: bindings)
        }

        _ = Self.consume(try #require(snapshots.last).materialised())
        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }

        let eager = Self.measure(snapshots)
        let coalesced = Self.measure([try #require(snapshots.last)])

        print(
            "preferences collections: eager \(eager.nanoseconds) ns / "
                + "\(eager.allocations) allocations; coalesced "
                + "\(coalesced.nanoseconds) ns / \(coalesced.allocations) allocations")
        #expect(eager.checksum > coalesced.checksum)
        #expect(eager.allocations >= coalesced.allocations * 50)
        #expect(eager.nanoseconds > coalesced.nanoseconds * 10)
    }

    private static func measure(
        _ snapshots: [PendingPreferencesSnapshot]
    ) -> (allocations: UInt64, nanoseconds: UInt64, checksum: Int) {
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        yun_rt_tripwire_mark_realtime(true)
        var checksum = 0
        for snapshot in snapshots {
            checksum &+= consume(snapshot.materialised())
        }
        yun_rt_tripwire_mark_realtime(false)
        return (
            RoutingEngine.allocationViolations - before,
            DispatchTime.now().uptimeNanoseconds - started,
            checksum
        )
    }

    @inline(never)
    private static func consume(_ preferences: Preferences) -> Int {
        preferences.monoChannel
            + preferences.capturedAppBundleIDs.reduce(0) { $0 &+ $1.utf8.count }
            + (preferences.excludedAppBundleIDs ?? []).reduce(0) {
                $0 &+ $1.utf8.count
            }
            + preferences.enabledEffects.reduce(0) { $0 &+ $1.utf8.count }
            + (preferences.sourceRoles ?? [:]).reduce(0) {
                $0 &+ $1.key.utf8.count &+ $1.value.utf8.count
            }
            + (preferences.midiBindings ?? [:]).reduce(0) {
                $0 &+ $1.key.utf8.count &+ $1.value.utf8.count
            }
    }
}

@Suite("Source meter performance", .serialized)
struct SourceMeterPerformanceTests {
    #if DEBUG
        @Test(
            "ten thousand meter reductions allocate at most once",
            .disabled("allocation evidence requires an optimised build"))
    #else
        @Test("ten thousand meter reductions allocate at most once")
    #endif
    func allocationFreeReduction() {
        let indices = Array(0..<8)
        let levels: [Float] = [0.1, 0.4, 0.2, 0.8, 0.3, 0.7, 0.5, 0.6]
        let holds: [Float] = [0.2, 0.5, 0.3, 0.9, 0.4, 0.8, 0.6, 0.7]
        let clipped = [false, false, false, true, false, false, false, false]

        _ = RouterModel.sourceMeter(
            routeIndices: indices,
            levels: levels,
            peakHolds: holds,
            clipped: clipped)
        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }
        yun_rt_tripwire_mark_realtime(true)
        // Run the exact same caller before the baseline so lazy setup is not
        // charged to the repeated twenty-hertz operation.
        _ = Self.reduceMany(
            indices: indices, levels: levels, holds: holds, clipped: clipped)
        _ = Self.baselineMany()
        let baselineBefore = RoutingEngine.allocationViolations
        let baselineChecksum = Self.baselineMany()
        let baselineAllocations = RoutingEngine.allocationViolations - baselineBefore
        let before = RoutingEngine.allocationViolations
        let checksum = Self.reduceMany(
            indices: indices, levels: levels, holds: holds, clipped: clipped)
        yun_rt_tripwire_mark_realtime(false)
        let allocations = RoutingEngine.allocationViolations - before

        print(
            "10,000 source meter reductions: \(allocations) allocations "
                + "(loop baseline \(baselineAllocations)), \(checksum)")
        #expect(baselineChecksum > 10_000)
        #expect(checksum > 26_000)
        // The optimised caller records one allocation for the whole 10,000-call
        // batch. The old two compactMap arrays per reduction record about
        // 20,000; this bound catches that shape without calling the measured
        // one zero.
        #expect(allocations <= baselineAllocations + 1)
    }

    @inline(never)
    private static func reduceMany(
        indices: [Int],
        levels: [Float],
        holds: [Float],
        clipped: [Bool]
    ) -> Float {
        var checksum: Float = 0
        for _ in 0..<10_000 {
            let meter = RouterModel.sourceMeter(
                routeIndices: indices,
                levels: levels,
                peakHolds: holds,
                clipped: clipped)
            checksum += meter.level + meter.peakHold + (meter.isClipped ? 1 : 0)
        }
        return checksum
    }

    @inline(never)
    private static func baselineMany() -> Float {
        var checksum: Float = 0
        for index in 0..<10_000 {
            checksum += Float(index & 3)
        }
        return checksum
    }
}

@Suite("Source grouping performance", .serialized)
struct SourceGroupingPerformanceTests {
    #if DEBUG
        @Test(
            "ten thousand cache reads avoid ten thousand regroupings",
            .disabled("allocation and timing evidence requires an optimised build"))
    #else
        @Test("ten thousand cache reads avoid ten thousand regroupings")
    #endif
    func cachedGrouping() {
        let routes = (0..<16).map { index in
            Route(
                source: ChannelRef(deviceUID: "source-\(index % 4)", channel: index % 2),
                destination: ChannelRef(deviceUID: "output", channel: index % 2))
        }
        let cached = RouterModel.groupRoutes(routes)
        _ = Self.rebuildMany(routes)
        _ = Self.readMany(cached)

        AllocationMeasurementLock.shared.lock()
        defer { AllocationMeasurementLock.shared.unlock() }
        RoutingEngine.enableAllocationTripwire()
        defer { RoutingEngine.disableAllocationTripwire() }

        let rebuilt = Self.measure { Self.rebuildMany(routes) }
        let read = Self.measure { Self.readMany(cached) }
        print(
            "10,000 source groups: rebuild \(rebuilt.allocations) allocations / "
                + "\(rebuilt.nanoseconds) ns; cache \(read.allocations) allocations / "
                + "\(read.nanoseconds) ns")
        #expect(rebuilt.checksum == read.checksum)
        #expect(rebuilt.allocations >= read.allocations + 50_000)
        #expect(rebuilt.nanoseconds > read.nanoseconds * 10)
    }

    private static func measure(
        _ body: () -> Int
    ) -> (allocations: UInt64, nanoseconds: UInt64, checksum: Int) {
        let before = RoutingEngine.allocationViolations
        let started = DispatchTime.now().uptimeNanoseconds
        yun_rt_tripwire_mark_realtime(true)
        let checksum = body()
        yun_rt_tripwire_mark_realtime(false)
        return (
            RoutingEngine.allocationViolations - before,
            DispatchTime.now().uptimeNanoseconds - started,
            checksum
        )
    }

    @inline(never)
    private static func rebuildMany(_ routes: [Route]) -> Int {
        var checksum = 0
        for _ in 0..<10_000 {
            let groups = RouterModel.groupRoutes(routes)
            checksum &+= groups.count
            checksum &+= groups.first?.routes.count ?? 0
        }
        return checksum
    }

    @inline(never)
    private static func readMany(_ groups: [RouterModel.SourceGroup]) -> Int {
        var checksum = 0
        for _ in 0..<10_000 {
            checksum &+= groups.count
            checksum &+= groups.first?.routes.count ?? 0
        }
        return checksum
    }
}
