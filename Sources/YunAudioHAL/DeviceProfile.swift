import CoreAudio
import Foundation

/// What is known about a particular piece of hardware, as data rather than code.
///
/// CoreAudio will say a device has three input channels and nothing about what
/// is on them. For most hardware that is all there is to say; for some it is
/// actively misleading, and the only way to know is that somebody took the
/// device apart and wrote it down.
///
/// That knowledge was compiled in, which meant every new microphone was a code
/// change, a build and a release — for a table of strings. It is a document
/// now: the ones that ship live beside the application, and anything the user
/// drops in their own folder is loaded on top. Adding support for a device
/// somebody else owns costs them a text file and costs this project nothing.
///
/// Deliberately data and not plugins. A profile describes hardware; it does not
/// execute. Loading code from a folder would mean signing, versioning, a
/// stable ABI and a way for a bad plugin to take the audio system down with
/// it — an enormous amount of machinery for something whose actual content is
/// a list of channel names.
public struct DeviceProfile: Codable, Sendable, Equatable {

    /// Matched against the device's model UID and name, case-insensitively.
    /// A substring, so "seiren v3 pro" matches whatever suffix the firmware
    /// appends this month.
    public let match: String
    /// Shown in place of the device's own name when it is set.
    public let displayName: String?
    /// One entry per input channel, in the device's own order.
    public let inputChannels: [Channel]
    /// Notes worth surfacing about the device as a whole.
    public let note: String?

    public struct Channel: Codable, Sendable, Equatable, Hashable {
        public let name: String
        /// One line on why you would pick this one.
        public let detail: String
        /// True for the channel a person almost always wants.
        public var isDefault: Bool = false

        public init(name: String, detail: String, isDefault: Bool = false) {
            self.name = name
            self.detail = detail
            self.isDefault = isDefault
        }

        /// Written out rather than synthesised, because the synthesised one
        /// ignores property defaults: a Swift default value does not make a
        /// key optional to a decoder, it only makes it optional to Swift. The
        /// generated decoder would have demanded `isDefault` on every channel
        /// of every file, which for a format whose entire purpose is that
        /// somebody else can write one by hand is the wrong requirement to
        /// impose silently.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
            isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        }
    }

    public init(
        match: String, displayName: String? = nil, inputChannels: [Channel],
        note: String? = nil
    ) {
        self.match = match
        self.displayName = displayName
        self.inputChannels = inputChannels
        self.note = note
    }

    public func matches(modelUID: String?, name: String) -> Bool {
        let haystack = "\(modelUID ?? "") \(name)".lowercased()
        return haystack.contains(match.lowercased())
    }
}

/// Every profile the application knows about.
public struct DeviceProfileLibrary: Sendable {
    static let maximumDirectoryEntries = 1_024
    static let maximumProfiles = 256
    static let maximumProfileBytes = 64 * 1_024
    static let maximumChannelsPerProfile = 64
    static let maximumIdentityCharacters = 256
    static let maximumDetailCharacters = 2_048

    public private(set) var profiles: [DeviceProfile]

    public init(profiles: [DeviceProfile]) {
        // Keep the later entries because user profiles intentionally follow
        // bundled ones and win an equal-specificity match.
        self.profiles = Array(
            profiles.lazy.filter(Self.admits).suffix(Self.maximumProfiles))
    }

    private static func admits(_ profile: DeviceProfile) -> Bool {
        !profile.match.isEmpty
            && profile.match.count <= maximumIdentityCharacters
            && (profile.displayName?.count ?? 0) <= maximumIdentityCharacters
            && (profile.note?.count ?? 0) <= maximumDetailCharacters
            && profile.inputChannels.count <= maximumChannelsPerProfile
            && profile.inputChannels.allSatisfy {
                !$0.name.isEmpty
                    && $0.name.count <= maximumIdentityCharacters
                    && $0.detail.count <= maximumDetailCharacters
            }
    }

