import AppKit
import CoreAudio
import Darwin
import Foundation

/// One application, as a person thinks of it, rather than as the HAL lists it.
///
/// The raw process list is not a menu anyone would want to pick from. On a
/// quiet machine it holds thirty-five entries, of which four are Discord —
/// `com.hnc.Discord`, `.helper`, `.helper.Renderer`, `.helper.Plugin` — and
/// most of the rest are daemons (`assistantd`, `cloudpaird`, `replayd`) that
/// exist to serve the system and have no audio a user would ever want to
/// capture. Presenting that list unfiltered buries Discord under `audiomxd`.
///
/// So the processes are folded back into the applications that spawned them and
/// marked as foreground or background. Nothing is discarded — the background
/// ones are still offered, just not first.
public struct AudioApplication: Sendable, Identifiable, Hashable {
    /// The base bundle identifier, which is what capture keys on. Every helper
    /// identifier begins with it, which is why prefix matching works.
    ///
    /// For a process that publishes no bundle identifier at all this is a
    /// `pid:` identity instead — see `AudioApplications.identity(forPID:)`.
    public let bundleID: String
    public let name: String
    /// Where the application lives, so its icon can be drawn. Absent for
    /// daemons, which have no bundle to draw from.
    public let bundleURL: URL?
    /// True when any member process is producing audio right now.
    public let isPlaying: Bool
    /// True when any member process has an input open right now.
    ///
    /// The half of "what is using my audio" that macOS shows an orange dot for
    /// and never names. It is also the answer to why a Bluetooth headset has
    /// dropped to telephone quality: something opened its microphone, and until
    /// now there was no way to find out what.
    public let isRecording: Bool
    /// Processes folded into this entry — the objects a tap is built from.
    public let processIDs: [AudioObjectID]
    /// True when the application has no Dock presence: a daemon, an agent, or
    /// a helper whose parent is not running.
    public let isBackground: Bool

    public var id: String { bundleID }

    /// How many processes were folded in. Shown so a four-process application
    /// does not look like it lost three of them.
    public var processCount: Int { processIDs.count }
}

extension AudioApplications {

    /// One process as the grouping needs to see it.
    ///
    /// The grouping rules are the part that gets things wrong, and they used to
    /// be reachable only through a live HAL and a live `NSWorkspace` — so the
    /// only way to find out what they did to a playing process with no bundle
    /// identifier was to play something and look at a menu. Taking data in
    /// instead lets a test state the case and assert the answer.
    public struct ProcessEntry: Sendable, Hashable {
        public let id: AudioObjectID
        public let pid: pid_t
        public let bundleID: String?
        public let name: String
        public let isPlaying: Bool
        /// True when the process has an input open — the microphone.
        public let isRecording: Bool

        public init(
            id: AudioObjectID, pid: pid_t, bundleID: String?, name: String,
            isPlaying: Bool, isRecording: Bool = false
        ) {
            self.id = id
            self.pid = pid
            self.bundleID = bundleID
            self.name = name
            self.isPlaying = isPlaying
            self.isRecording = isRecording
        }
    }

    /// What the running application list contributes to an entry: a name a
    /// person recognises, and a bundle to take an icon from.
    public struct ApplicationInfo: Sendable, Hashable {
        public let name: String
        public let bundleURL: URL?

        public init(name: String, bundleURL: URL? = nil) {
            self.name = name
            self.bundleURL = bundleURL
        }
    }

    /// The identity used for a process that publishes no bundle identifier.
    ///
    /// A tap is built from `AudioObjectID`s, so such a process can be captured
    /// perfectly well; it is only this list that needs something to key on. The
    /// `pid:` prefix is deliberate — no bundle identifier begins with it, so a
    /// synthetic key can never be swallowed by the prefix matching below and
    /// nothing real can be mistaken for one of these.
    public static func identity(forPID pid: pid_t) -> String { "\(pidIdentityPrefix)\(pid)" }

    /// How to recognise one again. A PID means nothing after a restart, so
    /// anything that persists a selection has to be able to tell these apart
    /// from the real identifiers it is safe to remember.
    public static let pidIdentityPrefix = "pid:"

    /// The process list, grouped by application.
    ///
    /// Ordering is what makes this useful: playing first, then foreground, then
    /// name. Whatever is making noise right now is almost always what the user
    /// came here to capture.
    public static func grouped() throws -> [AudioApplication] {
        let processes = try AudioProcesses.all(includingSilent: true).map(entry(for:))
        return group(
            processes: processes,
            foreground: runningApplications(foregroundOnly: true),
            // Accessory processes are not allowed to own a group, but they
            // still have a name and an icon worth showing — Siri and Control
            // Centre are recognisable, `com.apple.Siri` is not.
            named: runningApplications(foregroundOnly: false))
    }

