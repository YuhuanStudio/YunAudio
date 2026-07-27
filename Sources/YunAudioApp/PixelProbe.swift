import CoreGraphics
import Foundation
import ImageIO

/// Reads one pixel out of an encoded image.
///
/// Both verification harnesses need this and both had their own copy: the
/// renderer to check its own pipeline is not altering colour, the window
/// capture to check a shot actually came out in the appearance it claims. Two
/// copies of twenty lines of CGContext arithmetic is two chances to get the
/// row-flip wrong in only one of them.
enum PixelProbe {
    /// - Parameters:
    ///   - png: An encoded image.
    ///   - point: In image pixels, top-left origin.
    /// - Returns: The sampled colour, or nil when the image cannot be decoded.
    static func sample(_ png: Data, at point: CGPoint) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return sample(image, at: point)
    }

    static func sample(
        _ image: CGImage, at point: CGPoint
    ) -> (r: UInt8, g: UInt8, b: UInt8)? {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = bytes.withUnsafeMutableBytes({ raw in
                CGContext(
                    data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            })
        else { return nil }
        // Draw the whole image offset so the wanted pixel lands in the single
        // pixel this context has. CoreGraphics counts rows from the bottom, so
        // the y offset is measured from the far edge.
        context.draw(
            image,
            in: CGRect(
                x: -point.x, y: -(CGFloat(image.height) - point.y - 1),
                width: CGFloat(image.width), height: CGFloat(image.height)))
        return (bytes[0], bytes[1], bytes[2])
    }
}
