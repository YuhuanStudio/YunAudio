import Foundation

/// Finds the resource bundle without going through `Bundle.module`.
///
/// SwiftPM's generated accessor looks beside the executable and next to
/// `Bundle.main.bundleURL` — which for an application means the `.app`'s own
/// root, not `Contents/Resources` where a resource belongs. When it finds
/// nothing it does not fall back: it traps. And in development it *does* find
/// something, because one of the paths it tries is the build directory.
///
/// So the app ran perfectly on the machine that built it and would have died on
/// launch on every other one, with `could not load resource bundle`. Nothing
/// short of moving the bundle away from the build tree could show that, which
/// is what `App/build-app.sh --verify` now does.
///
/// Resolving it by hand keeps the bundle in the conventional place and removes
/// the trap.
enum AppResources {
    private static let name = "YunAudioKit_YunAudioApp.bundle"

    static let bundle: Bundle = {
        let candidates = [
            // Where `build-app.sh` puts it, and where a resource belongs.
            Bundle.main.resourceURL,
            // Where SwiftPM's own accessor looks.
            Bundle.main.bundleURL,
            Bundle.main.bundleURL.deletingLastPathComponent(),
        ]
        for candidate in candidates.compactMap({ $0 }) {
            let url = candidate.appendingPathComponent(name)
            if let bundle = Bundle(url: url) { return bundle }
        }
        // Running from the build directory, where SwiftPM's accessor works and
        // this one has nothing to go on.
        return Bundle.module
    }()
}
