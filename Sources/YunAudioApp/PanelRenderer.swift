import AppKit
import SwiftUI

/// Renders the panel to PNGs so its layout and colours can actually be looked
/// at. Reading the view code is not verification.
@MainActor
enum PanelRenderer {
    static func write(to directory: String, model: RouterModel) {
        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .light ? "panel-light.png" : "panel-dark.png"
            // The rendered tree is wrapped in the same background the glass
            // shell sits on, so contrast is judged against a real surface
            // rather than transparency.
            let content = PanelView(model: model)
                .environment(\.colorScheme, scheme)
                .background(scheme == .light
                    ? Color(hex: 0xF2F2F4) : Color(hex: 0x0C0C0E))

            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            // ImageRenderer resolves dynamic NSColor against the process
            // appearance, not the environment, so the appearance is switched
            // for the duration of the render.
            let previous = NSApp?.appearance
            NSApp?.appearance = NSAppearance(
                named: scheme == .light ? .aqua : .darkAqua)
            defer { NSApp?.appearance = previous }

            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else {
                FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
                continue
            }
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            try? png.write(to: url)
            print("wrote \(url.path)")
        }
    }
}

extension Color {
    fileprivate init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}
