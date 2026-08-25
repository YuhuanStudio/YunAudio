import CoreAudio
import Foundation

/// Whether the system's audio server is still opening devices.
///
/// There is a state this machine reached on 2026-08-25 that nothing could name.
/// `AudioDeviceCreateIOProcID` sent a mach message to coreaudiod and never
/// returned — in the application, in a fresh launch of it, and in an unrelated
/// command-line tool — while read-only property calls answered instantly the
/// whole time. So the device list looked perfectly healthy, every reading in
/// every interface was correct, and nothing could be opened.
///
/// That combination is the signature, and it is worth stating exactly, because
/// the two halves lead to opposite conclusions. "Core Audio is not answering"
/// suggests a machine under load and invites waiting. "Core Audio is answering
/// questions and not opening devices" is a wedge, and waiting never ends it.
///
/// What ends it is less dramatic than it first appeared. The reproduction was
/// read as a server needing to be restarted, on the strength of a check whose
/// loop had no delay in it and therefore measured nothing at all. Killing the
/// stuck clients cleared it; coreaudiod was never restarted, and three real
/// routes started in under a second each immediately afterwards. So the shape
/// is one wedged client holding the IOProc path against everybody else, and
/// quitting it is the first thing to try.
///
/// ## The probe leaks a thread, on purpose
///
/// A synchronous mach call cannot be cancelled or timed out from outside. The
/// only way to learn that one will not return is to make it and stop waiting,
/// which leaves a thread inside it for as long as the process lives. That is
/// the honest cost of the answer, so: at most one probe per process, ever, and
/// the result is remembered rather than re-measured.
public enum AudioServerHealth {

    public enum Verdict: Sendable, Equatable {
        /// A device was opened and closed inside the budget.
        case healthy
        /// Property reads answer, and opening a device does not return. The
        /// server is wedged; only restarting it clears this.
        case notOpeningDevices
        /// Even a property read did not come back. A machine this far gone
        /// cannot be told apart from one that is merely overwhelmed, and this
        /// says so rather than guessing.
        case notAnswering
        /// Nothing to probe with — no device carrying an output.
        case cannotTell
    }

    /// How long a probe may take before the server is the suspect.
    ///
    /// Opening and closing an IOProc on a healthy machine is a handful of
    /// milliseconds. Three seconds is not a slow open.
    public static let budget: TimeInterval = 3

    private static let lock = NSLock()
    nonisolated(unsafe) private static var remembered: Verdict?
    nonisolated(unsafe) private static var probeIsOutstanding = false

    /// The verdict from this process's one probe, or nil if none has been run.
    public static var lastVerdict: Verdict? { lock.withLock { remembered } }

    /// Runs the probe, or returns what the last one found.
    ///
    /// Blocks for at most `budget`. Safe to call from any thread that can
    /// afford that; never from an IO callback.
    @discardableResult
    public static func check(
        budget: TimeInterval = AudioServerHealth.budget,
        readProperty: @escaping @Sendable () -> Bool = { defaultOutputAnswers() },
        openAndClose: @escaping @Sendable () -> Bool = { openAndCloseAnIOProc() }
    ) -> Verdict {
        if let remembered = lock.withLock({ remembered }) { return remembered }

        let alreadyProbing = lock.withLock {
            defer { probeIsOutstanding = true }
            return probeIsOutstanding
        }
        // One probe per process. A second would add a second stuck thread and
        // learn nothing the first has not already established.
        guard !alreadyProbing else { return lock.withLock { remembered } ?? .cannotTell }

        return record(
            probe(budget: budget, readProperty: readProperty, openAndClose: openAndClose))
    }

    /// The measurement itself, remembering nothing.
    ///
    /// Separate from `check` because the remembering is the product's rule —
    /// one stuck thread per process is the price of one answer — and it makes
    /// the verdicts impossible to exercise: the first case recorded would be
    /// returned for every case after it.
    public static func probe(
        budget: TimeInterval = AudioServerHealth.budget,
        readProperty: @escaping @Sendable () -> Bool = { defaultOutputAnswers() },
        openAndClose: @escaping @Sendable () -> Bool = { openAndCloseAnIOProc() }
    ) -> Verdict {
        // The read first, and inside its own budget. If this does not come
        // back either, the two cases are indistinguishable and saying so is
        // more use than choosing one.
        guard runBounded(budget, readProperty) == true else { return .notAnswering }
        switch runBounded(budget, openAndClose) {
        case .some(true): return .healthy
        case .some(false): return .cannotTell
        case nil: return .notOpeningDevices
        }
    }

    /// Runs `work` on a detached thread and waits at most `budget` for it.
    ///
    /// Nil means it did not return in time — and, for the call this exists for,
    /// that it never will.
    private static func runBounded(
        _ budget: TimeInterval, _ work: @escaping @Sendable () -> Bool
    ) -> Bool? {
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        let thread = Thread {
            let answer = work()
            box.set(answer)
            done.signal()
        }
        thread.name = "com.yuhuanstudio.yunaudio.audio-server-probe"
        thread.start()
        guard done.wait(timeout: .now() + budget) == .success else { return nil }
        return box.value
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        func set(_ value: Bool) { lock.withLock { stored = value } }
        var value: Bool { lock.withLock { stored } }
    }

    private static func record(_ verdict: Verdict) -> Verdict {
        lock.withLock { remembered = verdict }
        return verdict
    }

    /// The same question about one named device.
    ///
    /// Not remembered and not counted against the one-probe rule: this is the
    /// deliberate sweep, and its whole purpose is to find out *which* endpoint
    /// does not come back. Each one that does not leaves a thread behind, which
    /// is why it belongs in a command somebody ran on purpose rather than in
    /// anything the application does by itself.
    public static func probeOne(
        device: AudioObjectID, budget: TimeInterval = AudioServerHealth.budget
    ) -> Verdict {
        switch runBounded(budget, { openAndClose(device) }) {
        case .some(true): return .healthy
        case .some(false): return .cannotTell
        case nil: return .notOpeningDevices
        }
    }

    /// A read-only property call: the cheapest question the server answers.
    public static func defaultOutputAnswers() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0
    }

    /// Creates and destroys an IOProc on one device.
    ///
    /// Never started, so nothing is heard either way — the question is only
    /// whether `AudioDeviceCreateIOProcID` comes back, and it is that call, not
    /// starting, which tells the server about stream usage and waits for it.
    public static func openAndClose(_ device: AudioObjectID) -> Bool {
        var procID: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(
            &procID, device, nil, { _, _, _, _, _ in })
        guard created == noErr, let procID else { return false }
        AudioDeviceDestroyIOProcID(device, procID)
        return true
    }

    /// The call that wedges: creating an IOProc, which tells the server about
    /// stream usage and waits for it.
    public static func openAndCloseAnIOProc() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
                == noErr, device != 0
        else { return false }

        return openAndClose(device)
    }
}
