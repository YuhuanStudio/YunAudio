import AppKit
import CoreAudio
import Foundation

extension AudioProperty {
    public static var processList: AudioProperty<AudioObjectID> {
        .init(kAudioHardwarePropertyProcessObjectList)
    }
    public static var processBundleID: AudioProperty<CFString> {
        .init(kAudioProcessPropertyBundleID)
    }
    public static var processPID: AudioProperty<pid_t> {
        .init(kAudioProcessPropertyPID)
    }
    public static var processIsRunningOutput: AudioProperty<UInt32> {
        .init(kAudioProcessPropertyIsRunningOutput)
    }
    public static var processDevices: AudioProperty<AudioObjectID> {
        .init(kAudioProcessPropertyDevices)
    }
    public static var tapList: AudioProperty<AudioObjectID> {
        .init(kAudioHardwarePropertyTapList)
    }
    public static var tapUID: AudioProperty<CFString> { .init(kAudioTapPropertyUID) }
    public static var tapFormat: AudioProperty<AudioStreamBasicDescription> {
        .init(kAudioTapPropertyFormat)
    }
}

/// An application the HAL knows about, which can therefore be tapped.
public struct AudioProcess: Sendable, Identifiable, Hashable {
    public let id: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    /// True when the process is currently producing audio.
    public let isPlaying: Bool
    /// Display name resolved from the running application list.
    public let name: String

    init?(id: AudioObjectID, names: [pid_t: String]) {
        self.id = id
        guard let pid = id.optionalValue(of: .processPID) else { return nil }
        self.pid = pid
        bundleID = id.optionalString(of: .processBundleID)
        isPlaying = (id.optionalValue(of: .processIsRunningOutput) ?? 0) != 0
        name =
            names[pid]
            ?? bundleID?.split(separator: ".").last.map(String.init)
            ?? "PID \(pid)"
    }
}

/// A live capture of one or more applications' audio.
///
/// Built on `AudioHardwareCreateProcessTap`, which lands the tapped audio on a
/// HAL object that an aggregate device can then include as a sub-device. That
/// is what makes this possible with no driver of our own: Loopback and its peers
/// ship a kernel-adjacent plug-in to intercept application audio, whereas this
/// is a documented API that has existed since macOS 14.2.
public final class ProcessTap {
    public let id: AudioObjectID
    public let uid: String
    /// Format the tap presents. Reported so the aggregate can be built to match.
    public let format: AudioStreamBasicDescription?

    private var isDestroyed = false

    /// - Parameters:
    ///   - processIDs: `AudioObjectID`s of the processes to capture.
    ///   - muteBehavior: Whether the tapped application keeps playing through
    ///     the speakers. `.mutedWhenTapped` is the useful one for streaming: the
    ///     audio reaches the mix without also reaching the room.
    /// - Throws: `ProcessTapError.creationFailed` when CoreAudio refuses, which
    ///   happens when the process has gone away between listing and tapping.
    public init(processIDs: [AudioObjectID], muteBehavior: TapMuteBehavior = .unmuted) throws {
        // NS_REFINED_FOR_SWIFT turns the NSNumber array in the header into a
        // plain [AudioObjectID] on this side.
        let description = CATapDescription(stereoMixdownOfProcesses: processIDs)
        description.name = "YunAudio Tap"
        // Private: the tap belongs to this process and disappears with it,
        // rather than lingering in every other application's device list.
        description.isPrivate = true
        description.muteBehavior = muteBehavior.coreAudioValue

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw ProcessTapError.creationFailed(status)
        }
        id = tapID
        uid = (try? tapID.string(of: .tapUID)) ?? description.uuid.uuidString
        format = tapID.optionalValue(of: .tapFormat)
    }

    deinit { destroy() }

    public func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        AudioHardwareDestroyProcessTap(id)
    }
}

public enum TapMuteBehavior: Sendable, CaseIterable {
    /// The application is captured and still heard.
    case unmuted
    /// The application is captured and silenced.
    case muted
    /// The application is heard until something reads the tap, then silenced —
    /// so it goes quiet exactly while it is being routed somewhere else.
    case mutedWhenTapped

    var coreAudioValue: CATapMuteBehavior {
        switch self {
        case .unmuted: .unmuted
        case .muted: .muted
        case .mutedWhenTapped: .mutedWhenTapped
        }
    }

    public var title: String {
        switch self {
        case .unmuted: "Keep playing"
        case .muted: "Silence the app"
        case .mutedWhenTapped: "Silence while routed"
        }
    }
}

public enum ProcessTapError: Error, CustomStringConvertible {
    case creationFailed(OSStatus)

    public var description: String {
        switch self {
        case let .creationFailed(status):
            "AudioHardwareCreateProcessTap failed with \(fourCharDescription(status))"
        }
    }
}

extension AudioProcess {
    /// Devices this process currently has open, per scope.
    public func devices(scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        let property = AudioProperty<AudioObjectID>.processDevices.scoped(to: scope)
        return (try? id.array(of: property)) ?? []
    }
}

public enum AudioProcesses {
    /// Every process tap currently alive on the system, ours or anyone's.
    ///
    /// A tap that outlives the process that made it keeps duplicating audio,
    /// so this is the first thing to check when something sounds doubled.
    public static func liveTaps() -> [(id: AudioObjectID, uid: String)] {
        let ids = (try? AudioObjectID.system.array(of: .tapList)) ?? []
        return ids.map { ($0, (try? $0.string(of: .tapUID)) ?? "—") }
    }

    /// Every process the HAL is tracking, newest-looking first.
    ///
    /// Processes with no bundle identifier and no audio activity are dropped:
    /// the raw list includes a long tail of system helpers that no one wants to
    /// pick from a menu.
    public static func all(includingSilent: Bool = false) throws -> [AudioProcess] {
        let names = runningApplicationNames()
        let ids = try AudioObjectID.system.array(of: .processList)
        return
            ids
            .compactMap { AudioProcess(id: $0, names: names) }
            .filter { includingSilent || $0.isPlaying || $0.bundleID != nil }
            .sorted { lhs, rhs in
                if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// Maps PIDs to the names a person would recognise.
    ///
    /// An earlier version reached `NSRunningApplication` through KVC to keep
    /// AppKit out of this module. That was wrong twice over:
    /// `runningApplications` is a class method, so the KVC lookup could never
    /// succeed — it failed silently in a command-line context and threw
    /// `NSUnknownKeyException` inside an app. Importing AppKit is the honest
    /// cost of showing "Discord" instead of "Renderer".
    private static func runningApplicationNames() -> [pid_t: String] {
        var result: [pid_t: String] = [:]
        for application in NSWorkspace.shared.runningApplications {
            guard let name = application.localizedName else { continue }
            result[application.processIdentifier] = name
        }
        return result
    }
}
