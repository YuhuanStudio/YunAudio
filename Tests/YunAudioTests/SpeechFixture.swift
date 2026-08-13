import AVFoundation
import CryptoKit
import Foundation

/// One immutable, checked input for tests whose claim is about speech rather
/// than about whether macOS's speech service happened to answer today.
enum DeterministicSpeechFixture {
    struct Audio: Sendable {
        let samples: [Float]
        let rate: Double
    }

    enum Failure: Error, CustomStringConvertible {
        case missingResource
        case fileSize(actual: Int)
        case hash(actual: String)
        case format(rate: Double, channels: UInt32, frames: AVAudioFramePosition)
        case bufferAllocation(frames: AVAudioFramePosition)
        case decodedFrames(actual: AVAudioFrameCount)
        case missingFloatChannel

        var description: String {
            switch self {
            case .missingResource:
                return "SpeechFixture.wav is missing from the test resource bundle"
            case .fileSize(let actual):
                return "SpeechFixture.wav is \(actual) bytes; expected 108844"
            case .hash(let actual):
                return "SpeechFixture.wav SHA-256 is \(actual); the checked fixture changed"
            case .format(let rate, let channels, let frames):
                return
                    "SpeechFixture.wav is \(rate) Hz / \(channels) channels / \(frames) frames; "
                    + "expected 16000 Hz mono / 54400 frames"
            case .bufferAllocation(let frames):
                return "could not allocate the \(frames)-frame speech fixture buffer"
            case .decodedFrames(let actual):
                return "SpeechFixture.wav decoded \(actual) frames; expected 54400"
            case .missingFloatChannel:
                return "SpeechFixture.wav did not decode to a mono float channel"
            }
        }
    }

    static let expectedFrames: AVAudioFramePosition = 54_400
    static let expectedRate = 16_000.0
    static let expectedFileBytes = 108_844
    static let expectedSHA256 =
        "c65fcd726d6b08c82c1e5dc7558f863cd8d483e3ed2f4a7bcf271dc1865ada14"

    static func load() throws -> Audio {
        guard let url = Bundle.module.url(forResource: "SpeechFixture", withExtension: "wav")
        else { throw Failure.missingResource }

        let data = try Data(contentsOf: url)
        guard data.count == expectedFileBytes else {
            throw Failure.fileSize(actual: data.count)
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == expectedSHA256 else { throw Failure.hash(actual: hash) }

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length == expectedFrames, format.sampleRate == expectedRate,
            format.channelCount == 1
        else {
            throw Failure.format(
                rate: format.sampleRate, channels: format.channelCount, frames: file.length)
        }
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(expectedFrames))
        else { throw Failure.bufferAllocation(frames: file.length) }
        try file.read(into: buffer)
        guard buffer.frameLength == AVAudioFrameCount(expectedFrames) else {
            throw Failure.decodedFrames(actual: buffer.frameLength)
        }
        guard let channel = buffer.floatChannelData else { throw Failure.missingFloatChannel }
        return Audio(
            samples: Array(
                UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))),
            rate: format.sampleRate)
    }
}

/// Serialises opt-in probes which exercise the process-wide macOS speech
/// service. Baseline tests use `DeterministicSpeechFixture`; a live probe is an
/// environment diagnosis, and two diagnoses must not make each other fail.
actor LiveSpeechAdmission {
    static let shared = LiveSpeechAdmission()

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withPermit<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async rethrows -> Result {
        await acquire()
        do {
            let result = try await operation()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum LiveSpeechProbe {
    enum Failure: Error, CustomStringConvertible {
        case synthesiserTimedOutOrEmpty
        case sayFailed(status: Int32)
        case emptySayOutput(bytes: Int, frames: AVAudioFramePosition, rate: Double)
        case bufferAllocation(frames: AVAudioFramePosition)
        case missingFloatChannel

        var description: String {
            switch self {
            case .synthesiserTimedOutOrEmpty:
                return "AVSpeechSynthesizer delivered no non-empty buffer within 10 seconds"
            case .sayFailed(let status):
                return "/usr/bin/say exited with status \(status)"
            case .emptySayOutput(let bytes, let frames, let rate):
                return
                    "/usr/bin/say produced \(bytes) bytes / \(frames) frames at \(rate) Hz"
            case .bufferAllocation(let frames):
                return "could not allocate /usr/bin/say's \(frames)-frame output"
            case .missingFloatChannel:
                return "/usr/bin/say output did not decode to a mono float channel"
            }
        }
    }

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["YUNAUDIO_LIVE_SPEECH_PROBE"] == "1"
    }

    static func renderWithSay(_ words: String) throws -> DeterministicSpeechFixture.Audio {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yunaudio-speech-probe-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, words]
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw Failure.sayFailed(status: process.terminationStatus)
        }

        let data = try Data(contentsOf: url)
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0, !data.isEmpty else {
            throw Failure.emptySayOutput(
                bytes: data.count, frames: file.length, rate: format.sampleRate)
        }
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { throw Failure.bufferAllocation(frames: file.length) }
        try file.read(into: buffer)
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData else {
            throw Failure.missingFloatChannel
        }
        return DeterministicSpeechFixture.Audio(
            samples: Array(
                UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))),
            rate: format.sampleRate)
    }
}
