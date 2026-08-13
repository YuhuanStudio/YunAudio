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

/// The small piece of state shared with the HID render thread.
///
/// A lock is cheap at thirty reads a second, and it makes a generation change
/// an actual handover rather than five unrelated data races. The previous
/// `nonisolated(unsafe)` annotations had no effect on a nonisolated class
/// member; the compiler said so, and the old render thread could consequently
/// miss the generation change and keep writing beside the new one.
final class LightingRenderState: @unchecked Sendable {
    struct Snapshot: Sendable {
        let mode: LightingMode
        let colour: RazerRing.Colour
        let level: Float
        let isMuted: Bool
    }

    private let lock = NSLock()
    private var generation = 0
    private var mode: LightingMode = .off
    private var colour: RazerRing.Colour = (0, 120, 255)
    private var level: Float = 0
    private var isMuted = false

    func update(mode: LightingMode) {
        lock.withLock { self.mode = mode }
    }

    func update(colour: RazerRing.Colour) {
        lock.withLock { self.colour = colour }
    }

    func update(level: Float, isMuted: Bool) {
        lock.withLock {
            self.level = level
            self.isMuted = isMuted
        }
    }

    /// Invalidates the outgoing loop and returns the new loop's identity.
    @discardableResult
    func advanceGeneration() -> Int {
        lock.withLock {
            generation &+= 1
            return generation
        }
    }

    /// One coherent frame, or nil once this loop has been superseded.
    func snapshot(for expectedGeneration: Int) -> Snapshot? {
        lock.withLock {
            guard generation == expectedGeneration else { return nil }
            return Snapshot(mode: mode, colour: colour, level: level, isMuted: isMuted)
        }
    }
}

/// Revokes every normal HID caller before teardown waits for the device lock.
///
/// A generation check made before `deviceLock.lock()` is too early: an outgoing
/// frame can wait there while Quit darkens the ring, then acquire the lock and
/// put the old frame back. `perform` deliberately validates only after taking
/// that lock. A caller already inside a synchronous HID call may finish, but the
/// teardown operation is then ordered behind it and remains the final writer.
final class LightingDeviceAccessGate: @unchecked Sendable {
    struct Token: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var acceptsAccess = true

    /// Supersedes queued work without permanently closing normal operation.
    func advance() -> Token {
        lock.withLock {
            generation &+= 1
            return Token(generation: generation)
        }
    }

    /// Captures the current device ownership epoch for a read-only request.
    func current() -> Token? {
        lock.withLock {
            acceptsAccess ? Token(generation: generation) : nil
        }
    }

    /// Permanently closes access for this controller before teardown admission.
    func revoke() {
        lock.withLock {
            generation &+= 1
            acceptsAccess = false
        }
    }

    /// Runs one normal operation only if its epoch is current after lock acquisition.
    func perform<Result>(
        _ token: Token, deviceLock: NSLock, operation: () -> Result
    ) -> Result? {
        deviceLock.lock()
        defer { deviceLock.unlock() }
        guard accepts(token) else { return nil }
        return operation()
    }

    private func accepts(_ token: Token) -> Bool {
        lock.withLock { acceptsAccess && generation == token.generation }
    }
}

/// Everything one background render loop owns.
///
/// The device itself is not `Sendable`; this box is, because every access to it
/// goes through the shared device lock. Capturing the box rather than the
/// device also gives Swift's `Thread` closure the same ownership model the code
/// actually uses.
private final class LightingRenderWorker: @unchecked Sendable {
    private let device: RazerDevice
    private let deviceLock: NSLock
    private let accessGate: LightingDeviceAccessGate
    private let accessToken: LightingDeviceAccessGate.Token
    private let state: LightingRenderState
    private let generation: Int
    private let frameInterval: TimeInterval

    init(
        device: RazerDevice, deviceLock: NSLock,
        accessGate: LightingDeviceAccessGate,
        accessToken: LightingDeviceAccessGate.Token,
        state: LightingRenderState, generation: Int, frameInterval: TimeInterval
    ) {
        self.device = device
        self.deviceLock = deviceLock
        self.accessGate = accessGate
        self.accessToken = accessToken
        self.state = state
        self.generation = generation
        self.frameInterval = frameInterval
    }

