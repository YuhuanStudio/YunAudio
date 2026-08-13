import CoreAudio
import Foundation
import YunAudioRT

/// Per-output correction whose live configuration is never mutated in place.
///
/// The control thread writes only the inactive bank, then publishes one scalar
/// command through an SPSC queue. The IO thread observes that command at a cycle
/// boundary and hands old to new with a twenty-millisecond output crossfade.
/// Both coefficient and filter-history storage are fixed at construction.
final class OutputCorrectionBank: @unchecked Sendable {
    struct Configuration: Equatable, Sendable {
        let coefficients: [Float]
        let preampGain: Float

        var stages: Int {
            min(coefficients.count / 5, OutputCorrectionBank.maximumStages)
        }

        init?(coefficients: [Float], preampGain: Float) {
            let stages = min(coefficients.count / 5, OutputCorrectionBank.maximumStages)
            guard stages > 0, preampGain.isFinite, preampGain >= 0,
                coefficients.prefix(stages * 5).allSatisfy(\.isFinite)
            else { return nil }
            self.coefficients = Array(coefficients.prefix(stages * 5))
            self.preampGain = preampGain
        }
    }

    static let maximumSlots = 8
    static let maximumStages = 24
    static let maximumChannels = 8
    static let fadeSeconds = 0.020

    let sampleRate: Double
    let maximumFrames: Int
    let fadeFrames: Int
    let latencyFrames = 0

    var fixedStorageBytes: Int {
        let slotBanks = Self.banks * Self.maximumSlots
        let floats =
            slotBanks
            + slotBanks * Self.coefficientStride
            + slotBanks * Self.stateStride
            + maximumFrames * Self.maximumChannels
        let integers =
            slotBanks + Self.maximumSlots * 2
        return floats * MemoryLayout<Float>.size
            + integers * MemoryLayout<Int32>.size
            + Self.maximumSlots * MemoryLayout<Int>.size
    }

    private static let banks = 2
    private static let coefficientStride = maximumStages * 5
    private static let stateStride = maximumStages * maximumChannels * 4

    private let stages: UnsafeMutablePointer<Int32>
    private let preampGains: UnsafeMutablePointer<Float>
    private let coefficients: UnsafeMutablePointer<Float>
    private let states: UnsafeMutablePointer<Float>
    private let activeBanks: UnsafeMutablePointer<Int32>
    private let targetBanks: UnsafeMutablePointer<Int32>
    private let transitionPositions: UnsafeMutablePointer<Int>
    private let scratch: UnsafeMutablePointer<Float>
    private let commands: OpaquePointer
    private let completion: OpaquePointer

    /// Written and read only by the IO thread.
    private var transitionMask: UInt32 = 0

    /// Serialises the one control-side producer without involving engine state.
    private let publicationLock = NSLock()
    private var controlBanks = [Int](repeating: 0, count: maximumSlots)
    private var controlConfigurations = [Configuration?](
        repeating: nil, count: maximumSlots)
    private var pending: PendingPublication?

    private struct PendingPublication {
        let completionAfter: UInt64
        let changedMask: UInt32
        let targetMask: UInt32
        let configurations: [Configuration?]
    }

    init?(sampleRate: Double, maximumFrames: Int) {
        guard AudioProcessingContract.supports(sampleRate: sampleRate),
            AudioProcessingContract.supports(framesPerSlice: maximumFrames)
        else { return nil }
        guard let commands = yun_rt_queue_create(2) else { return nil }
        guard let completion = yun_rt_counter_create(0) else {
            yun_rt_queue_free(commands)
            return nil
        }

        self.sampleRate = sampleRate
        self.maximumFrames = maximumFrames
        fadeFrames = max(1, Int((sampleRate * Self.fadeSeconds).rounded()))
        self.commands = commands
        self.completion = completion

        let slotBanks = Self.banks * Self.maximumSlots
        stages = .allocate(capacity: slotBanks)
        stages.initialize(repeating: 0, count: slotBanks)
        preampGains = .allocate(capacity: slotBanks)
        preampGains.initialize(repeating: 1, count: slotBanks)
        coefficients = .allocate(capacity: slotBanks * Self.coefficientStride)
        coefficients.initialize(
            repeating: 0, count: slotBanks * Self.coefficientStride)
        states = .allocate(capacity: slotBanks * Self.stateStride)
        states.initialize(repeating: 0, count: slotBanks * Self.stateStride)
        activeBanks = .allocate(capacity: Self.maximumSlots)
        activeBanks.initialize(repeating: 0, count: Self.maximumSlots)
        targetBanks = .allocate(capacity: Self.maximumSlots)
        targetBanks.initialize(repeating: 0, count: Self.maximumSlots)
        transitionPositions = .allocate(capacity: Self.maximumSlots)
        transitionPositions.initialize(repeating: 0, count: Self.maximumSlots)
        scratch = .allocate(capacity: maximumFrames * Self.maximumChannels)
        scratch.initialize(
            repeating: 0, count: maximumFrames * Self.maximumChannels)
    }

