import AppKit

/// The application mark, loaded once.
///
/// An accessory application has no Dock icon, so the status item and the window
/// header are the only places the mark is ever seen. Loading it through a single
/// accessor keeps that from being three slightly different lookups, one of which
/// silently returns nil.
enum YunAppIcon {
    static let image: NSImage? = {
        guard let url = Bundle.module.url(forResource: "Icon", withExtension: "png"),
            let loaded = NSImage(contentsOf: url)
        else { return nil }
        // Template rendering is deliberately off: the mark is a gradient, and a
        // template would flatten it to a monochrome silhouette.
        loaded.isTemplate = false
        return loaded
    }()
}