    func run() {
        var step = 0
        var frameGate = LightingFrameGate()
        var retryBackoff = LightingRetryBackoff()
        // The ring's own smoothing. The meters fall at 20 dB a second, which is
        // right for reading a number and too fast for something in peripheral
        // vision — it reads as flicker.
        var smoothed: Float = 0

        while let snapshot = state.snapshot(for: generation) {
            let target = snapshot.level
            smoothed = target > smoothed ? target : smoothed * 0.88 + target * 0.12

            let colours = LightingController.frame(
                mode: snapshot.mode, colour: snapshot.colour, level: smoothed,
                isMuted: snapshot.isMuted, step: step)
            var delivered = false
            if frameGate.shouldSend(colours) {
                let frame = RazerLightingCommand.frame(
                    colours, transactionID: UInt8(step % 0x1F))
                guard
                    let admitted = accessGate.perform(
                        accessToken, deviceLock: deviceLock,
                        operation: {
                            (try? device.send(frame)) == .success
                        })
                else { return }
                delivered = admitted
                // A busy or failed request did not put these pixels on the
                // hardware. Retry even if the image is unchanged, but not at
                // video rate: a missing device otherwise makes 1,800 blocking
                // HID requests a minute for ever.
                if delivered {
                    retryBackoff.succeeded()
                } else {
                    frameGate.invalidate()
                }
            }
            step &+= 1
            Thread.sleep(
                forTimeInterval: delivered || !frameGate.isInvalidated
                    ? frameInterval : retryBackoff.failed(frameInterval: frameInterval))
        }
    }
}

/// Carries a discovered HID object back across the utility queue.
///
/// The controller remains the only owner that uses the object, and every use
/// still goes through `deviceLock`. The box records that ownership boundary
/// without claiming the third-party HID wrapper itself is generally Sendable.
private final class LightingDiscoveryResult: @unchecked Sendable {
    let device: RazerDevice?

    init(device: RazerDevice?) {
        self.device = device
    }
}

/// One immutable desired HID state owned by the normal-operation lane.
private final class LightingCommandRequest: @unchecked Sendable {
    let device: RazerDevice
    let deviceLock: NSLock
    let accessGate: LightingDeviceAccessGate
    let accessToken: LightingDeviceAccessGate.Token
    let generation: Int
    let mode: LightingMode
    let colour: RazerRing.Colour
    let brightness: UInt8
    let isSignalActive: Bool

    init(
        device: RazerDevice, deviceLock: NSLock,
        accessGate: LightingDeviceAccessGate,
        accessToken: LightingDeviceAccessGate.Token, generation: Int,
        mode: LightingMode, colour: RazerRing.Colour, brightness: UInt8,
        isSignalActive: Bool
    ) {
        self.device = device
        self.deviceLock = deviceLock
        self.accessGate = accessGate
        self.accessToken = accessToken
        self.generation = generation
        self.mode = mode
        self.colour = colour
        self.brightness = brightness
        self.isSignalActive = isSignalActive
    }
}

private final class LightingCommandResult: @unchecked Sendable {
    let request: LightingCommandRequest
    let error: String?
    let enteredDeviceAccess: Bool

    init(
        request: LightingCommandRequest, error: String?, enteredDeviceAccess: Bool
    ) {
        self.request = request
        self.error = error
        self.enteredDeviceAccess = enteredDeviceAccess
    }
}

private enum LightingNormalOperation {
    static func apply(_ request: LightingCommandRequest) -> LightingCommandResult {
        var commandError: String?
        let enteredDeviceAccess =
            request.accessGate.perform(
                request.accessToken, deviceLock: request.deviceLock
            ) {
                do {
                    guard request.mode != .off else {
                        _ = try request.device.send(RazerLightingCommand.brightness(0))
                        return
                    }
                    guard request.mode == .solid || request.isSignalActive else {
                        _ = try request.device.send(RazerLightingCommand.brightness(0))
                        return
                    }
                    _ = try request.device.send(RazerLightingCommand.streamMode())
                    _ = try request.device.send(
                        RazerLightingCommand.brightness(request.brightness))
                    if request.mode == .solid {
                        _ = try request.device.send(
                            RazerLightingCommand.frame(
                                LightingController.frame(
                                    mode: request.mode, colour: request.colour,
                                    level: 0, isMuted: false, step: 0),
                                transactionID: 0))
                    }
                } catch {
                    commandError = String(describing: error)
                }
            } != nil
        return LightingCommandResult(
            request: request, error: commandError,
            enteredDeviceAccess: enteredDeviceAccess)
    }
}

