import AVFoundation
import Foundation
import YunAudioRT

/// Writes the routed signal to a file.
///
/// The audio is already in the IO callback, so recording is mostly a question of
/// getting it out of there without blocking: a file write is a syscall and a
/// syscall on the IO thread is a dropout. Frames go into a lock-free ring on the
/// realtime side and a writer thread drains it.
///
/// What lands on disk is the signal as routed — after any processing, before the
/// virtual device. Recording the same thing the far end hears is the point;
/// recording something subtly different would make the file useless as evidence
/// of what was sent.
/// `@unchecked Sendable` because the writer thread and the caller genuinely
/// share it: the stop flag is behind a lock, `framesWritten` is only ever
/// written by the writer, and the ring is lock-free by construction.
public final class Recorder: @unchecked Sendable {
    public enum Format: String, CaseIterable, Sendable {
        /// Lossless, and the only choice that keeps a bit-exact path bit-exact.
        case wav
        /// Lossless and about half the size of WAV. The right default for
        /// anybody keeping the recording rather than sending it somewhere.
        case flac
        /// A quarter the size, at the cost of being a lossy copy of something
        /// this project spends most of its effort keeping intact.
        case aac

        public var fileExtension: String {
            switch self {
            case .wav: "wav"
            case .flac: "flac"
            case .aac: "m4a"
            }
        }

        public var title: String {
            switch self {
            case .wav: "WAV"
            case .flac: "FLAC"
            case .aac: "AAC"
            }
        }

        /// True when nothing about the signal is thrown away, which is the only
        /// thing that matters for a project whose whole claim is that the path
        /// is bit-exact.
        public var isLossless: Bool { self != .aac }
    }

    public let url: URL
    /// Handed to the graph so the IO thread can write without going through
    /// this object, which is a Swift class and must not be touched there.
    public var ringHandle: OpaquePointer { ring }
    public private(set) var framesWritten: Int64 = 0
    public private(set) var lastError: String?

    private let file: AVAudioFile
    private let ring: OpaquePointer
    private let channels: Int
    private let sampleRate: Double
    private var writer: Thread?
    private var isStopping = false
    private let stopLock = NSLock()

    /// - Parameters:
    ///   - directory: Where the file goes. The caller owns the choice so the
    ///     app can put it somewhere the user picked.
    ///   - format: Container and encoding.
    ///   - channels: Channels to record.
    ///   - sampleRate: Rate of the material being recorded.
    ///   - timestamp: Used in the file name. Passed in rather than read here so
    ///     the name is reproducible in a test.
    /// - Throws: Whatever `AVAudioFile` throws when the destination cannot be
    ///   created — a directory that does not exist, or is not writable.
    public init(
        directory: URL, format: Format, channels: Int, sampleRate: Double, timestamp: Date
    ) throws {
        self.channels = max(1, channels)
        self.sampleRate = sampleRate

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        url = directory.appendingPathComponent(
            "YunAudio \(stamp.string(from: timestamp)).\(format.fileExtension)")

        var settings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: self.channels,
        ]
        switch format {
        case .wav:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            // 32-bit float on disk: the capture path is float throughout, so
            // anything narrower would quantise at the last step.
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = true
            settings[AVLinearPCMIsNonInterleaved] = false
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
            // FLAC is an integer format, so this is the one path where the
            // float capture has to be quantised. Twenty-four bits puts the
            // quantisation floor at −144 dBFS, which is below the noise floor
            // of any microphone that has ever existed.
            settings[AVLinearPCMBitDepthKey] = 24
        case .aac:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = 256_000
        }

        file = try AVAudioFile(forWriting: url, settings: settings)

        // Four seconds of headroom. The writer wakes ten times a second, so this
        // survives a long stall on the file system without losing audio.
        let capacity = UInt32(sampleRate * 4) * UInt32(self.channels)
        guard let ring = yun_rt_ring_create(capacity) else {
            throw RecorderError.couldNotAllocate
        }
        self.ring = ring

        let thread = Thread { [weak self] in self?.drain() }
        thread.name = "com.yuhuanstudio.yunaudio.recorder"
        thread.qualityOfService = .utility
        thread.start()
        writer = thread
    }

    deinit { yun_rt_ring_free(ring) }

    /// Realtime side. Never blocks; drops rather than waits when the ring is
    /// full, because stalling the IO thread would cost the live signal as well
    /// as the recording.
    @inline(__always)
    public func write(_ samples: UnsafePointer<Float>, count: Int) {
        _ = yun_rt_ring_write(ring, samples, UInt32(count))
    }

    public func stop() {
        stopLock.lock()
        isStopping = true
        stopLock.unlock()
        // Give the writer a moment to flush what is still in the ring.
        while writer?.isFinished == false { usleep(20000) }
        writer = nil
    }

    private var shouldStop: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return isStopping
    }

    private func drain() {
        let chunk = 4096
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: AVAudioFormat(
                    standardFormatWithSampleRate: sampleRate,
                    channels: AVAudioChannelCount(channels))!,
                frameCapacity: AVAudioFrameCount(chunk))
        else { return }

        var scratch = [Float](repeating: 0, count: chunk * channels)

        while true {
            let stopping = shouldStop
            let read = scratch.withUnsafeMutableBufferPointer {
                Int(yun_rt_ring_read(ring, $0.baseAddress!, UInt32($0.count)))
            }
            if read == 0 {
                if stopping { break }
                usleep(100_000)
                continue
            }

            let frames = read / channels
            buffer.frameLength = AVAudioFrameCount(frames)
            // The ring carries interleaved frames; AVAudioPCMBuffer's standard
            // format is deinterleaved, so they are split here rather than on the
            // IO thread.
            if let channelData = buffer.floatChannelData {
                for channel in 0..<channels {
                    let destination = channelData[channel]
                    for frame in 0..<frames {
                        destination[frame] = scratch[frame * channels + channel]
                    }
                }
            }
            do {
                try file.write(from: buffer)
                framesWritten += Int64(frames)
            } catch {
                lastError = error.localizedDescription
                break
            }
        }
    }

    public var duration: TimeInterval {
        sampleRate > 0 ? Double(framesWritten) / sampleRate : 0
    }
}

public enum RecorderError: Error, CustomStringConvertible {
    case couldNotAllocate

    public var description: String {
        switch self {
        case .couldNotAllocate: "the recording buffer could not be allocated"
        }
    }
}
