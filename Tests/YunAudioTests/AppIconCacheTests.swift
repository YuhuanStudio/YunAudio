import AppKit
import Testing

@testable import YunAudioApp

@MainActor
@Suite("Application icon cache")
struct AppIconCacheTests {
    @Test("restoring and installing the same application icon rasterises it once")
    func repeatedApplicationStyleIsSuppressed() {
        var applied: String?
        var rasterisations = 0

        for requested in ["graphite", "graphite", "paper", "paper", "graphite"] {
            if RouterModel.shouldApplyIconStyle(
                requested, previouslyApplied: applied,
                applicationIsAvailable: true)
            {
                rasterisations += 1
                applied = requested
            }
        }

        #expect(rasterisations == 3)
        #expect(
            !RouterModel.shouldApplyIconStyle(
                "graphite", previouslyApplied: nil,
                applicationIsAvailable: false))
    }

    @Test("full workspace icons become bounded row-sized pixels")
    func fullIconsAreNotRetained() throws {
        let source = try Self.image(pixels: 1_024)
        let cache = AppIconCache()
        var loads = 0

        for index in 0..<(AppIconCache.maximumEntries + 20) {
            let image = cache.image(
                for: URL(fileURLWithPath: "/Applications/App-\(index).app")
            ) { _ in
                loads += 1
                return source
            }
            let representation = try #require(image?.representations.first)
            #expect(representation.pixelsWide == AppIconCache.pixelSize)
            #expect(representation.pixelsHigh == AppIconCache.pixelSize)
        }

        #expect(loads == AppIconCache.maximumEntries + 20)
        #expect(cache.count == AppIconCache.maximumEntries)
        #expect(cache.pixelBytes == AppIconCache.maximumPixelBytes)
        #expect(cache.pixelBytes == 262_144)
    }

    @Test("a cache hit does not ask the workspace again")
    func hitIsReused() throws {
        let source = try Self.image(pixels: 64)
        let cache = AppIconCache()
        let url = URL(fileURLWithPath: "/Applications/One.app")
        var loads = 0

        let first = cache.image(for: url) { _ in
            loads += 1
            return source
        }
        let second = cache.image(for: url) { _ in
            loads += 1
            return source
        }

        #expect(loads == 1)
        #expect(first === second)
        #expect(cache.count == 1)
        #expect(cache.pixelBytes == 4_096)
    }

    private static func image(pixels: Int) throws -> NSImage {
        let representation = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixels,
                pixelsHigh: pixels,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0))
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.addRepresentation(representation)
        return image
    }
}