private final class LightingFrameReadRequest: @unchecked Sendable {
    let device: RazerDevice
    let deviceLock: NSLock
    let accessGate: LightingDeviceAccessGate
    let accessToken: LightingDeviceAccessGate.Token

    init(
        device: RazerDevice, deviceLock: NSLock,
        accessGate: LightingDeviceAccessGate,
        accessToken: LightingDeviceAccessGate.Token
    ) {
        self.device = device
        self.deviceLock = deviceLock
        self.accessGate = accessGate
        self.accessToken = accessToken
    }
}

/// A detached HID owner plus the render loop which may still be inside it.
///
/// The render generation is revoked before this capsule is made. Retaining the
/// thread and lock is still essential: a timed-out `IOHIDDeviceSetReport` may
/// be holding that lock and the thread's worker still has the same device.
final class LightingTerminationOwner: @unchecked Sendable {
    private let device: RazerDevice?
    private let deviceLock: NSLock
    private let renderThread: Thread?

    init(device: RazerDevice?, deviceLock: NSLock, renderThread: Thread?) {
        self.device = device
        self.deviceLock = deviceLock
        self.renderThread = renderThread
    }

    func darken(using gate: OwnedResourceShutdownGate) -> Bool {
        withExtendedLifetime(renderThread) {
            var acquired = false
            let lockCompleted = gate.perform {
                deviceLock.lock()
                acquired = true
                return true
            }
            guard lockCompleted == true else {
                // The lock was eventually acquired after the deadline. Give it
                // back without beginning the HID round trip.
                if acquired { deviceLock.unlock() }
                return false
            }
            defer { deviceLock.unlock() }
            guard let device else { return true }
            return gate.perform {
                (try? device.send(RazerLightingCommand.brightness(0))) == .success
            } ?? false
        }
    }
}

/// Suppresses frames the twelve physical LEDs cannot distinguish.
///
/// A level is continuous but the ring is not: most adjacent meter samples
/// light the same LEDs. The old loop still opened the HID device, wrote 64
/// bytes, waited 5 ms and read them back thirty times a second for those
/// identical frames.
struct LightingFrameGate {
    private var previous: [RazerRing.Colour]?
    private(set) var isInvalidated = false

    mutating func shouldSend(_ colours: [RazerRing.Colour]) -> Bool {
        if let previous, Self.equal(previous, colours) { return false }
        previous = colours
        isInvalidated = false
        return true
    }

    mutating func invalidate() {
        previous = nil
        isInvalidated = true
    }

    private static func equal(
        _ lhs: [RazerRing.Colour], _ rhs: [RazerRing.Colour]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { pair in
            pair.0.r == pair.1.r && pair.0.g == pair.1.g && pair.0.b == pair.1.b
        }
    }
}

/// Backs a failed HID device away without making recovery a manual operation.
///
/// A successful frame resets the delay immediately. A disconnected device
/// therefore gets at most a handful of probes per minute once the cap is
/// reached, while plugging it back in resumes the normal frame cadence on the
/// first successful probe.
struct LightingRetryBackoff {
    static let maximumDelay: TimeInterval = 8
    private var consecutiveFailures = 0

    mutating func failed(frameInterval: TimeInterval) -> TimeInterval {
        let exponent = min(consecutiveFailures, 30)
        consecutiveFailures &+= 1
        return min(Self.maximumDelay, frameInterval * pow(2, Double(exponent)))
    }

