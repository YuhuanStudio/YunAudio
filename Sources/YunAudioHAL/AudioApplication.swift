import AppKit
import CoreAudio
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
    public let bundleID: String
    public let name: String
    /// Where the application lives, so its icon can be drawn. Absent for
    /// daemons, which have no bundle to draw from.
    public let bundleURL: URL?
    /// True when any member process is producing audio right now.
    public let isPlaying: Bool
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

    /// The process list, grouped by application.
    ///
    /// Ordering is what makes this useful: playing first, then foreground, then
    /// name. Whatever is making noise right now is almost always what the user
    /// came here to capture.
    public static func grouped() throws -> [AudioApplication] {
        let processes = try AudioProcesses.all(includingSilent: true)
        let apps = runningApplications(foregroundOnly: true)
        // Accessory processes are not allowed to own a group, but they still
        // have a name and an icon worth showing — Siri and Control Centre are
        // recognisable, `com.apple.Siri` is not.
        let named = runningApplications(foregroundOnly: false)

        // Longest match wins so `com.hnc.Discord.helper.Renderer` folds into
        // `com.hnc.Discord` and not into some shorter accidental prefix.
        let identifiers = apps.keys.sorted { $0.count > $1.count }

        var groups: [String: [AudioProcess]] = [:]
        for process in processes {
            // Capture is keyed on the bundle identifier, so a process without
            // one cannot be captured at all — an empty key would prefix-match
            // every application on the machine. Three of these exist on a
            // running Mac and none can be named; they are dropped rather than
            // offered as "PID 638" and then failing to work.
            guard let bundle = process.bundleID, !bundle.isEmpty else { continue }
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
                return AudioApplication(
                    bundleID: bundleID,
                    name: application?.localizedName
                        ?? members.first { $0.bundleID == bundleID }?.name
                        ?? members[0].name,
                    bundleURL: application?.bundleURL,
                    isPlaying: isPlaying,
                    processIDs: members.map(\.id),
                    isBackground: apps[bundleID] == nil)
            }
            .sorted { lhs, rhs in
                if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
                if lhs.isBackground != rhs.isBackground { return rhs.isBackground }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
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
    ) -> [String: NSRunningApplication] {
        var result: [String: NSRunningApplication] = [:]
        for application in NSWorkspace.shared.runningApplications
        where !foregroundOnly || application.activationPolicy == .regular {
            guard let bundle = application.bundleIdentifier else { continue }
            result[bundle] = application
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
