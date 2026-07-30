import Foundation
import YunAudioEngine
import YunAudioHAL

/// The whole machine's audio arrangement, remembered under a name.
///
/// Distinct from a scene preset, and the difference is the point. A preset says
/// *how to process* — isolation, buffer size, channel mode — and deliberately
/// leaves devices alone, because those are what you route rather than how. This
/// says what everything is plugged into: which devices the system itself is
/// pointed at, which ones this router is using, what it is capturing, and
/// whether it is running at all.
///
/// The two are wanted at different moments. A preset changes when the room
/// changes; this changes when the *work* changes — a podcast, a game, a call —
/// and each of those is a different set of devices, not a different compressor
/// setting.
struct QuickConfig: Codable, Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String

    /// What the Sound pane is pointed at. Stored because half of setting up for
    /// a call is telling macOS itself where to listen, and forgetting that step
    /// is why somebody's first minute is always spent on "you're on mute".
    var systemInputUID: String?
    var systemOutputUID: String?

    /// What this router is using.
    var sourceUID: String?
    var destinationUID: String?
    var monitorUID: String?

    var capturedAppBundleIDs: [String]
    /// Whether the route was up when the snapshot was taken.
    var isRouting: Bool

    /// What was missing when a configuration was applied.
    ///
    /// Applying is best-effort by design: restoring a podcast setup on a laptop
    /// with the interface at home should put back everything it can and say
    /// what it could not, rather than refusing because one device is absent.
    struct Outcome: Equatable, Sendable {
        var restored: Int
        var missing: [String]
        var isComplete: Bool { missing.isEmpty }
    }
}

extension RouterModel {

    /// Takes a snapshot of everything as it stands.
    func captureQuickConfig(named name: String) -> QuickConfig {
        QuickConfig(
            name: name,
            systemInputUID: (try? AudioDevices.defaultInput())??.uid,
            systemOutputUID: (try? AudioDevices.defaultOutput())??.uid,
            sourceUID: selectedSourceUID,
            destinationUID: selectedDestinationUID,
            monitorUID: monitorDeviceUID,
            capturedAppBundleIDs: Array(capturedAppBundleIDs).sorted(),
            isRouting: isRunning)
    }

    func saveQuickConfig(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let captured = captureQuickConfig(named: trimmed)
        var configurations = quickConfigs.filter { $0.name != trimmed }
        configurations.append(captured)
        quickConfigs = configurations.sorted { $0.name < $1.name }
    }

    func deleteQuickConfig(named name: String) {
        quickConfigs.removeAll { $0.name == name }
    }

    /// Puts the machine back the way it was.
    ///
    /// - Returns: What was restored and what was not, so the interface can say
    ///   "everything except the interface" instead of failing silently or
    ///   pretending it worked.
    @discardableResult
    func apply(_ configuration: QuickConfig) -> QuickConfig.Outcome {
        var restored = 0
        var missing: [String] = []

        // Everything the router owns is set in one batch: each of these
        // restarts the route on its own, and applying a configuration used to
        // tear the audio down and build it back four times for one click.
        batched {
            for (uid, isInput) in [
                (configuration.sourceUID, true), (configuration.destinationUID, false),
            ] {
                guard let uid else { continue }
                let devices = isInput ? inputDevices : outputDevices
                guard let device = devices.first(where: { $0.uid == uid }) else {
                    missing.append(uid)
                    continue
                }
                _ = device
                if isInput {
                    selectedSourceUID = uid
                    if selectedSourceUID == uid { restored += 1 }
                } else {
                    selectedDestinationUID = uid
                    if selectedDestinationUID == uid { restored += 1 }
                }
            }

            // The monitor is allowed to be absent without complaint: it is the
            // one device somebody deliberately unplugs — headphones — and
            // reporting it missing every time would train them to ignore the
            // report.
            if let monitor = configuration.monitorUID {
                monitorDeviceUID = outputDevices.contains { $0.uid == monitor } ? monitor : nil
            } else {
                monitorDeviceUID = nil
            }

            // Anything on the never-capture list stays off it. A configuration
            // saved before something was excluded must not bring it back.
            let wanted = Set(configuration.capturedAppBundleIDs)
                .subtracting(excludedAppBundleIDs)
            capturedAppBundleIDs = wanted
        }

        for (uid, isInput) in [
            (configuration.systemInputUID, true), (configuration.systemOutputUID, false),
        ] {
            guard let uid else { continue }
            if (try? AudioDevices.setDefault(uid, forInput: isInput)) == true {
                restored += 1
            } else {
                missing.append(uid)
            }
        }

        // Last, because starting a route with the devices half set would build
        // an aggregate around whatever was selected a moment ago.
        if configuration.isRouting, !isRunning {
            start()
        } else if !configuration.isRouting, isRunning {
            stop()
        }

        return QuickConfig.Outcome(restored: restored, missing: missing)
    }

    /// Names devices that are not here, so the report reads as English rather
    /// than as a list of UIDs.
    func describeMissing(_ uids: [String]) -> String {
        uids.map { uid in
            (inputDevices + outputDevices).first { $0.uid == uid }?.name ?? uid
        }.joined(separator: ", ")
    }
}

@MainActor
enum QuickConfigStore {
    private static let key = "com.yuhuanstudio.yunaudio.quickConfigs"

    static func load() -> [QuickConfig] {
        guard let data = UserDefaults.standard.data(forKey: key),
            let saved = try? JSONDecoder().decode([QuickConfig].self, from: data)
        else { return [] }
        return saved
    }

    static func save(_ configurations: [QuickConfig]) {
        guard let data = try? JSONEncoder().encode(configurations) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