    mutating func succeeded() {
        consecutiveFailures = 0
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
            renderState.update(mode: mode)
            restart()
        }
    }
    /// The colour used by `.solid`, and the lit colour used by `.level`.
    var colour: (r: UInt8, g: UInt8, b: UInt8) = (0, 120, 255) {
        didSet {
            renderState.update(colour: colour)
            if mode == .solid { restart() }
        }
    }
    var brightness: UInt8 = 255 {
        didSet { if oldValue != brightness { applyBrightness() } }
    }

    private var device: RazerDevice?
    private var thread: Thread?
    private let renderState = LightingRenderState()
    private let deviceAccessGate = LightingDeviceAccessGate()
    private var isSignalActive = false
    private var isTerminating = false
    @ObservationIgnored private var discoveryGate = LatestRefreshGate()
    private static let discoveryQueue = DispatchQueue(
        label: "com.yuhuanstudio.yunaudio.lighting-discovery", qos: .utility)

    /// One owner of the device at a time.
    ///
    /// `IOHIDDeviceOpen` fails while somebody else holds the device open, so a
    /// mode change that sent its setup while the outgoing render thread was
    /// mid-frame came back `couldNotOpen` and the interface reported an error
    /// for a ring that was working. Contention is one HID round trip, about a
    /// millisecond, and nothing here is realtime.
    private let deviceLock = NSLock()
    @ObservationIgnored private lazy var commandLane =
        LatestExternalWorkLane<LightingCommandRequest, LightingCommandResult>(
            queue: DispatchQueue(
                label: "com.yuhuanstudio.yunaudio.lighting-control", qos: .utility),
            apply: LightingNormalOperation.apply,
            publish: { [weak self] result in self?.finishNormalOperation(result) })
    @ObservationIgnored private lazy var frameReadLane =
        LatestExternalWorkLane<LightingFrameReadRequest, [UInt8]?>(
            queue: DispatchQueue(
                label: "com.yuhuanstudio.yunaudio.lighting-read", qos: .utility),
            apply: { request in
                guard
                    let frame = request.accessGate.perform(
                        request.accessToken, deviceLock: request.deviceLock,
                        operation: { () -> [UInt8]? in
                            guard
                                let bytes = try? request.device.readFeatureReport(
                                    id: 0x07, size: 63),
                                bytes.count >= 50
                            else { return nil }
                            return Array(bytes[14..<50])
                        })
                else { return nil }
                return frame
            },
            publish: { [weak self] frame in self?.lastFrameRead = frame })
    @ObservationIgnored private var lastFrameRead: [UInt8]?
    @ObservationIgnored private let terminationWorker =
        BoundedOwnerShutdownWorker<LightingTerminationOwner>(
            label: "com.yuhuanstudio.yunaudio.lighting-shutdown",
            quarantineReason: "light ring teardown is unresolved",
            operation: { $0.darken(using: $1) })
    @ObservationIgnored private var terminationFence: OwnedResourceTeardownFence?

    init() {}

    /// Performs an explicit, deterministic rescan for the settings action.
    func refreshDevice() {
        refreshDeviceAsynchronously()
    }

    /// Discovers the optional HID device without delaying the application's
    /// first MainActor frame.
    func refreshDeviceAsynchronously() {
        guard !isTerminating else { return }
        guard let token = discoveryGate.request() else { return }
        runDeviceDiscovery(token)
    }

    private func runDeviceDiscovery(_ token: LatestRefreshGate.Token) {
        Self.discoveryQueue.async {
            let result = LightingDiscoveryResult(device: RazerDevice.discover().first)
            MainRunLoopDelivery.perform {
                self.finishDeviceDiscovery(result, token: token)
            }
        }
    }

    private func finishDeviceDiscovery(
        _ result: LightingDiscoveryResult, token: LatestRefreshGate.Token
    ) {
        guard !isTerminating, discoveryGate.accepts(token) else { return }
        applyDiscoveredDevice(result.device)
        if case .start(let next) = discoveryGate.finish(token) {
            runDeviceDiscovery(next)
        }
    }

    /// Publishes only an already-discovered object on the MainActor.
    private func applyDiscoveredDevice(_ discoveredDevice: RazerDevice?) {
        renderState.advanceGeneration()
        _ = deviceAccessGate.advance()
        thread = nil
        frameReadLane.invalidate()
        lastFrameRead = nil
        device = discoveredDevice
        let available = discoveredDevice != nil
        if isAvailable != available { isAvailable = available }
        if available {
            restart()
        } else {
            lastError = nil
        }
    }

    /// Called from the router's poll, so the ring follows the same numbers the
    /// meters do.
    func update(level: Float, isMuted: Bool) {
        renderState.update(level: level, isMuted: isMuted)
    }

    /// Whether the router's meter poll has a consumer for level and mute.
    ///
    /// Spectrum is animated but does not read either value. Letting every other
    /// mode through acquired the render-state lock twenty times a second to
    /// overwrite values no worker could use.
    var needsSignalUpdate: Bool {
        Self.needsSignalUpdate(mode: mode, isSignalActive: isSignalActive)
    }

    /// Pure scheduling decision behind the poll gate.
    nonisolated static func needsSignalUpdate(
        mode: LightingMode, isSignalActive: Bool
    ) -> Bool {
        mode == .level && isSignalActive
    }

    /// Starts or withdraws the live signal that animated modes represent.
    ///
    /// Level has no honest frame without a route, and spectrum has no audio to
    /// accompany its animation. A held solid colour needs no worker at all.
    func setSignalActive(_ isActive: Bool) {
        guard isSignalActive != isActive else { return }
        isSignalActive = isActive
        if !isActive {
            renderState.update(level: 0, isMuted: false)
        }
        if mode == .level || mode == .spectrum { restart() }
    }

    /// Invalidates every renderer and hands the HID owner to one bounded lane.
    ///
    /// No device lock or IOKit call is made on MainActor. If an outgoing frame
    /// is already stuck while holding the lock, the worker times out and keeps
    /// the device, lock and render thread together for the process lifetime.
    func requestTerminationStop() -> OwnedResourceTeardownFence {
        if let terminationFence {
            guard terminationFence.result?.permitsSameOwnerRetry == true,
                let retry = terminationWorker.retryAfterTimeoutBeforeEntry()
            else { return terminationFence }
            self.terminationFence = retry
            return retry
        }
        isTerminating = true
        deviceAccessGate.revoke()
        discoveryGate.invalidate()
        commandLane.shutdown()
        frameReadLane.shutdown()
        renderState.advanceGeneration()
        isSignalActive = false
        isAvailable = false
        let renderThread = thread
        thread = nil
        let device = device
        self.device = nil
        let fence = terminationWorker.submit(
            LightingTerminationOwner(
                device: device, deviceLock: deviceLock, renderThread: renderThread))
        terminationFence = fence
        return fence
    }

    private func applyBrightness() {
        guard Self.shouldApplyBrightness(mode: mode, isSignalActive: isSignalActive)
        else { return }
        requestConfiguration()
    }

    private func restart() {
        guard !isTerminating else { return }
        thread = nil
        requestConfiguration()
    }

    private func requestConfiguration() {
        guard !isTerminating, let device else { return }
        let generation = renderState.advanceGeneration()
        let accessToken = deviceAccessGate.advance()
        _ = commandLane.submit(
            LightingCommandRequest(
                device: device, deviceLock: deviceLock,
                accessGate: deviceAccessGate, accessToken: accessToken,
                generation: generation,
                mode: mode, colour: colour, brightness: brightness,
                isSignalActive: isSignalActive))
    }

    private func finishNormalOperation(_ result: LightingCommandResult) {
        guard !isTerminating, result.enteredDeviceAccess,
            device === result.request.device
        else { return }
        lastError = result.error
        guard result.error == nil,
            let frameInterval = Self.workerInterval(
                mode: result.request.mode,
                isSignalActive: result.request.isSignalActive)
        else { return }
        let worker = LightingRenderWorker(
            device: result.request.device, deviceLock: deviceLock,
            accessGate: deviceAccessGate,
            accessToken: result.request.accessToken,
            state: renderState, generation: result.request.generation,
            frameInterval: frameInterval)
        let thread = Thread { worker.run() }
        thread.name = "com.yuhuanstudio.yunaudio.lighting"
        thread.qualityOfService = .utility
        thread.start()
        self.thread = thread
    }

    /// Nil means no render thread and therefore exactly zero background loops.
    nonisolated static func workerInterval(
        mode: LightingMode, isSignalActive: Bool
    ) -> TimeInterval? {
        guard isSignalActive else { return nil }
        return switch mode {
        case .level, .spectrum: 1.0 / 30
        case .off, .solid: nil
        }
    }

    /// Animated modes must not relight their last frame after routing stopped.
    nonisolated static func shouldApplyBrightness(
        mode: LightingMode, isSignalActive: Bool
    ) -> Bool {
        mode == .solid || isSignalActive && (mode == .level || mode == .spectrum)
    }

    /// The frame the device is currently holding, read back off it.
    ///
    /// Used to check that the ring is following the signal rather than assuming
    /// it: the device keeps the last frame it was given, so two reads a moment
    /// apart say whether anything is moving.
    func currentFrame() -> [UInt8]? {
        guard !isTerminating, let device,
            let accessToken = deviceAccessGate.current()
        else { return nil }
        _ = frameReadLane.submit(
            LightingFrameReadRequest(
                device: device, deviceLock: deviceLock,
                accessGate: deviceAccessGate, accessToken: accessToken))
        return lastFrameRead
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