    /// The best match for a device, or nil when nothing is known about it.
    ///
    /// Longest match wins. A profile for "seiren v3 pro" has to beat one for
    /// "seiren", or adding a general entry would silently take over from every
    /// specific one already in the folder. At equal specificity, later wins:
    /// `standard` appends user profiles after bundled ones so a local correction
    /// can replace a shipped profile without inventing a longer false match.
    public func profile(modelUID: String?, name: String) -> DeviceProfile? {
        profiles
            .enumerated()
            .filter { $0.element.matches(modelUID: modelUID, name: name) }
            .max { lhs, rhs in
                if lhs.element.match.count != rhs.element.match.count {
                    return lhs.element.match.count < rhs.element.match.count
                }
                return lhs.offset < rhs.offset
            }?
            .element
    }

    /// Loads every `.json` in a folder, skipping anything that will not parse.
    ///
    /// A malformed file is skipped rather than fatal: these come from outside,
    /// and one bad file in a folder must not stop the application knowing about
    /// the rest — nor stop it starting at all.
    public static func load(from directory: URL) -> ([DeviceProfile], [String]) {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return ([], []) }

        var entries: [URL] = []
        var inspected = 0
        while let entry = enumerator.nextObject() as? URL,
            inspected < maximumDirectoryEntries
        {
            inspected += 1
            guard entry.pathExtension.lowercased() == "json" else { continue }
            entries.append(entry)
            if entries.count == maximumProfiles { break }
        }

        var loaded: [DeviceProfile] = []
        var problems: [String] = []
        let decoder = JSONDecoder()
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let values = try? entry.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true,
                let handle = try? FileHandle(forReadingFrom: entry)
            else {
                problems.append("\(entry.lastPathComponent): could not be read")
                continue
            }
            let data = try? handle.read(upToCount: maximumProfileBytes + 1)
            try? handle.close()
            guard let data else {
                problems.append("\(entry.lastPathComponent): could not be read")
                continue
            }
            guard data.count <= maximumProfileBytes else {
                problems.append("\(entry.lastPathComponent): profile is too large")
                continue
            }
            do {
                let profile = try decoder.decode(DeviceProfile.self, from: data)
                guard admits(profile) else {
                    problems.append("\(entry.lastPathComponent): profile exceeds safe limits")
                    continue
                }
                loaded.append(profile)
            } catch {
                problems.append("\(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (loaded, problems)
    }

    /// Built-in profiles plus anything in the user's folder, with the user's
    /// taking precedence by virtue of being longer or, at equal length, later.
    public static func standard(
        bundled: URL?, userDirectory: URL?
    ) -> (library: DeviceProfileLibrary, problems: [String]) {
        var all: [DeviceProfile] = []
        var problems: [String] = []
        if let bundled {
            let (loaded, issues) = load(from: bundled)
            all += loaded
            problems += issues
        }
        if let userDirectory {
            let (loaded, issues) = load(from: userDirectory)
            all += loaded
            problems += issues
        }
        return (DeviceProfileLibrary(profiles: all), problems)
    }

    /// Where a user's own profiles go.
    public static var userDirectory: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("YunAudio/Devices", isDirectory: true)
    }
}

extension Bundle {
    /// The module bundle when there is one.
    ///
    /// `Bundle.module` traps when the resource bundle is missing, which is a
    /// hard crash on a shipped application over a table of channel names.
    /// Nothing here is worth that, so it degrades to nil and the built-in
    /// fallback takes over.
    public static var moduleIfPresent: Bundle? {
        let name = "YunAudioKit_YunAudioHAL.bundle"
        let token = Bundle(for: BundleToken.self)
        // Every place the bundle actually turns up: beside the executable in a
        // shipped app, beside the built products under a test runner, and in
        // the build directory during development. The first version of this
        // tried three of them, missed the one a test process uses, and reported
        // no profiles at all — while two tests went on passing because their
        // assertions were also satisfied by the compiled-in fallback.
        let candidates = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.bundleURL.deletingLastPathComponent(),
            Bundle.main.executableURL?.deletingLastPathComponent(),
            token.resourceURL,
            token.bundleURL,
            token.bundleURL.deletingLastPathComponent(),
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if let bundle = Bundle(url: candidate.appendingPathComponent(name)) {
                return bundle
            }
        }
        return nil
    }
}

private final class BundleToken {}
