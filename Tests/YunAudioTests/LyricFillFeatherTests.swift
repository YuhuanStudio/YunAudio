import CoreGraphics
import Foundation
import Testing

@testable import YunAudioApp

/// The soft edge the karaoke sweep is lit through.
@Suite("Lyric fill feather")
struct LyricFillFeatherTests {

    /// Alpha of every column, left to right, from the mask image itself.
    @MainActor private func alphas(feather: CGFloat, mirrored: Bool) throws -> [Int] {
        let image = try #require(
            LyricFillFeather.image(feather: feather, mirrored: mirrored))
        let data = try #require(image.dataProvider?.data as Data?)
        // Premultiplied RGBA, one row: the alpha is every fourth byte.
        return stride(from: 3, to: data.count, by: 4).map { Int(data[$0]) }
    }

    @Test("the fade is a fraction of a letter, at any size the stage picks")
    func widthStaysProportional() {
        // A letter at 72 points is about 40 wide, so 30 is most of one and the
        // clamp is what stops the fade swallowing a whole character on a wall.
        #expect(LyricFillFeather.width(forPointSize: 72) == 30)
        #expect(LyricFillFeather.width(forPointSize: 27) == 11)
        // Below ten points a fade is a fringe, above forty-six it stops saying
        // which character is being sung.
        #expect(LyricFillFeather.width(forPointSize: 9) == 10)
        #expect(LyricFillFeather.width(forPointSize: 400) == 46)
    }

    @Test("the mask is opaque behind the sweep and clear ahead of it")
    @MainActor
    func fadeRunsTheRightWay() throws {
        let alphas = try alphas(feather: 16, mirrored: false)
        #expect(alphas.count == LyricFillFeather.columns(feather: 16))
        #expect(alphas.first == 255)
        // Clear at the leading edge, which is the whole point: the glyph the
        // sweep has not reached yet is not lit at all.
        #expect(alphas.last! <= 16)
        // Monotonic, so the fade never brightens again on its way out.
        #expect(zip(alphas, alphas.dropFirst()).allSatisfy { $0 >= $1 })
        // And it really fades rather than stepping: the middle is neither end.
        let middle = alphas[alphas.count / 2]
        #expect(middle > 40 && middle < 215)
    }

    @Test("a right-to-left row fades the other way")
    @MainActor
    func mirroredIsReversed() throws {
        let mirrored = try alphas(feather: 16, mirrored: true)
        #expect(mirrored.last == 255)
        #expect(mirrored.first! <= 16)
        // The same fade, read backwards — not a second gradient with its own
        // shape, which is how the two directions drift apart. Compared within
        // one step of 255 rather than byte for byte: CoreGraphics rasterises
        // the two directions independently, and 89 against 90 in the middle of
        // a ramp is its rounding, not a difference anybody can see.
        let plain = try alphas(feather: 16, mirrored: false)
        let difference = zip(mirrored, plain.reversed()).map { abs($0 - $1) }.max()
        #expect(difference != nil && difference! <= 2)
    }

    @Test("only the solid column stretches")
    func stretchableRegionIsOneColumn() {
        let columns = CGFloat(LyricFillFeather.columns(feather: 16))
        let plain = LyricFillFeather.stretchableRegion(feather: 16, mirrored: false)
        #expect(plain.minX == 0)
        #expect(abs(plain.width - 1 / columns) < 1e-9)
        // At the trailing end for a row read the other way, because that is
        // where the solid column is.
        let mirrored = LyricFillFeather.stretchableRegion(feather: 16, mirrored: true)
        #expect(abs(mirrored.maxX - 1) < 1e-9)
        #expect(abs(mirrored.width - plain.width) < 1e-9)
        // Full height either way: nothing about the fade varies vertically.
        #expect(plain.height == 1 && mirrored.height == 1)
    }

    @Test("the image is built once per size")
    @MainActor
    func imagesAreCached() throws {
        let first = try #require(LyricFillFeather.image(feather: 23, mirrored: false))
        let again = try #require(LyricFillFeather.image(feather: 23, mirrored: false))
        // A bitmap and a gradient per line of every song is what this avoids;
        // identity is the only evidence that the cache is the thing answering.
        #expect(first === again)
        let other = try #require(LyricFillFeather.image(feather: 23, mirrored: true))
        #expect(first !== other)
    }
}
