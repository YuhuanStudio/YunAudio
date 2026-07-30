import AppKit
import Foundation
import Testing
import YunAudioEngine

@testable import YunAudioApp

@MainActor
@Suite("Singing interface performance")
struct SingingUIPerformanceTests {
    @Test("large artwork is decoded to display size")
    func artworkDecodeIsBounded() throws {
        let width = 2_048
        let height = 1_024
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let decoded = try #require(
            SongArtworkDecoder.decode(data, maxPixelSize: 256))

        let longestSide = max(decoded.image.width, decoded.image.height)
        let decodedRatio = Double(decoded.image.width) / Double(decoded.image.height)
        let sourceBytes = width * height * 4
        print(
            "2048×1024 cover: \(sourceBytes) source pixel bytes → "
                + "\(decoded.image.width)×\(decoded.image.height), "
                + "\(decoded.cost) cached bytes")

        #expect(longestSide <= 256)
        #expect(abs(decodedRatio - 2) < 0.01)
        #expect(decoded.cost * 32 <= sourceBytes)
    }

    @Test("current lyric score uses the ordered line index")
    func indexedLineScoreIsExact() {
        let lines = Self.lines(count: 512)
        for index in lines.indices {
            #expect(SingingPanel.scoreLine(at: index, in: lines) == lines[index])
        }
        #expect(SingingPanel.scoreLine(at: -1, in: lines) == nil)
        #expect(SingingPanel.scoreLine(at: lines.count, in: lines) == nil)
    }

    #if DEBUG
        @Test(
            "current-line lookup stays materially below a full lyric scan",
            .disabled("timing evidence requires an optimised build"))
    #else
        @Test("current-line lookup stays materially below a full lyric scan")
    #endif
    func indexedLineBenchmark() {
        let lines = Self.lines(count: 2_000)
        let repetitions = 20
        var indexedChecksum = 0
        let indexedStarted = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<repetitions {
            for index in lines.indices {
                indexedChecksum += SingingPanel.scoreLine(at: index, in: lines)?.index ?? -1
            }
        }
        let indexedNanoseconds = DispatchTime.now().uptimeNanoseconds - indexedStarted

        var scannedChecksum = 0
        let scannedStarted = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<repetitions {
            for index in lines.indices {
                scannedChecksum += lines.first(where: { $0.index == index })?.index ?? -1
            }
        }
        let scannedNanoseconds = DispatchTime.now().uptimeNanoseconds - scannedStarted

        print(
            "\(lines.count * repetitions) current-line lookups: "
                + "index \(indexedNanoseconds) ns, scan \(scannedNanoseconds) ns, "
                + "speedup \(Double(scannedNanoseconds) / Double(indexedNanoseconds))x")
        #expect(indexedChecksum == scannedChecksum)
        #expect(scannedNanoseconds > indexedNanoseconds * 10)
    }

    @Test("the moving view avoids synchronous decode and transient row arrays")
    func hotViewStructureIsBounded() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/SingingPanel.swift"),
            encoding: .utf8)
        let resourceSource = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/SongArtworkStore.swift"),
            encoding: .utf8)

        #expect(!source.contains("NSImage(data:"))
        #expect(!source.contains("Data(contentsOf:"))
        #expect(!source.contains("URLSession.shared"))
        #expect(resourceSource.contains("Task.detached(priority: .utility)"))
        #expect(resourceSource.contains("totalCostLimit: 8 * 1_024 * 1_024"))
        #expect(resourceSource.contains("maximumInputBytes = 8 * 1_024 * 1_024"))
        #expect(!source.contains("Array(model.singers.enumerated())"))
        // One reader sizes the track progress and one positions the pitch dot.
        // A third would mean the moving lyric rows had regained layout readers.
        #expect(source.ranges(of: "GeometryReader").count == 2)
    }

    @Test("fast song readings stop at dedicated observation leaves")
    func fastSongReadingsAreIsolated() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/YunAudioApp/SingingPanel.swift"),
            encoding: .utf8)

        #expect(source.contains("SingingNote(model: model)"))
        #expect(source.contains("SongClock(model: model, track: track)"))
        #expect(source.contains("SongProgress(model: model, duration: track.duration)"))
        #expect(source.ranges(of: "BodyCount.tick(\"SingingNote\")").count == 1)
        #expect(source.ranges(of: "BodyCount.tick(\"SongClock\")").count == 1)
        #expect(source.ranges(of: "BodyCount.tick(\"SongProgress\")").count == 1)
    }

    private static func lines(count: Int) -> [KaraokeScore.Line] {
        (0..<count).map { index in
            KaraokeScore.Line(
                index: index,
                time: Double(index) * 3,
                text: "Line \(index)",
                referenceSeconds: 3,
                onPitchSeconds: 2,
                nearPitchSeconds: 0.5,
                percentage: 75)
        }
    }
}
