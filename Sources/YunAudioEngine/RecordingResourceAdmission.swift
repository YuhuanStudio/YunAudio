import Foundation

/// Pure admission for every file writer created by one recording session.
///
/// Per-recorder bounds are not a session bound: a mix plus sixty-four stems at
/// the largest supported rate would otherwise reserve about 762 MiB and start
/// sixty-five threads in one click. The session receives 128 MiB of float-ring
/// storage and at most thirty-two writers. At 48 kHz that still admits the mix
/// plus thirty-one stereo stems with four seconds of backlog (about 48 MiB),
/// while leaving headroom for graphs, Audio Units and analyser storage.
struct RecordingResourceAdmission: Equatable, Sendable {
    static let maximumWriters = 32
    static let maximumRingBytes = 128 * 1_024 * 1_024

    let writerCount: Int
    let ringSamples: Int
    let ringBytes: Int

    static func evaluate(sampleRate: Double, channelCounts: [Int]) -> Self? {
        guard !channelCounts.isEmpty, channelCounts.count <= maximumWriters else {
            return nil
        }
        var samples = 0
        for channels in channelCounts {
            guard
                let capacity = Recorder.ringSampleCapacity(
                    sampleRate: sampleRate, channels: channels)
            else { return nil }
            let addition = samples.addingReportingOverflow(capacity)
            guard !addition.overflow else { return nil }
            samples = addition.partialValue
        }
        guard let bytes = admittedRingBytes(sampleCounts: [samples]) else { return nil }
        return Self(
            writerCount: channelCounts.count,
            ringSamples: samples,
            ringBytes: bytes)
    }

    /// Exact overflow-checked arithmetic kept independently testable.
    static func totalRingBytes(sampleCounts: [Int]) -> Int? {
        guard !sampleCounts.isEmpty else { return nil }
        var samples = 0
        for count in sampleCounts {
            guard count > 0 else { return nil }
            let addition = samples.addingReportingOverflow(count)
            guard !addition.overflow else { return nil }
            samples = addition.partialValue
        }
        let bytes = samples.multipliedReportingOverflow(by: MemoryLayout<Float>.stride)
        return bytes.overflow ? nil : bytes.partialValue
    }

    /// Applies the aggregate byte ceiling after overflow-safe arithmetic.
    static func admittedRingBytes(sampleCounts: [Int]) -> Int? {
        guard let bytes = totalRingBytes(sampleCounts: sampleCounts),
            bytes <= maximumRingBytes
        else { return nil }
        return bytes
    }
}