    deinit {
        let slotBanks = Self.banks * Self.maximumSlots
        stages.deinitialize(count: slotBanks)
        stages.deallocate()
        preampGains.deinitialize(count: slotBanks)
        preampGains.deallocate()
        coefficients.deinitialize(count: slotBanks * Self.coefficientStride)
        coefficients.deallocate()
        states.deinitialize(count: slotBanks * Self.stateStride)
        states.deallocate()
        activeBanks.deinitialize(count: Self.maximumSlots)
        activeBanks.deallocate()
        targetBanks.deinitialize(count: Self.maximumSlots)
        targetBanks.deallocate()
        transitionPositions.deinitialize(count: Self.maximumSlots)
        transitionPositions.deallocate()
        scratch.deinitialize(count: maximumFrames * Self.maximumChannels)
        scratch.deallocate()
        yun_rt_queue_free(commands)
        yun_rt_counter_free(completion)
    }

    /// Installs setup state before this bank is visible to the IO thread.
    ///
    /// Live callers use `publish`; this exists for graph construction and
    /// deterministic filter tests where no previous sound needs a handover.
    @discardableResult
    func installImmediately(_ configuration: Configuration?, slot: Int) -> Bool {
        guard slot >= 0, slot < Self.maximumSlots else { return false }
        publicationLock.lock()
        defer { publicationLock.unlock() }
        guard pending == nil else { return false }
        if controlConfigurations[slot] == configuration {
            return configuration != nil
        }
        prepare(configuration, slot: slot, bank: 0)
        prepare(nil, slot: slot, bank: 1)
        activeBanks[slot] = 0
        targetBanks[slot] = 0
        controlBanks[slot] = 0
        controlConfigurations[slot] = configuration
        return configuration != nil
    }

    /// Publishes one complete set of output curves and waits for its handover.
    ///
    /// Waiting happens on the caller's background queue and under this bank's
    /// own lock, never `RoutingEngine.stateLock`. That makes reusing the
    /// inactive storage provably safe without stalling hotkeys or faders.
    func publish(
        _ configurations: [Int: Configuration],
        timeoutMilliseconds: UInt64 = 500
    ) -> Int {
        publicationLock.lock()
        defer { publicationLock.unlock() }

        guard finishPending(timeoutMilliseconds: timeoutMilliseconds) else {
            return installedCount
        }

        var desired = [Configuration?](repeating: nil, count: Self.maximumSlots)
        for (slot, configuration) in configurations
        where slot >= 0 && slot < Self.maximumSlots {
            desired[slot] = configuration
        }

        var changedMask: UInt32 = 0
        var targetMask: UInt32 = 0
        for slot in 0..<Self.maximumSlots
        where desired[slot] != controlConfigurations[slot] {
            changedMask |= 1 << UInt32(slot)
            let target = 1 - controlBanks[slot]
            if target != 0 { targetMask |= 1 << UInt32(slot) }
            prepare(desired[slot], slot: slot, bank: target)
        }
        guard changedMask != 0 else { return installedCount }

        let completionAfter = yun_rt_counter_load(completion) &+ 1
        let command = YunRTCommand(
            kind: 0, index: Int32(changedMask), value: Float(targetMask))
        guard yun_rt_queue_push(commands, command) else { return installedCount }

        pending = PendingPublication(
            completionAfter: completionAfter,
            changedMask: changedMask,
            targetMask: targetMask,
            configurations: desired)
        _ = finishPending(timeoutMilliseconds: timeoutMilliseconds)
        return installedCount
    }

