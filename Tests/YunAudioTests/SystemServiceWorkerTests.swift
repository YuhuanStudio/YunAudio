import AppKit
import Foundation
import Testing

@testable import YunAudioApp

private final class SystemServiceLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func read() -> Value { lock.withLock { value } }

    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

@Suite("System service workers", .serialized)
struct SystemServiceWorkerTests {
    @MainActor
    @Test("the first accepted value survives a queue which has not started")
    func synchronousReservationIsFirstLatest() async throws {
        let queue = DispatchQueue(label: "yunaudio.test.system-service-reservation")
        queue.suspend()
        let applied = SystemServiceLockedBox<[Int]>([])
        var published: [Int] = []
        let worker = SoleLatestSystemServiceWorker<Int, Int>(
            queue: queue,
            apply: { value, _ in
                applied.update { $0.append(value) }
                return value
            },
            publish: { published.append($0) })

        #expect(worker.submit(1))
        #expect(worker.submit(2))
        #expect(worker.submit(3))
        #expect(worker.statistics.applications == 0)
        #expect(worker.statistics.maximumPending == 1)
        queue.resume()

        for _ in 0..<2_000 where worker.statistics.publications != 1 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(applied.read() == [1, 3])
        #expect(published == [3])
        #expect(worker.statistics.submissions == 3)
        #expect(worker.statistics.coalesced == 1)
        #expect(worker.statistics.applications == 2)
        #expect(worker.statistics.revokedResults == 1)
        #expect(worker.statistics.maximumConcurrentApplications == 1)
    }

