import Foundation
import YunAudioHAL

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

/// Proves the assembled application is using only resources inside its bundle.
///
/// This deliberately constructs no `RouterModel`: checking whether an app can
/// be shipped must not enumerate a microphone, start CoreAudio or inherit the
/// failure state of somebody's audio server. The build script runs this after
/// moving `.build` out of reach, so a generated `Bundle.module` accessor cannot
/// rescue a resource that was never copied into the application.
enum BundleSmokeCheck {
    private static let languages = ["en", "zh-Hans", "zh-Hant"]

    static func run() -> Bool {
        var failures: [String] = []
        guard let resourceRoot = Bundle.main.resourceURL?.resolvingSymlinksInPath() else {
            report(["the application has no resource directory"])
            return false
        }

        func require(_ condition: @autoclosure () -> Bool, _ failure: String) {
            if !condition() { failures.append(failure) }
        }

        let applicationResources = AppResources.bundle
        require(
            isInsideApplication(applicationResources.bundleURL, root: resourceRoot),
            "the application resource bundle resolved outside the application")
        require(
            applicationResources.url(forResource: "Icon", withExtension: "png") != nil,
            "the source artwork is missing")

        let localisations = languages.map {
            ($0, table(named: "Localizable", language: $0, in: applicationResources))
        }
        for (language, table) in localisations {
            require(table?.isEmpty == false, "the \(language) string table did not load")
        }
        let localisationKeys = localisations.compactMap { $0.1.map { Set($0.keys) } }
        if let first = localisationKeys.first {
            require(
                localisationKeys.count == languages.count
                    && localisationKeys.allSatisfy { $0 == first },
                "the three string tables do not carry the same keys")
        }

        let infoTables = languages.map {
            ($0, table(named: "InfoPlist", language: $0, in: .main))
        }
        for (language, table) in infoTables {
            require(table?.isEmpty == false, "the \(language) permission strings did not load")
        }
        let requiredPermissionKeys: Set<String> = [
            "NSAudioCaptureUsageDescription",
            "NSAppleEventsUsageDescription",
            "NSMicrophoneUsageDescription",
        ]
        let infoKeys = infoTables.compactMap { $0.1.map { Set($0.keys) } }
        if let first = infoKeys.first {
            require(
                infoKeys.count == languages.count && infoKeys.allSatisfy { $0 == first },
                "the three permission string tables do not carry the same keys")
            require(
                requiredPermissionKeys.isSubset(of: first),
                "a required permission description is missing")
        }

        guard let halBundle = Bundle.moduleIfPresent else {
            failures.append("the HAL resource bundle did not load")
            report(failures)
            return false
        }
        require(
            isInsideApplication(halBundle.bundleURL, root: resourceRoot),
            "the HAL resource bundle resolved outside the application")
        let bundledDevices = halBundle.url(forResource: "Devices", withExtension: nil)
        let deviceProfiles = DeviceProfileLibrary.standard(
            bundled: bundledDevices, userDirectory: nil)
        require(!deviceProfiles.library.profiles.isEmpty, "no bundled device profile loaded")
        require(deviceProfiles.problems.isEmpty, "a bundled device profile did not parse")

        let engineURL = resourceRoot.appendingPathComponent(
            "YunAudioKit_YunAudioEngine.bundle", isDirectory: true)
        guard let engineBundle = Bundle(url: engineURL) else {
            failures.append("the engine resource bundle did not load")
            report(failures)
            return false
        }
        require(
            engineBundle.url(forResource: "PitchHead", withExtension: "mlpackage") != nil,
            "the learned pitch model is missing")

        guard failures.isEmpty else {
            report(failures)
            return false
        }
        let keyCount = localisationKeys.first?.count ?? 0
        print(
            "bundle check: 3 module bundles, \(languages.count) languages, "
                + "\(keyCount) keys, \(deviceProfiles.library.profiles.count) device profiles")
        return true
    }

    private static func isInsideApplication(_ url: URL, root: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func table(
        named name: String, language: String, in bundle: Bundle
    ) -> [String: String]? {
        let roots = [bundle.resourceURL, bundle.bundleURL]
            .compactMap { $0?.standardizedFileURL }
        for root in roots {
            guard
                let entries = try? FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: nil),
                let languageDirectory = entries.first(where: {
                    $0.lastPathComponent.caseInsensitiveCompare("\(language).lproj")
                        == .orderedSame
                })
            else { continue }
            let url = languageDirectory.appendingPathComponent("\(name).strings")
            guard
                let data = try? Data(contentsOf: url),
                let values = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil) as? [String: String]
            else { continue }
            return values
        }
        return nil
    }

    private static func report(_ failures: [String]) {
        for failure in failures {
            FileHandle.standardError.write(Data("bundle check: \(failure)\n".utf8))
        }
    }
}
