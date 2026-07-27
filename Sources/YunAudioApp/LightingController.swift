import Foundation
import Observation
import YunDesign
import YunAudioRazer

/// What the microphone's light ring shows.
public enum LightingMode: String, CaseIterable, Identifiable, Sendable {
    case off
    /// One colour, held.
    case solid
    /// The ring fills with the input level, and goes red when muted.
    case level
    /// A hue circle turning around the ring.
    case spectrum

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: loc("Off")
        case .solid: loc("Solid")
        case .level: loc("Level")
        case .spectrum: loc("Spectrum")
        }
    }
}

/// Drives the Seiren's light ring from what the router is doing.
///
/// The capture that produced the protocol also established that the device has
/// no effects of its own: Synapse computes every animation on the PC and pushes
/// frames. That is usually bad news and here it is the opposite — it means the
/// ring is a twelve-pixel display this application already has something to put
/// on. A microphone whose ring shows its own level, and turns red the moment it
/// is muted, is the thing the hardware was always able to do and no software on
/// this platform asked it to.
///
/// Frames go out on a background thread. `IOHIDDeviceSetReport` is a
/// synchronous round trip to the device, and thirty of those a second on the
/// main actor would show up as a stuttering interface.
@MainActor
@Observable
final class LightingController {
    /// True when a device that speaks this protocol is present.
    private(set) var isAvailable = false
    /// Set when a write failed, so the interface can stop claiming it works.
    private(set) var lastError: String?

    var mode: LightingMode = .off {
        didSet {
            guard oldValue != mode else { return }
            renderMode = mode
            restart()
        }
    }
    /// The colour used by `.solid`, and the lit colour used by `.level`.
    var colour: (r: UInt8, g: UInt8, b: UInt8) = (0, 120, 255) {
        didSet {
            renderColour = colour
            if mode == .solid { restart() }
        }
    }
    var brightness: UInt8 = 255 {
        didSet { if oldValue != brightness { applyBrightness() } }
    }

    /// Read on the render thread; written on the main actor. A torn float here
    /// would cost one frame of one LED, which is not worth a lock.
    /// Mirrors of the settings above, for the render thread.
    ///
    /// It cannot reach the main actor to read them. Hopping would mean waiting
    /// on the main queue thirty times a second, and `assumeIsolated` from a
    /// thread that is not the main actor is not an assertion that can be made —
    /// it traps, which is exactly how the first version of this died.
    nonisolated(unsafe) private var level: Float = 0
    nonisolated(unsafe) private var isMuted = false
    /// Which render thread is the current one.
    ///
    /// A single boolean was not enough: `restart` cleared it and set it again,
    /// so a thread that had not yet noticed the clear carried on and two
    /// threads wrote frames at once. Each thread keeps the generation it was
    /// started with and stops as soon as that stops being the current one.
    nonisolated(unsafe) private var generation = 0
    nonisolated(unsafe) private var renderMode: LightingMode = .off
    nonisolated(unsafe) private var renderColour: (r: UInt8, g: UInt8, b: UInt8) =
        (0, 120, 255)

    private var device: RazerDevice?
    private var thread: Thread?

    /// One owner of the device at a time.
    ///
    /// `IOHIDDeviceOpen` fails while somebody else holds the device open, so a
    /// mode change that sent its setup while the outgoing render thread was
    /// mid-frame came back `couldNotOpen` and the interface reported an error
    /// for a ring that was working. Contention is one HID round trip, about a
    /// millisecond, and nothing here is realtime.
    private let deviceLock = NSLock()

    init() { refreshDevice() }

    func refreshDevice() {
        device = RazerDevice.discover().first
        isAvailable = device != nil
    }

    /// Called from the router's poll, so the ring follows the same numbers the
    /// meters do.
    func update(level: Float, isMuted: Bool) {
        self.level = level
        self.isMuted = isMuted
    }

    func stop() {
        generation &+= 1
        thread = nil
        guard let device else { return }
        // Left dark rather than holding the last frame: a ring stuck on a
        // colour after the application quit would look like a fault.
        deviceLock.lock()
        defer { deviceLock.unlock() }
        _ = try? device.send(RazerLightingCommand.brightness(0))
    }

    private func applyBrightness() {
        guard let device, mode != .off else { return }
        deviceLock.lock()
        defer { deviceLock.unlock() }
        _ = try? device.send(RazerLightingCommand.brightness(brightness))
    }

    private func restart() {
        generation &+= 1
        thread = nil
        guard let device else { return }

        deviceLock.lock()
        defer { deviceLock.unlock() }

        guard mode != .off else {
            _ = try? device.send(RazerLightingCommand.brightness(0))
            return
        }

        do {
            _ = try device.send(RazerLightingCommand.streamMode())
            _ = try device.send(RazerLightingCommand.brightness(brightness))
            lastError = nil
        } catch {
            lastError = String(describing: error)
            return
        }

        let mine = generation
        let thread = Thread { [weak self] in self?.render(device: device, generation: mine) }
        thread.name = "com.yuhuanstudio.yunaudio.lighting"
        // Below the audio threads and above nothing: a late frame is a late
        // frame, and this must never compete with the IO cycle.
        thread.qualityOfService = .utility
        thread.start()
        self.thread = thread
    }

    /// The render loop. Runs off the main actor and touches only the two
    /// scalars above.
    nonisolated private func render(device: RazerDevice, generation mine: Int) {
        let count = RazerLightingCommand.ledCount
        var step = 0
        // The ring's own smoothing. The meters fall at 20 dB a second, which is
        // right for reading a number and too fast for something in peripheral
        // vision — it reads as flicker.
        var smoothed: Float = 0

        while generation == mine {
            let target = level
            smoothed = target > smoothed ? target : smoothed * 0.88 + target * 0.12

            let colours = Self.frame(
                mode: renderMode, colour: renderColour, level: smoothed,
                isMuted: isMuted, step: step)

            let frame = RazerLightingCommand.frame(
                colours, transactionID: UInt8(step % 0x1F))
            deviceLock.lock()
            _ = try? device.send(frame)
            deviceLock.unlock()
            step &+= 1
            Thread.sleep(forTimeInterval: 1.0 / 30)
        }
    }

    /// The frame the device is currently holding, read back off it.
    ///
    /// Used to check that the ring is following the signal rather than assuming
    /// it: the device keeps the last frame it was given, so two reads a moment
    /// apart say whether anything is moving.
    func currentFrame() -> [UInt8]? {
        guard let device else { return nil }
        // 64 including the report id, as the frame is written.
        deviceLock.lock()
        defer { deviceLock.unlock() }
        guard let bytes = try? device.readFeatureReport(id: 0x07, size: 63),
            bytes.count >= 50
        else { return nil }
        // The device returns the report id as byte 0, so the buffer it hands
        // back has the same layout as the one that was written: nine bytes of
        // header, then the five-byte prefix, then the twelve triples at 14.
        return Array(bytes[14..<50])
    }

    /// Dispatches to the ring renderer, which lives beside the protocol
    /// because the ring's geometry is device knowledge.
    nonisolated static func frame(
        mode: LightingMode, colour: RazerRing.Colour,
        level: Float, isMuted: Bool, step: Int
    ) -> [RazerRing.Colour] {
        switch mode {
        case .off: RazerRing.solid(RazerRing.dark)
        case .solid: RazerRing.solid(colour)
        case .level: RazerRing.level(level, colour: colour, isMuted: isMuted)
        case .spectrum: RazerRing.spectrum(step: step)
        }
    }
}