    @MainActor
    @Test("ten thousand requests retain one owner and only one pending value")
    func saturationNeverStartsAReplacementOwner() async throws {
        let began = SystemServiceLockedBox(false)
        let release = DispatchSemaphore(value: 0)
        let applied = SystemServiceLockedBox<[Int]>([])
        var published: [Int] = []
        let worker = SoleLatestSystemServiceWorker<Int, Int>(
            queue: DispatchQueue(label: "yunaudio.test.system-service-saturation"),
            apply: { value, _ in
                applied.update { $0.append(value) }
                if value == 0 {
                    began.update { $0 = true }
                    _ = release.wait(timeout: .now() + TestGate.deadlock)
                }
                return value
            },
            publish: { published.append($0) })

        #expect(worker.submit(0))
        for _ in 0..<2_000 where !began.read() {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(began.read())
        for value in 1..<10_000 { #expect(worker.submit(value)) }

        #expect(worker.statistics.submissions == 10_000)
        #expect(worker.statistics.coalesced == 9_998)
        #expect(worker.statistics.applications == 1)
        #expect(worker.statistics.maximumPending == 1)
        release.signal()
        for _ in 0..<2_000 where worker.statistics.publications != 1 {
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(applied.read() == [0, 9_999])
        #expect(published == [9_999])
        #expect(worker.statistics.maximumConcurrentApplications == 1)
    }

    @MainActor
    @Test("invalidation revokes a late result but keeps refused-Quit admission")
    func staleGenerationCannotPublish() async throws {
        let began = SystemServiceLockedBox(false)
        let release = DispatchSemaphore(value: 0)
        var published: [Int] = []
        let worker = SoleLatestSystemServiceWorker<Int, Int>(
            queue: DispatchQueue(label: "yunaudio.test.system-service-generation"),
            apply: { value, _ in
                if value == 1 {
                    began.update { $0 = true }
                    _ = release.wait(timeout: .now() + TestGate.deadlock)
                }
                return value
            },
            publish: { published.append($0) })

        #expect(worker.submit(1))
        for _ in 0..<2_000 where !began.read() {
            try await Task.sleep(for: .milliseconds(1))
        }
        worker.invalidate()
        #expect(worker.submit(2))
        release.signal()
        for _ in 0..<2_000 where published != [2] {
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(published == [2])
        #expect(worker.statistics.applications == 2)
        #expect(worker.statistics.revokedResults == 1)
    }

    @MainActor
    @Test("elapsed-time failure remains on the sole owner until it returns")
    func timeoutDoesNotCreateAReplacementThread() async throws {
        struct Result: Sendable { let value: Int; let timedOut: Bool }
        let began = SystemServiceLockedBox(false)
        let release = DispatchSemaphore(value: 0)
        var published: [Int] = []
        let worker = SoleLatestSystemServiceWorker<Int, Result>(
            queue: DispatchQueue(label: "yunaudio.test.system-service-timeout"),
            apply: { value, _ in
                if value == 1 {
                    began.update { $0 = true }
                    _ = release.wait(timeout: .now() + TestGate.deadlock)
                    return Result(value: value, timedOut: true)
                }
                return Result(value: value, timedOut: false)
            },
            didTimeOut: \.timedOut,
            publish: { published.append($0.value) })

        #expect(worker.submit(1))
        for _ in 0..<2_000 where !began.read() {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(worker.submit(2))
        #expect(worker.statistics.applications == 1)
        #expect(worker.statistics.maximumConcurrentApplications == 1)
        release.signal()
        for _ in 0..<2_000 where published != [2] {
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(worker.statistics.timedOutApplications == 1)
        #expect(worker.statistics.applications == 2)
        #expect(worker.statistics.maximumConcurrentApplications == 1)
        #expect(published == [2])
    }

    @MainActor
    @Test("terminal cleanup is ordered behind the active framework call")
    func terminalCleanupIsNonBlockingAndOrdered() async throws {
        let began = SystemServiceLockedBox(false)
        let release = DispatchSemaphore(value: 0)
        let events = SystemServiceLockedBox<[String]>([])
        let worker = SoleLatestSystemServiceWorker<Int, Int>(
            queue: DispatchQueue(label: "yunaudio.test.system-service-terminal"),
            apply: { value, _ in
                events.update { $0.append("apply-start") }
                began.update { $0 = true }
                _ = release.wait(timeout: .now() + TestGate.deadlock)
                events.update { $0.append("apply-end") }
                return value
            },
            publish: { _ in })

        #expect(worker.submit(1))
        for _ in 0..<2_000 where !began.read() {
            try await Task.sleep(for: .milliseconds(1))
        }
        worker.shutdown(after: { events.update { $0.append("terminal") } })
        #expect(!worker.submit(2))
        #expect(events.read() == ["apply-start"])
        release.signal()
        for _ in 0..<2_000 where worker.statistics.terminalOperations != 1 {
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(events.read() == ["apply-start", "apply-end", "terminal"])
        #expect(worker.statistics.publications == 0)
        #expect(worker.statistics.terminalOperations == 1)
    }
}

@Suite("Application icon worker", .serialized)
struct AppIconWorkerTests {
    @MainActor
    @Test("duplicate misses are one raster and sixty-four outstanding paths")
    func boundedDeduplication() async throws {
        let queue = DispatchQueue(label: "yunaudio.test.icon-reservation")
        queue.suspend()
        let loaded = SystemServiceLockedBox<[String]>([])
        var published: [String] = []
        let worker = AppIconLoadWorker(
            queue: queue,
            load: { path in
                loaded.update { $0.append(path) }
                return NSImage(size: NSSize(width: 1, height: 1))
            },
            rasterise: { $0 },
            publish: { published.append($0.path) })

        #expect(worker.submit(path: "/Applications/First.app"))
        for _ in 0..<10_000 {
            #expect(!worker.submit(path: "/Applications/First.app"))
        }
        for index in 1..<AppIconLoadWorker.maximumOutstanding {
            #expect(worker.submit(path: "/Applications/App-\(index).app"))
        }
        #expect(!worker.submit(path: "/Applications/Overflow.app"))
        #expect(worker.statistics.maximumOutstanding == 64)
        #expect(worker.statistics.duplicates == 10_000)
        #expect(worker.statistics.rejectedAtCapacity == 1)
        queue.resume()

        for _ in 0..<2_000 where worker.statistics.publications != 64 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(loaded.read().count == 64)
        #expect(Set(published).count == 64)
        #expect(worker.statistics.applications == 64)
        #expect(worker.statistics.maximumConcurrentApplications == 1)
    }

    @MainActor
    @Test("icon invalidation drops queued and late answers then remains reusable")
    func invalidationRevokesStaleGeneration() async throws {
        let began = SystemServiceLockedBox(false)
        let release = DispatchSemaphore(value: 0)
        let loaded = SystemServiceLockedBox<[String]>([])
        var published: [String] = []
        let worker = AppIconLoadWorker(
            queue: DispatchQueue(label: "yunaudio.test.icon-generation"),
            load: { path in
                loaded.update { $0.append(path) }
                if path == "old" {
                    began.update { $0 = true }
                    _ = release.wait(timeout: .now() + TestGate.deadlock)
                }
                return NSImage(size: NSSize(width: 1, height: 1))
            },
            rasterise: { $0 },
            publish: { published.append($0.path) })

        #expect(worker.submit(path: "old"))
        for _ in 0..<2_000 where !began.read() {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(worker.submit(path: "queued"))
        worker.invalidate()
        #expect(worker.submit(path: "new"))
        release.signal()
        for _ in 0..<2_000 where published != ["new"] {
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(loaded.read() == ["old", "new"])
        #expect(published == ["new"])
        #expect(worker.statistics.revokedResults == 2)
        worker.shutdown()
        #expect(!worker.submit(path: "after-shutdown"))
    }

    @Test("the icon miss path contains no synchronous workspace or raster call")
    func sourceBoundary() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/AppSourceList.swift",
            encoding: .utf8)
        let start = try #require(source.range(of: "private struct AppIconView"))
        let end = try #require(
            source.range(
                of: "enum AppIconRasteriser", range: start.upperBound..<source.endIndex))
        let view = source[start.lowerBound..<end.lowerBound]
        #expect(!view.contains("NSWorkspace.shared"))
        #expect(!view.contains("NSGraphicsContext"))
        #expect(!view.contains("NSBitmapImageRep"))
        #expect(view.contains("AppIconStore.shared.image(for: url)"))

        let worker = try String(
            contentsOfFile: root + "Sources/YunAudioApp/AppIconWorker.swift",
            encoding: .utf8)
        #expect(worker.contains("static let maximumOutstanding = 64"))
        #expect(worker.contains("NSWorkspace.shared.icon(forFile:"))
        #expect(worker.contains("MainRunLoopDelivery.perform"))
    }
}

@Suite("Permission snapshot worker", .serialized)
struct PermissionSnapshotWorkerTests {
    @Test("one snapshot finds eight targets in ten calls without touching TCC")
    func finiteRegistryBoundary() {
        let calls = SystemServiceLockedBox<[String]>([])
        let candidates = (0..<12).map {
            NowPlaying.AutomationTarget(name: "Player \($0)", bundleID: "player.\($0)")
        }
        let operations = PermissionSystemServiceOperations(
            microphoneState: {
                calls.update { $0.append("microphone") }
                return .allowed
            },
            loginItemState: {
                calls.update { $0.append("login") }
                return .needsRequest
            },
            isApplicationInstalled: { bundleID in
                calls.update { $0.append("installed:\(bundleID)") }
                return true
            })

        let result = PermissionSafeStatusProbe.inspect(
            .init(timeout: .seconds(1)), candidates: candidates, operations: operations)
        #expect(!result.timedOut)
        #expect(result.microphone == .allowed)
        #expect(result.loginItem == .needsRequest)
        #expect(result.automationTargets.count == 8)
        #expect(result.completedSystemCalls == 10)
        #expect(calls.read().count == 10)
        #expect(calls.read().filter { $0.hasPrefix("installed:") }.count == 8)
    }

    @Test("a late system answer stops the remaining snapshot calls")
    func elapsedBudgetStopsTheSnapshot() {
        let calls = SystemServiceLockedBox<[String]>([])
        let operations = PermissionSystemServiceOperations(
            microphoneState: {
                calls.update { $0.append("microphone") }
                Thread.sleep(forTimeInterval: 0.01)
                return .allowed
            },
            loginItemState: {
                calls.update { $0.append("login") }
                return .allowed
            },
            isApplicationInstalled: { _ in
                calls.update { $0.append("registry") }
                return true
            })

        let result = PermissionSafeStatusProbe.inspect(
            .init(timeout: .milliseconds(1)), operations: operations)
        #expect(result.timedOut)
        #expect(result.completedSystemCalls == 1)
        #expect(calls.read() == ["microphone"])
    }

    @Test("production status refresh contains no synchronous registry or TCC probe")
    func mainActorSourceBoundary() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let permission = try String(
            contentsOfFile: root + "Sources/YunAudioApp/PermissionCentre.swift",
            encoding: .utf8)
        let refreshStart = try #require(permission.range(of: "func refreshSafeStatuses()"))
        let refreshEnd = try #require(
            permission.range(
                of: "var hasInstalledPlayer",
                range: refreshStart.upperBound..<permission.endIndex))
        let refresh = permission[refreshStart.lowerBound..<refreshEnd.lowerBound]
        for forbidden in [
            "AVCaptureDevice.authorizationStatus", "LoginItem.state",
            "installedAutomationTargets", "automationPermissionStatus",
            "NSWorkspace.shared",
        ] {
            #expect(!refresh.contains(forbidden), "refresh contains \(forbidden)")
        }
        #expect(refresh.contains("safeStatusService.submit(PermissionSafeStatusRequest())"))

        let preferences = try String(
            contentsOfFile: root + "Sources/YunAudioApp/PreferencesWindow.swift",
            encoding: .utf8)
        #expect(!preferences.contains("switch LoginItem.state"))
        let nowPlaying = try String(
            contentsOfFile: root + "Sources/YunAudioApp/NowPlaying.swift", encoding: .utf8)
        let installed = try #require(
            nowPlaying.range(of: "static var installedAutomationTargets"))
        let current = try #require(
            nowPlaying.range(
                of: "nonisolated static func current()",
                range: installed.upperBound..<nowPlaying.endIndex))
        #expect(
            !nowPlaying[installed.lowerBound..<current.lowerBound].contains(
                "NSWorkspace.shared"))
    }

    @Test("now-playing artwork has input, pixel and decoded-byte ceilings")
    func artworkDecodeBoundary() throws {
        #expect(NowPlayingArtworkDecoder.maximumInputBytes == 8 * 1_024 * 1_024)
        #expect(NowPlayingArtworkDecoder.maximumPixelSize == 512)
        #expect(
            NowPlayingArtworkDecoder.decode(
                Data(repeating: 0, count: NowPlayingArtworkDecoder.maximumInputBytes + 1))
                == nil)

        let root = PreferencesCompletenessTests.sourceRootForTests
        let data = try Data(
            contentsOf: URL(
                fileURLWithPath: root + "Sources/YunAudioApp/Resources/Icon.png"))
        let decoded = try #require(NowPlayingArtworkDecoder.decode(data))
        #expect(decoded.image.width <= 512)
        #expect(decoded.image.height <= 512)
        #expect(decoded.cost <= 512 * 512 * 4)
    }

    @Test("MainActor now-playing state contains no framework or image decode call")
    func nowPlayingMainActorSourceBoundary() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/NowPlayingStage.swift",
            encoding: .utf8)
        let start = try #require(source.range(of: "@MainActor\nfinal class NowPlayingStage"))
        let mainActorHalf = source[start.lowerBound...]
        for forbidden in [
            "MPNowPlayingInfoCenter.default", "MPRemoteCommandCenter.shared",
            "NSImage(data:", "SongArtworkDecoder.decode", "NSWorkspace.shared",
        ] {
            #expect(!mainActorHalf.contains(forbidden), "MainActor half contains \(forbidden)")
        }
        #expect(mainActorHalf.contains("systemServiceWorker.submit("))
        #expect(mainActorHalf.contains("systemServiceWorker.shutdown(after:"))
    }
}