    /// - Parameters:
    ///   - processes: Every process the HAL is tracking, the silent ones
    ///     included.
    ///   - foreground: Applications with a Dock presence, keyed by bundle
    ///     identifier. Only these may head a group.
    ///   - named: Every running application, so an accessory still gets its own
    ///     name and icon.
    /// - Returns: One entry per application, whatever is playing first.
    public static func group(
        processes: [ProcessEntry],
        foreground: [String: ApplicationInfo],
        named: [String: ApplicationInfo]
    ) -> [AudioApplication] {
        // Longest match wins so `com.hnc.Discord.helper.Renderer` folds into
        // `com.hnc.Discord` and not into some shorter accidental prefix.
        let identifiers = foreground.keys.sorted { $0.count > $1.count }

        var groups: [String: [ProcessEntry]] = [:]
        for process in processes {
            guard let bundle = process.bundleID, !bundle.isEmpty else {
                // These used to be dropped outright, on the grounds that
                // capture keys on a bundle identifier. It does not: a tap keys
                // on the HAL object. What the rule actually did was hide
                // whatever was making the noise whenever the noise came from
                // something with no bundle — afplay, ffplay, mpv, a Python
                // script — which is the one case a list of audible applications
                // has to get right. Measured on this machine: two processes
                // playing, one of them listed.
                //
                // The silent ones are still dropped. They are a long tail
                // nobody can name and nobody came here for — but "silent" has
                // to mean using no audio at all, not merely making none.
                // Recording counted as silent, so a process with no bundle
                // holding the microphone was dropped from the one list that
                // exists to say what is using the audio on this machine.
                guard process.isPlaying || process.isRecording else { continue }
                groups[identity(forPID: process.pid), default: []].append(process)
                continue
            }
            let owner =
                identifiers.first { bundle == $0 || bundle.hasPrefix($0 + ".") }
                ?? baseIdentifier(of: bundle)
            groups[owner, default: []].append(process)
        }

        return
            groups
            .compactMap { bundleID, members -> AudioApplication? in
                guard !members.isEmpty else { return nil }
                let application = named[bundleID]
                let isPlaying = members.contains { $0.isPlaying }
                let isRecording = members.contains { $0.isRecording }
                return AudioApplication(
                    bundleID: bundleID,
                    name: application?.name
                        ?? members.first { $0.bundleID == bundleID }?.name
                        ?? members[0].name,
                    bundleURL: application?.bundleURL,
                    isPlaying: isPlaying,
                    isRecording: isRecording,
                    processIDs: members.map(\.id),
                    isBackground: foreground[bundleID] == nil)
            }
            .sorted { lhs, rhs in
                if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
                if lhs.isBackground != rhs.isBackground { return rhs.isBackground }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// Resolves the one thing the HAL will not: a name for a process that has
    /// no bundle, and therefore no `NSRunningApplication` behind it either.
    ///
    /// Kept out of `group(processes:foreground:named:)` so that stays a
    /// function of its arguments. This one asks the kernel about a PID, and a
    /// test that had to hand it real PIDs would be asserting the machine rather
    /// than the rules.
    private static func entry(for process: AudioProcess) -> ProcessEntry {
        var name = process.name
        // Recording counts as well as playing. It did not, and the one place
        // that matters most is a process with no bundle holding the microphone:
        // "PID 47482" is not a row anybody can act on, and it is exactly the
        // row somebody needs when their headset has dropped to call quality and
        // they are trying to find out what did it.
        if process.bundleID?.isEmpty ?? true, process.isPlaying || process.isRecording,
            let executable = executableName(ofPID: process.pid)
        {
            name = executable
        }
        return ProcessEntry(
            id: process.id, pid: process.pid, bundleID: process.bundleID, name: name,
            isPlaying: process.isPlaying, isRecording: process.isRecording)
    }

    /// The last path component of a process's executable, which for a
    /// command-line player is the only name it is ever going to have. "afplay"
    /// is a row somebody can act on; "PID 63311" is not.
    private static func executableName(ofPID pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0 else { return nil }
        let path = String(decoding: buffer[0..<Int(length)], as: UTF8.self)
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// Running applications keyed by bundle identifier.
    ///
    /// `.regular` is the discriminator for ownership: an activation policy of
    /// `.accessory` or `.prohibited` means the process deliberately has no
    /// window and no Dock icon, which is exactly the definition of something
    /// that should not head a list of applications to capture. It is not a
    /// reason to withhold its name.
    private static func runningApplications(
        foregroundOnly: Bool
    ) -> [String: ApplicationInfo] {
        var result: [String: ApplicationInfo] = [:]
        for application in NSWorkspace.shared.runningApplications
        where !foregroundOnly || application.activationPolicy == .regular {
            guard let bundle = application.bundleIdentifier else { continue }
            result[bundle] = ApplicationInfo(
                name: application.localizedName ?? bundle,
                bundleURL: application.bundleURL)
        }
        return result
    }

    /// Trims a helper identifier back to its parent when the parent itself is
    /// not running as a foreground application — Safari's GPU process lives
    /// under `com.apple.WebKit.GPU`, which no `NSRunningApplication` claims.
    private static func baseIdentifier(of bundle: String) -> String {
        let parts = bundle.split(separator: ".")
        guard let helper = parts.firstIndex(where: { $0.lowercased() == "helper" }),
            helper > 0
        else { return bundle }
        return parts[0..<helper].joined(separator: ".")
    }
}

public enum AudioApplications {}
