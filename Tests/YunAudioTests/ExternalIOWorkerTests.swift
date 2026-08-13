import Foundation
import Testing

@testable import YunAudioApp
@testable import YunAudioEngine

private final class ExternalIOLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func read() -> Value { lock.withLock { value } }

    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

private actor ExternalIOAsyncGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiter = continuation
            }
        }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

@Suite("External I/O workers", .serialized)
struct ExternalIOWorkerTests {
    @MainActor
    @Test("ten thousand synchronous requests execute first and latest and publish only latest")
    func synchronousFirstLatestBoundary() async throws {
        let began = ExternalIOLockedBox(false)
        let release = DispatchSemaphore(value: 0)
        let applied = ExternalIOLockedBox<[Int]>([])
        var published: [Int] = []
        let lane = LatestExternalWorkLane<Int, Int>(
            queue: DispatchQueue(label: "yunaudio.test.external-first-latest"),
            apply: { value in
                applied.update { $0.append(value) }
                if value == 0 {
                    began.update { $0 = true }
                    _ = release.wait(timeout: .now() + 2)
                }
                return value
            },
            publish: { published.append($0) })

        #expect(lane.submit(0))
        for _ in 0..<2_000 where !began.read() {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(began.read())
        var acceptedEveryRequest = true
        for value in 1..<10_000 {
            acceptedEveryRequest = lane.submit(value) && acceptedEveryRequest
        }
        #expect(acceptedEveryRequest)

        let held = lane.statistics
        #expect(held.submissions == 10_000)
        #expect(held.coalesced == 9_998)
        #expect(held.applications == 1)
        #expect(held.maximumPending == 1)
        #expect(published.isEmpty)

        release.signal()
        for _ in 0..<2_000 where lane.statistics.publications != 1 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(applied.read() == [0, 9_999])
        #expect(published == [9_999])
        #expect(lane.statistics.applications == 2)
        #expect(lane.statistics.revokedResults == 1)
        lane.shutdown()
        #expect(!lane.submit(10_000))
    }

    @MainActor
    @Test("invalidation revokes an exit attempt without closing future admission")
    func invalidationRemainsReusable() async throws {
        let began = ExternalIOLockedBox(false)
        let release = DispatchSemaphore(value: 0)
        var published: [Int] = []
        let lane = LatestExternalWorkLane<Int, Int>(
            queue: DispatchQueue(label: "yunaudio.test.refused-exit-recovery"),
            apply: { value in
                if value == 1 {
                    began.update { $0 = true }
                    _ = release.wait(timeout: .now() + 2)
                }
                return value
            },
            publish: { published.append($0) })

        #expect(lane.submit(1))
        for _ in 0..<2_000 where !began.read() {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(began.read())
        lane.invalidate()
        // This is the AppKit-refused-Quit case: stale publication is revoked,
        // but the still-live process must be able to submit new work.
        #expect(lane.submit(2))
        release.signal()
        for _ in 0..<2_000 where published != [2] {
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(published == [2])
        #expect(lane.statistics.applications == 2)
        #expect(lane.statistics.revokedResults == 1)
        lane.shutdown()
    }

    @MainActor
    @Test("ten thousand local-song termination requests share one fence")
    func localSongTerminationIsExactOnce() {
        let worker = LocalSongOperationWorker(publish: { _ in })
        let first = worker.requestTerminationStop(timeout: 0.25)
        var everyRequestShared = true
        for _ in 1..<10_000 {
            everyRequestShared =
                (worker.requestTerminationStop(timeout: 0.25) === first)
                && everyRequestShared
        }

        #expect(everyRequestShared)
        #expect(first.wait(timeout: 1) == .complete)
        #expect(first.completionCount == 1)
    }

    @MainActor
    @Test("ten thousand async metadata requests retain one pending task")
    func asynchronousFirstLatestBoundary() async throws {
        let began = ExternalIOLockedBox(false)
        let release = ExternalIOAsyncGate()
        let applied = ExternalIOLockedBox<[UInt64]>([])
        var published: [UInt64] = []
        let worker = LocalSongMetadataWorker(
            load: { request in
                applied.update { $0.append(request.generation) }
                if request.generation == 0 {
                    began.update { $0 = true }
                    await release.wait()
                }
                return LocalSongMetadataSnapshot(
                    generation: request.generation, url: request.url,
                    title: nil, artist: nil, album: nil, artwork: nil,
                    rejectedOversizedValue: false, timedOut: false)
            },
            publish: { published.append($0.generation) })
        let url = URL(fileURLWithPath: "/tmp/yunaudio-metadata-test")

        #expect(worker.submit(LocalSongMetadataRequest(generation: 0, url: url)))
        for _ in 0..<2_000 where !began.read() {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(began.read())
        var acceptedEveryRequest = true
        for generation in 1..<UInt64(10_000) {
            acceptedEveryRequest =
                worker.submit(
                    LocalSongMetadataRequest(generation: generation, url: url))
                && acceptedEveryRequest
        }
        #expect(acceptedEveryRequest)
        #expect(worker.statistics.submissions == 10_000)
        #expect(worker.statistics.coalesced == 9_998)
        #expect(worker.statistics.applications == 1)
        #expect(worker.statistics.maximumPending == 1)

        await release.open()
        for _ in 0..<2_000 where worker.statistics.publications != 1 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(applied.read() == [0, 9_999])
        #expect(published == [9_999])
        #expect(worker.statistics.revokedResults == 1)
        worker.shutdown()
    }

    @Test("bounded file reads reject the byte after their ceiling")
    func boundedFileRead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yunaudio-bounded-read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x5A, count: 4_097).write(to: url)
        let deadline = ExternalIODeadline(timeout: .seconds(1))

        #expect(BoundedFileSystem.system.readFile(url, 4_096, deadline) == .tooLarge)
        #expect(
            BoundedFileSystem.system.readFile(
                url, 4_097, ExternalIODeadline(timeout: .seconds(1)))
                == .data(Data(repeating: 0x5A, count: 4_097)))
    }

    @Test("driver manifests settle the comparison without reading either binary")
    func driverManifestComparison() {
        let installed = URL(fileURLWithPath: "/installed/YunAudioDriver.driver")
        let bundled = URL(fileURLWithPath: "/bundle/YunAudioDriver.driver")
        let binaryReads = ExternalIOLockedBox(0)
        let fileSystem = BoundedFileSystem(
            itemExists: { _, _ in .exists(true) },
            listDirectory: { _, _, _, _ in
                BoundedDirectorySnapshot(
                    names: [], isAvailable: false, reachedLimit: false, timedOut: false)
            },
            readFile: { url, _, _ in
                if url.lastPathComponent == "Info.plist" {
                    let identifier = url.path.hasPrefix("/installed") ? "old" : "new"
                    return .data(
                        try! PropertyListSerialization.data(
                            fromPropertyList: ["YunAudioSourceIdentifier": identifier],
                            format: .binary, options: 0))
                }
                binaryReads.update { $0 += 1 }
                return .unavailable
            })

        let result = DriverStatusProbe.inspect(
            .init(installedDriverURL: installed, bundledCandidates: [bundled]),
            fileSystem: fileSystem)
        #expect(result.isInstalled)
        #expect(result.bundledDriverURL == bundled)
        #expect(result.isOutOfDate == true)
        #expect(binaryReads.read() == 0)
    }

    @Test("an oversized driver manifest is unknown rather than a false match")
    func driverManifestByteCeiling() {
        let installed = URL(fileURLWithPath: "/installed/YunAudioDriver.driver")
        let bundled = URL(fileURLWithPath: "/bundle/YunAudioDriver.driver")
        let fileSystem = BoundedFileSystem(
            itemExists: { _, _ in .exists(true) },
            listDirectory: { _, _, _, _ in
                BoundedDirectorySnapshot(
                    names: [], isAvailable: false, reachedLimit: false, timedOut: false)
            },
            readFile: { _, _, _ in .tooLarge })
        let result = DriverStatusProbe.inspect(
            .init(installedDriverURL: installed, bundledCandidates: [bundled]),
            fileSystem: fileSystem)

        #expect(result.isOutOfDate == nil)
        #expect(result.rejectedOversizedInput)
        #expect(!result.timedOut)
    }

    @Test("queue restoration preserves the selected duplicate and bounds path count")
    func queueRestoreDuplicateIdentity() {
        let fileSystem = BoundedFileSystem(
            itemExists: { _, _ in .exists(true) },
            listDirectory: { _, _, _, _ in
                BoundedDirectorySnapshot(
                    names: [], isAvailable: false, reachedLimit: false, timedOut: false)
            },
            readFile: { _, _, _ in .unavailable })
        let duplicate = "/Volumes/KTV/duet.wav"
        let paths =
            [duplicate, duplicate]
            + (0..<KTVQueueRestoreLoader.maximumPaths).map { "/Volumes/KTV/\($0).wav" }
        let result = KTVQueueRestoreLoader.restore(
            KTVQueueRestoreRequest(paths: paths, currentIndex: 1),
            fileSystem: fileSystem)

        #expect(result.songs.count == KTVQueueRestoreLoader.maximumPaths)
        #expect(result.currentIndex == 1)
        #expect(result.inspectedPaths == KTVQueueRestoreLoader.maximumPaths)
        #expect(result.reachedLimit)
    }

    @MainActor
    @Test("one local-resource scan finds timed words and artwork within numeric bounds")
    func nowPlayingResourceSnapshot() throws {
        let directory = URL(fileURLWithPath: "/lyrics", isDirectory: true)
        let names = ["Artist - Title.lrc", "Artist - Title.png"]
        let listCalls = ExternalIOLockedBox(0)
        let lyric = Data("[00:01.00]first\n[00:02.00]second".utf8)
        let fileSystem = BoundedFileSystem(
            itemExists: { _, _ in .exists(true) },
            listDirectory: { _, maximumEntries, _, _ in
                listCalls.update { $0 += 1 }
                return BoundedDirectorySnapshot(
                    names: Array(names.prefix(maximumEntries)), isAvailable: true,
                    reachedLimit: names.count > maximumEntries, timedOut: false)
            },
            readFile: { url, maximumBytes, _ in
                if url.pathExtension.lowercased() == "lrc" {
                    return lyric.count <= maximumBytes ? .data(lyric) : .tooLarge
                }
                return .unavailable
            })
        let track = NowPlaying.Track(
            application: "Music", title: "Title", artist: "Artist", album: "",
            position: 0, duration: 10, isPlaying: true, identity: "track-1")
        let result = NowPlayingResourceLoader.load(
            NowPlayingResourceRequest(
                generation: 7, track: track, directory: directory,
                needsArtwork: true),
            fileSystem: fileSystem)

        #expect(listCalls.read() == 1)
        #expect(result.timedLyrics?.lines.count == 2)
        #expect(result.timedLyricsURL?.lastPathComponent == "Artist - Title.lrc")
        #expect(result.artworkURL?.lastPathComponent == "Artist - Title.png")
        #expect(result.filesRead == 1)
        #expect(result.bytesRead == lyric.count)
        #expect(!result.reachedLimit)
    }

    @Test("local-song sidecars use exact names and reject oversized input")
    func localSongResourceBounds() {
        let song = URL(fileURLWithPath: "/Volumes/KTV/duet.wav")
        let lyricData = Data("[00:01.00]first\n[00:02.00]second".utf8)
        let inspected = ExternalIOLockedBox<[String]>([])
        let fileSystem = BoundedFileSystem(
            itemExists: { url, _ in
                inspected.update { $0.append(url.lastPathComponent) }
                return .exists(url.lastPathComponent == "duet.png")
            },
            listDirectory: { _, _, _, _ in
                Issue.record("an exact-name sidecar lookup must not enumerate the directory")
                return BoundedDirectorySnapshot(
                    names: [], isAvailable: false, reachedLimit: false, timedOut: false)
            },
            readFile: { url, maximumBytes, _ in
                inspected.update { $0.append(url.lastPathComponent) }
                if url.pathExtension == "lrc" {
                    return lyricData.count <= maximumBytes ? .data(lyricData) : .tooLarge
                }
                return .unavailable
            })

        let result = LocalSongResourceLoader.load(
            LocalSongResourceRequest(
                generation: 17, url: song, embeddedArtwork: nil),
            fileSystem: fileSystem)

        #expect(result.generation == 17)
        #expect(result.lyrics?.lines.count == 2)
        #expect(result.lyricsURL?.lastPathComponent == "duet.lrc")
        #expect(result.artworkURL?.lastPathComponent == "duet.png")
        #expect(result.filesRead == 1)
        #expect(result.bytesRead == lyricData.count)
        #expect(!result.rejectedOversizedInput)
        #expect(!result.timedOut)
        #expect(inspected.read().count <= LocalSongResourceLoader.maximumFiles + 5)

        let oversized = LocalSongResourceLoader.load(
            LocalSongResourceRequest(
                generation: 18, url: song,
                embeddedArtwork: Data(
                    repeating: 0x5A,
                    count: LocalSongResourceLoader.maximumArtworkBytes + 1)),
            fileSystem: BoundedFileSystem(
                itemExists: { _, _ in .exists(false) },
                listDirectory: { _, _, _, _ in
                    BoundedDirectorySnapshot(
                        names: [], isAvailable: false, reachedLimit: false,
                        timedOut: false)
                },
                readFile: { url, _, _ in
                    url.pathExtension.lowercased() == "lrc" ? .tooLarge : .unavailable
                }))
        #expect(oversized.lyrics == nil)
        #expect(oversized.artworkURL == nil)
        #expect(oversized.rejectedOversizedInput)
    }

    @Test("hand-selected words stay within exact-name and byte ceilings")
    func handWordsResourceBounds() {
        let words = URL(fileURLWithPath: "/Volumes/KTV/duet.lrc")
        let lyricData = Data("[00:01.00]first\n[00:02.00]second".utf8)
        let inspected = ExternalIOLockedBox<[String]>([])
        let fileSystem = BoundedFileSystem(
            itemExists: { url, _ in
                inspected.update { $0.append(url.lastPathComponent) }
                return .exists(url.lastPathComponent == "duet.png")
            },
            listDirectory: { _, _, _, _ in
                Issue.record("hand-selected sidecars must not enumerate their directory")
                return BoundedDirectorySnapshot(
                    names: [], isAvailable: false, reachedLimit: false, timedOut: false)
            },
            readFile: { url, maximumBytes, _ in
                inspected.update { $0.append(url.lastPathComponent) }
                if url.pathExtension.lowercased() == "lrc" {
                    return lyricData.count <= maximumBytes ? .data(lyricData) : .tooLarge
                }
                return .unavailable
            })

        let result = HandWordsResourceLoader.load(
            HandWordsResourceRequest(generation: 41, url: words),
            fileSystem: fileSystem)

        #expect(result.generation == 41)
        #expect(result.lyrics?.lines.count == 2)
        #expect(result.artworkURL?.lastPathComponent == "duet.png")
        #expect(result.failure == nil)
        #expect(result.filesRead == 1)
        #expect(result.bytesRead == lyricData.count)
        #expect(result.filesInspected <= HandWordsResourceLoader.maximumFilesInspected)
        #expect(!result.rejectedOversizedSidecar)
        #expect(!result.timedOutBesideLyrics)

        let oversized = HandWordsResourceLoader.load(
            HandWordsResourceRequest(generation: 42, url: words),
            fileSystem: BoundedFileSystem(
                itemExists: { _, _ in .exists(false) },
                listDirectory: { _, _, _, _ in
                    BoundedDirectorySnapshot(
                        names: [], isAvailable: false, reachedLimit: false,
                        timedOut: false)
                },
                readFile: { url, _, _ in
                    url.pathExtension.lowercased() == "lrc" ? .tooLarge : .unavailable
                }))
        #expect(oversized.failure == .lyricsTooLarge)
        #expect(oversized.filesRead == 0)
        #expect(oversized.bytesRead == 0)
    }

    @MainActor
    @Test("a late selected-words result cannot replace the latest choice")
    func handWordsLatestWins() async throws {
        let began = ExternalIOLockedBox(false)
        let release = DispatchSemaphore(value: 0)
        let first = URL(fileURLWithPath: "/Volumes/KTV/first.lrc")
        let latest = URL(fileURLWithPath: "/Volumes/KTV/latest.lrc")
        let data = Data("[00:01.00]line".utf8)
        var published: [String] = []
        let worker = HandWordsResourceWorker(
            fileSystem: BoundedFileSystem(
                itemExists: { _, _ in .exists(false) },
                listDirectory: { _, _, _, _ in
                    BoundedDirectorySnapshot(
                        names: [], isAvailable: false, reachedLimit: false,
                        timedOut: false)
                },
                readFile: { url, _, _ in
                    if url == first {
                        began.update { $0 = true }
                        _ = release.wait(timeout: .now() + 2)
                    }
                    return url.pathExtension == "lrc" ? .data(data) : .unavailable
                }),
            publish: { published.append($0.url.lastPathComponent) })

        #expect(worker.submit(HandWordsResourceRequest(generation: 1, url: first)))
        for _ in 0..<2_000 where !began.read() {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(began.read())
        for generation in 2..<UInt64(10_000) {
            #expect(
                worker.submit(
                    HandWordsResourceRequest(generation: generation, url: latest)))
        }
        #expect(worker.statistics.maximumPending == 1)
        release.signal()
        for _ in 0..<2_000 where published.isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(published == ["latest.lrc"])
        #expect(worker.statistics.applications == 2)
        #expect(worker.statistics.revokedResults == 1)
        worker.shutdown()
    }

    @Test("transcript formatting saturates time and rejects the byte after its limit")
    func transcriptSaveBounds() throws {
        let written = ExternalIOLockedBox<Data?>(nil)
        let line = Transcriber.Line(
            speaker: "Microphone", text: "hello",
            start: .infinity, duration: 1)
        let request = TranscriptSaveRequest(
            generation: 51, lines: [line],
            directory: URL(fileURLWithPath: "/recordings"),
            date: Date(timeIntervalSince1970: 0))
        let saved = TranscriptSaveOperation.save(
            request,
            fileSystem: TranscriptFileSystem { data, _, _ in
                written.update { $0 = data }
                return .complete
            })

        #expect(saved.generation == 51)
        #expect(saved.linesWritten == 1)
        #expect(saved.bytesWritten == written.read()?.count)
        #expect(saved.failure == nil)
        #expect(
            String(decoding: try #require(written.read()), as: UTF8.self)
                .hasPrefix("[00:00]"))

        let oversized = TranscriptSaveOperation.save(
            TranscriptSaveRequest(
                generation: 52,
                lines: [
                    Transcriber.Line(
                        speaker: "Microphone",
                        text: String(
                            repeating: "x",
                            count: TranscriptSaveOperation.maximumTextBytes + 1),
                        start: 0, duration: 1)
                ],
                directory: URL(fileURLWithPath: "/recordings")),
            fileSystem: TranscriptFileSystem { _, _, _ in
                Issue.record("oversized transcript input must not reach storage")
                return .complete
            })
        #expect(oversized.failure == .inputTooLarge)
        #expect(oversized.bytesWritten == 0)
    }

    @Test("a transcript is private from its first inode")
    func transcriptSavePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yunaudio-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = TranscriptSaveOperation.save(
            TranscriptSaveRequest(
                generation: 53,
                lines: [
                    Transcriber.Line(
                        speaker: "Microphone", text: "private words",
                        start: 1, duration: 1)
                ],
                directory: directory,
                date: Date(timeIntervalSince1970: 0)))

        let url = try #require(result.outputURL)
        #expect(result.failure == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o600)
        #expect(
            String(decoding: try Data(contentsOf: url), as: UTF8.self)
                == "[00:01] Microphone: private words")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    }

    @MainActor
    @Test("transcript save storms retain one latest write")
    func transcriptSaveLatestWins() async throws {
        let began = ExternalIOLockedBox(false)
        let release = DispatchSemaphore(value: 0)
        let applied = ExternalIOLockedBox<[UInt64]>([])
        var published: [UInt64] = []
        let worker = TranscriptSaveWorker(
            fileSystem: TranscriptFileSystem { data, _, _ in
                let text = String(decoding: data, as: UTF8.self)
                let generation = UInt64(text.split(separator: " ").last ?? "") ?? 0
                applied.update { $0.append(generation) }
                if generation == 0 {
                    began.update { $0 = true }
                    _ = release.wait(timeout: .now() + 2)
                }
                return .complete
            },
            publish: { published.append($0.generation) })
        func request(_ generation: UInt64) -> TranscriptSaveRequest {
            TranscriptSaveRequest(
                generation: generation,
                lines: [
                    Transcriber.Line(
                        speaker: "", text: "\(generation)", start: 0, duration: 1)
                ],
                directory: URL(fileURLWithPath: "/recordings"))
        }

        #expect(worker.submit(request(0)))
        for _ in 0..<2_000 where !began.read() {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(began.read())
        for generation in 1..<UInt64(10_000) { #expect(worker.submit(request(generation))) }
        #expect(worker.statistics.maximumPending == 1)
        release.signal()
        for _ in 0..<2_000 where published.isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(published == [9_999])
        #expect(worker.statistics.applications == 2)
        #expect(worker.statistics.revokedResults == 1)
        worker.shutdown()
    }

    @Test("profile loading caps a ten-thousand-entry directory and every file")
    func headphoneProfileBounds() {
        let directory = URL(fileURLWithPath: "/profiles", isDirectory: true)
        let names = (0..<10_000).map { String(format: "%05d.txt", $0) }
        let text = Data(
            "Preamp: -6.0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 6.0 dB Q 1.00".utf8)
        let fileSystem = BoundedFileSystem(
            itemExists: { _, _ in .exists(true) },
            listDirectory: { _, maximumEntries, _, _ in
                BoundedDirectorySnapshot(
                    names: Array(names.prefix(maximumEntries)), isAvailable: true,
                    reachedLimit: names.count > maximumEntries, timedOut: false)
            },
            readFile: { _, maximumBytes, _ in
                text.count <= maximumBytes ? .data(text) : .tooLarge
            })
        let result = HeadphoneProfileLoader.read(
            directory: directory, fileSystem: fileSystem)

        #expect(result.directoryEntries == HeadphoneProfileLoader.maximumDirectoryEntries)
        #expect(result.filesRead == HeadphoneProfileLoader.maximumProfileFiles)
        #expect(result.profiles.count == HeadphoneProfileLoader.maximumProfileFiles)
        #expect(result.bytesRead == text.count * HeadphoneProfileLoader.maximumProfileFiles)
        #expect(result.reachedLimit)
    }

    @MainActor
    @Test("a blocked plug-in registry retains one rescan behind the active scan")
    func pluginRegistryStorm() async throws {
        let began = ExternalIOLockedBox(false)
        let scans = ExternalIOLockedBox(0)
        let release = DispatchSemaphore(value: 0)
        var publications = 0
        let worker = PluginRegistryWorker(
            scan: {
                let scan = scans.read()
                scans.update { $0 += 1 }
                if scan == 0 {
                    began.update { $0 = true }
                    _ = release.wait(timeout: .now() + 2)
                }
                return []
            },
            publish: { _ in publications += 1 })

        #expect(worker.submit())
        for _ in 0..<2_000 where !began.read() {
            try await Task.sleep(for: .milliseconds(1))
        }
        var acceptedEveryRequest = true
        for _ in 1..<10_000 { acceptedEveryRequest = worker.submit() && acceptedEveryRequest }
        #expect(acceptedEveryRequest)
        #expect(worker.statistics.submissions == 10_000)
        #expect(worker.statistics.maximumPending == 1)
        #expect(worker.statistics.applications == 1)
        release.signal()
        for _ in 0..<2_000 where worker.statistics.publications != 1 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(scans.read() == 2)
        #expect(publications == 1)
        #expect(worker.statistics.revokedResults == 1)
        worker.shutdown()
    }
}
