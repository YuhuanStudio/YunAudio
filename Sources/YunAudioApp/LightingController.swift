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
    nonisolated(unsafe) private var running = false
    nonisolated(unsafe) private var renderMode: LightingMode = .off
    nonisolated(unsafe) private var renderColour: (r: UInt8, g: UInt8, b: UInt8) =
        (0, 120, 255)

    private var device: RazerDevice?
    private var thread: Thread?

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
        running = false
        thread = nil
        guard let device else { return }
        // Left dark rather than holding the last frame: a ring stuck on a
        // colour after the application quit would look like a fault.
        _ = try? device.send(RazerLightingCommand.brightness(0))
    }

    private func applyBrightness() {
        guard let device, mode != .off else { return }
        _ = try? device.send(RazerLightingCommand.brightness(brightness))
    }

    private func restart() {
        running = false
        thread = nil
        guard let device else { return }

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

        running = true
        let thread = Thread { [weak self] in self?.render(device: device) }
        thread.name = "com.yuhuanstudio.yunaudio.lighting"
        // Below the audio threads and above nothing: a late frame is a late
        // frame, and this must never compete with the IO cycle.
        thread.qualityOfService = .utility
        thread.start()
        self.thread = thread
    }

    /// The render loop. Runs off the main actor and touches only the two
    /// scalars above.
    nonisolated private func render(device: RazerDevice) {
        let count = RazerLightingCommand.ledCount
        var step = 0
        // The ring's own smoothing. The meters fall at 20 dB a second, which is
        // right for reading a number and too fast for something in peripheral
        // vision — it reads as flicker.
        var smoothed: Float = 0

        while running {
            let target = level
            smoothed = target > smoothed ? target : smoothed * 0.88 + target * 0.12

            var colours = [(r: UInt8, g: UInt8, b: UInt8)]()
            colours.reserveCapacity(count)

            let colour = renderColour
            switch renderMode {
            case .off:
                colours = Array(repeating: (0, 0, 0), count: count)
            case .solid:
                colours = Array(repeating: colour, count: count)
            case .level:
                if isMuted {
                    colours = Array(repeating: (r: 255, g: 0, b: 0), count: count)
                } else {
                    // Compressed the same way the meters are, so the ring and
                    // the bars agree about what "half" means.
                    let filled = Double(min(1, pow(min(1, smoothed * 4), 0.5)))
                    for index in 0..<count {
                        // By height rather than by index. Index 0 is at six
                        // o'clock and they run clockwise, so filling by index
                        // sweeps round the ring like a chase; filling by height
                        // rises up both sides at once, which is what a level
                        // looks like.
                        let height = RazerLightingCommand.height(ofLED: index)
                        guard height <= filled else {
                            colours.append((0, 0, 0))
                            continue
                        }
                        colours.append(
                            height > 0.92
                                ? (255, 40, 0)
                                : (height > 0.75 ? (255, 170, 0) : colour))
                    }
                }
            case .spectrum:
                for index in 0..<count {
                    let hue =
                        (Double(step) / 90.0 + Double(index) / Double(count))
                        .truncatingRemainder(dividingBy: 1)
                    colours.append(Self.hue(hue))
                }
            }

            let frame = RazerLightingCommand.frame(
                colours, transactionID: UInt8(step % 0x1F))
            _ = try? device.send(frame)
            step &+= 1
            Thread.sleep(forTimeInterval: 1.0 / 30)
        }
    }

    nonisolated private static func hue(_ hue: Double) -> (r: UInt8, g: UInt8, b: UInt8) {
        let sector = hue * 6
        let offset = sector - sector.rounded(.down)
        let rising = UInt8(offset * 255)
        let falling = UInt8((1 - offset) * 255)
        switch Int(sector) % 6 {
        case 0: return (255, rising, 0)
        case 1: return (falling, 255, 0)
        case 2: return (0, 255, rising)
        case 3: return (0, falling, 255)
        case 4: return (rising, 0, 255)
        default: return (255, 0, falling)
        }
    }
}