    /// Prepares a handover before a synthetic or unpublished graph is rendered.
    ///
    /// This is the deterministic counterpart to `publish`: it exercises the
    /// identical render state without needing a second thread merely to feed
    /// the SPSC queue in numerical and release-cost tests.
    func prepareTransitionImmediately(
        from old: Configuration?, to new: Configuration?, slot: Int
    ) {
        guard slot >= 0, slot < Self.maximumSlots else { return }
        prepare(old, slot: slot, bank: 0)
        prepare(new, slot: slot, bank: 1)
        activeBanks[slot] = 0
        targetBanks[slot] = 1
        transitionMask |= UInt32(1) << UInt32(slot)
        transitionPositions[slot] = 0
        controlBanks[slot] = 0
        controlConfigurations[slot] = old
    }

    /// Runs all output slots for one IO cycle.
    @inline(__always)
    func process(_ output: UnsafeMutableAudioBufferListPointer) {
        acceptPublication()
        let transitionWasActive = transitionMask != 0
        var cycleFrames = 0
        var renderedMask: UInt32 = 0
        let slots = min(Self.maximumSlots, output.count)
        for slot in 0..<slots {
            let buffer = output[slot]
            guard let data = buffer.mData else { continue }
            let stride = Int(buffer.mNumberChannels)
            guard stride > 0 else { continue }
            let frames =
                Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * stride)
            cycleFrames = max(cycleFrames, frames)
            let channels = min(stride, Self.maximumChannels)
            let samples = data.assumingMemoryBound(to: Float.self)
            let bit = UInt32(1) << UInt32(slot)

            if transitionMask & bit != 0 {
                guard frames > 0 else { continue }
                renderedMask |= bit
                // A device can hand over a larger slice after a live format
                // change than the graph's ordinary cycle. Chunking through the
                // fixed scratch keeps the fade sample-accurate instead of
                // silently skipping it and hard-switching at the next cycle.
                var processed = 0
                while processed < frames {
                    let chunk = min(maximumFrames, frames - processed)
                    let old = samples + processed * stride
                    for frame in 0..<chunk {
                        for channel in 0..<channels {
                            scratch[frame * channels + channel] =
                                old[frame * stride + channel]
                        }
                    }
                    let oldBank = Int(activeBanks[slot])
                    let newBank = Int(targetBanks[slot])
                    process(
                        old, frames: chunk, channels: channels, stride: stride,
                        slot: slot, bank: oldBank)
                    process(
                        scratch, frames: chunk, channels: channels, stride: channels,
                        slot: slot, bank: newBank)
                    crossfade(
                        old: old, oldStride: stride, new: scratch,
                        frames: chunk, channels: channels,
                        position: transitionPositions[slot] + processed)
                    processed += chunk
                }
                advanceTransition(slot: slot, frames: frames)
            } else {
                process(
                    samples, frames: frames, channels: channels, stride: stride,
                    slot: slot, bank: Int(activeBanks[slot]))
            }
        }
        // A nil or absent output has no sample on which a handover can click.
        // Advance it by the longest buffer in this callback so publication
        // cannot wedge merely because an inactive stream supplied no storage.
        if transitionMask != 0, cycleFrames > 0 {
            for slot in 0..<Self.maximumSlots {
                let bit = UInt32(1) << UInt32(slot)
                if transitionMask & bit != 0, renderedMask & bit == 0 {
                    advanceTransition(slot: slot, frames: cycleFrames)
                }
            }
        }
        if transitionWasActive, transitionMask == 0 {
            yun_rt_counter_increment(completion)
        }
    }

    var installedCount: Int {
        controlConfigurations.reduce(0) { $0 + ($1 == nil ? 0 : 1) }
    }

    func stageCount(slot: Int, bank: Int = 0) -> Int {
        guard slot >= 0, slot < Self.maximumSlots, bank >= 0, bank < Self.banks
        else { return 0 }
        return Int(stages[slotBankIndex(slot: slot, bank: bank)])
    }

    func coefficient(slot: Int, bank: Int = 0, index: Int) -> Float? {
        guard slot >= 0, slot < Self.maximumSlots, bank >= 0, bank < Self.banks,
            index >= 0, index < Self.coefficientStride
        else { return nil }
        return coefficients[coefficientOffset(slot: slot, bank: bank) + index]
    }

    func stateValue(slot: Int, bank: Int = 0, index: Int) -> Float? {
        guard slot >= 0, slot < Self.maximumSlots, bank >= 0, bank < Self.banks,
            index >= 0, index < Self.stateStride
        else { return nil }
        return states[stateOffset(slot: slot, bank: bank) + index]
    }

    func setStateValue(_ value: Float, slot: Int, bank: Int = 0, index: Int) {
        guard slot >= 0, slot < Self.maximumSlots, bank >= 0, bank < Self.banks,
            index >= 0, index < Self.stateStride
        else { return }
        states[stateOffset(slot: slot, bank: bank) + index] = value
    }

    private func finishPending(timeoutMilliseconds: UInt64) -> Bool {
        guard let pending else { return true }
        let deadline =
            DispatchTime.now().uptimeNanoseconds
            &+ timeoutMilliseconds &* 1_000_000
        while yun_rt_counter_load(completion) < pending.completionAfter {
            if DispatchTime.now().uptimeNanoseconds >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.001)
        }
        for slot in 0..<Self.maximumSlots {
            let bit = UInt32(1) << UInt32(slot)
            guard pending.changedMask & bit != 0 else { continue }
            controlBanks[slot] = pending.targetMask & bit == 0 ? 0 : 1
        }
        controlConfigurations = pending.configurations
        self.pending = nil
        return true
    }

    private func prepare(_ configuration: Configuration?, slot: Int, bank: Int) {
        let slotBank = slotBankIndex(slot: slot, bank: bank)
        stages[slotBank] = 0
        preampGains[slotBank] = configuration?.preampGain ?? 1
        let coefficientBase = coefficientOffset(slot: slot, bank: bank)
        coefficients.advanced(by: coefficientBase).update(
            repeating: 0, count: Self.coefficientStride)
        if let configuration {
            configuration.coefficients.withUnsafeBufferPointer { packed in
                guard let base = packed.baseAddress else { return }
                coefficients.advanced(by: coefficientBase).update(
                    from: base, count: packed.count)
            }
        }
        states.advanced(by: stateOffset(slot: slot, bank: bank)).update(
            repeating: 0, count: Self.stateStride)
        stages[slotBank] = Int32(configuration?.stages ?? 0)
    }

    @inline(__always)
    private func acceptPublication() {
        guard transitionMask == 0 else { return }
        var command = YunRTCommand(kind: 0, index: 0, value: 0)
        guard yun_rt_queue_pop(commands, &command) else { return }
        transitionMask = UInt32(bitPattern: command.index)
        let targetMask = UInt32(max(0, command.value))
        for slot in 0..<Self.maximumSlots {
            let bit = UInt32(1) << UInt32(slot)
            if transitionMask & bit != 0 {
                targetBanks[slot] = targetMask & bit == 0 ? 0 : 1
                transitionPositions[slot] = 0
            }
        }
    }

    @inline(__always)
    private func advanceTransition(slot: Int, frames: Int) {
        guard frames > 0 else { return }
        let bit = UInt32(1) << UInt32(slot)
        guard transitionMask & bit != 0 else { return }
        transitionPositions[slot] += frames
        guard transitionPositions[slot] >= fadeFrames else { return }
        activeBanks[slot] = targetBanks[slot]
        transitionPositions[slot] = 0
        transitionMask &= ~bit
    }

    @inline(__always)
    private func crossfade(
        old: UnsafeMutablePointer<Float>, oldStride: Int,
        new: UnsafePointer<Float>, frames: Int, channels: Int,
        position: Int
    ) {
        let denominator = Float(max(fadeFrames - 1, 1))
        for frame in 0..<frames {
            let absolute = position + frame
            let amount =
                fadeFrames == 1
                ? 1 : min(1, Float(absolute) / denominator)
            for channel in 0..<channels {
                let oldIndex = frame * oldStride + channel
                let newIndex = frame * channels + channel
                let oldSample = sanitisedAudioSample(old[oldIndex])
                let newSample = sanitisedAudioSample(new[newIndex])
                old[oldIndex] =
                    oldSample + (newSample - oldSample) * amount
            }
        }
    }

    @inline(__always)
    private func process(
        _ samples: UnsafeMutablePointer<Float>, frames: Int,
        channels: Int, stride: Int, slot: Int, bank: Int
    ) {
        let slotBank = slotBankIndex(slot: slot, bank: bank)
        let stageCount = Int(stages[slotBank])
        guard stageCount > 0 else { return }
        let coefficientBase = coefficientOffset(slot: slot, bank: bank)
        let stateBase = stateOffset(slot: slot, bank: bank)
        let preamp = preampGains[slotBank]

        // Fold the preamp and the one untrusted boundary into a single pass.
        // Every later section reads the finite value written by the previous
        // one, so repeating this check inside all twenty-four cascades triples
        // their measured cost without making another state transition safer.
        for frame in 0..<frames {
            for channel in 0..<channels {
                let index = frame * stride + channel
                samples[index] = sanitisedAudioSample(samples[index] * preamp)
            }
        }

        for section in 0..<stageCount {
            let c = coefficients + coefficientBase + section * 5
            let b0 = c[0]
            let b1 = c[1]
            let b2 = c[2]
            let a1 = c[3]
            let a2 = c[4]
            let sectionState =
                states + stateBase + section * Self.maximumChannels * 4

            var channel = 0
            while channel + 1 < channels {
                let left = sectionState + channel * 4
                let right = left + 4
                var lx1 = left[0]
                var lx2 = left[1]
                var ly1 = left[2]
                var ly2 = left[3]
                var rx1 = right[0]
                var rx2 = right[1]
                var ry1 = right[2]
                var ry2 = right[3]
                var index = channel
                for _ in 0..<frames {
                    let lx = samples[index]
                    let rx = samples[index + 1]
                    let ly =
                        b0 * lx + b1 * lx1 + b2 * lx2
                        - a1 * ly1 - a2 * ly2
                    let ry =
                        b0 * rx + b1 * rx1 + b2 * rx2
                        - a1 * ry1 - a2 * ry2
                    lx2 = lx1
                    lx1 = lx
                    ly2 = ly1
                    ly1 = ly
                    rx2 = rx1
                    rx1 = rx
                    ry2 = ry1
                    ry1 = ry
                    samples[index] = sanitisedAudioSample(ly)
                    samples[index + 1] = sanitisedAudioSample(ry)
                    index += stride
                }
                // State is sanitised once at the block boundary. The input
                // boundary and each inter-section sample are already finite;
                // this catches an internal overflow without putting IEEE-754
                // classification on the biquad's loop-carried critical path.
                left[0] = sanitisedAudioSample(lx1)
                left[1] = sanitisedAudioSample(lx2)
                left[2] = sanitisedAudioSample(ly1)
                left[3] = sanitisedAudioSample(ly2)
                right[0] = sanitisedAudioSample(rx1)
                right[1] = sanitisedAudioSample(rx2)
                right[2] = sanitisedAudioSample(ry1)
                right[3] = sanitisedAudioSample(ry2)
                channel += 2
            }

            if channel < channels {
                let mono = sectionState + channel * 4
                var x1 = mono[0]
                var x2 = mono[1]
                var y1 = mono[2]
                var y2 = mono[3]
                var index = channel
                for _ in 0..<frames {
                    let x = samples[index]
                    let y =
                        b0 * x + b1 * x1 + b2 * x2
                        - a1 * y1 - a2 * y2
                    x2 = x1
                    x1 = x
                    y2 = y1
                    y1 = y
                    samples[index] = sanitisedAudioSample(y)
                    index += stride
                }
                mono[0] = sanitisedAudioSample(x1)
                mono[1] = sanitisedAudioSample(x2)
                mono[2] = sanitisedAudioSample(y1)
                mono[3] = sanitisedAudioSample(y2)
            }
        }
    }

    @inline(__always)
    private func slotBankIndex(slot: Int, bank: Int) -> Int {
        bank * Self.maximumSlots + slot
    }

    @inline(__always)
    private func coefficientOffset(slot: Int, bank: Int) -> Int {
        slotBankIndex(slot: slot, bank: bank) * Self.coefficientStride
    }

    @inline(__always)
    private func stateOffset(slot: Int, bank: Int) -> Int {
        slotBankIndex(slot: slot, bank: bank) * Self.stateStride
    }
}
