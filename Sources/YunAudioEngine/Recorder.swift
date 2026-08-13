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
/// share it: mutable lifecycle and progress state is behind locks, and the
/// ring is lock-free by construction.
public final class Recorder: @unchecked Sendable {
    static let maximumChannelCount = 64
    /// Thirty-two MiB of float storage. Four seconds of 384 kHz stereo fits;
    /// a corrupt format cannot turn one recorder into a multi-gigabyte request.
    static let maximumRingSamples = 8 * 1_024 * 1_024
    /// File progress and failure from one writer-thread observation.
    public struct ProgressSnapshot: Sendable, Equatable {
        public let framesWritten: Int64
        public let duration: TimeInterval
        public let error: String?

        public init(framesWritten: Int64, duration: TimeInterval, error: String?) {
            self.framesWritten = framesWritten
            self.duration = duration
            self.error = error
        }
    }

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

    /// Frames durably handed to the file writer.
    ///
    /// The writer updates this from its utility thread while the interface
    /// polls progress. A plain stored property was a data race even though
    /// there was only one writer.
    public var framesWritten: Int64 {
        progressSnapshot.framesWritten
    }

    /// The terminal file error, when writing stopped early.
    public var lastError: String? {
        progressSnapshot.error
    }

    /// One coherent read of progress and terminal state.
    public var progressSnapshot: ProgressSnapshot {
        progressLock.withLock {
            ProgressSnapshot(
                framesWritten: storedFramesWritten,
                duration: sampleRate > 0 ? Double(storedFramesWritten) / sampleRate : 0,
                error: storedLastError)
        }
    }

    private let file: AVAudioFile
    private let ring: OpaquePointer
    private let channels: Int
    private let sampleRate: Double
    private var writer: Thread?
    private var isStopping = false
    private let stopLock = NSLock()
    private var storedFramesWritten: Int64 = 0
    private var storedLastError: String?
    private let progressLock = NSLock()
    private let writerWake = DispatchSemaphore(value: 0)
    private let writerReady = DispatchSemaphore(value: 0)
    private let writerFinished = DispatchGroup()

    /// Exact float-ring storage for one admitted writer.
    static func ringSampleCapacity(sampleRate: Double, channels: Int) -> Int? {
        guard AudioProcessingContract.supports(sampleRate: sampleRate),
            (1...Self.maximumChannelCount).contains(channels)
        else { return nil }
        let requested = sampleRate * 4 * Double(channels)
        guard requested.isFinite,
            let capacity = Int(exactly: requested.rounded(.up)),
            capacity > 0, capacity <= Self.maximumRingSamples
        else { return nil }
        return capacity
    }

    /// - Parameters:
    ///   - directory: Where the file goes. The caller owns the choice so the
    ///     app can put it somewhere the user picked.
    ///   - format: Container and encoding.
    ///   - channels: Channels to record.
    ///   - sampleRate: Rate of the material being recorded.
    ///   - timestamp: Used in the file name. Passed in rather than read here so
    ///     the name is reproducible in a test.
    ///   - name: Appended to the file name, so several files written at the
    ///     same instant do not collide and can be told apart afterwards.
    /// - Throws: Whatever `AVAudioFile` throws when the destination cannot be
    ///   created — a directory that does not exist, or is not writable.
    public init(
        directory: URL, format: Format, channels: Int, sampleRate: Double,
        timestamp: Date, name: String? = nil
    ) throws {
        guard
            let admittedCapacity = Self.ringSampleCapacity(
                sampleRate: sampleRate, channels: channels),
            let capacity = UInt32(exactly: admittedCapacity)
        else { throw RecorderError.couldNotAllocate }

        self.channels = channels
        self.sampleRate = sampleRate

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        // A stem's own name in the file, because "YunAudio 2026-07-28 01.12.33"
        // three times over is not something anybody can sort out later.
        let suffix = name.map { " \(Self.sanitised($0))" } ?? ""
        url = directory.appendingPathComponent(
            "YunAudio \(stamp.string(from: timestamp))\(suffix).\(format.fileExtension)")

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
        guard let ring = yun_rt_ring_create(capacity) else {
            throw RecorderError.couldNotAllocate
        }
        self.ring = ring

        let thread = Thread { [weak self] in
            self?.drain()
            self?.writerFinished.leave()
        }
        thread.name = "com.yuhuanstudio.yunaudio.recorder"
        thread.qualityOfService = .utility
        writerFinished.enter()
        thread.start()
        writer = thread
    }

    deinit { yun_rt_ring_free(ring) }

    /// Realtime side. Never blocks; drops rather than waits when the ring is
    /// full, because stalling the IO thread would cost the live signal as well
    /// as the recording.
    @inline(__always)
    public func write(_ samples: UnsafePointer<Float>, count: Int) {
        guard let count = UInt32(exactly: count) else { return }
        _ = yun_rt_ring_write(ring, samples, count)
    }

    /// Tells the writer to drain and exit without waiting for storage.
    ///
    /// Split from the join so every stem can be woken before a slow file is
    /// awaited. Only the recording finalisation lane calls the two halves
    /// separately; ordinary callers retain the synchronous `stop()` contract.
    func requestStop() {
        let shouldWake = stopLock.withLock {
            guard writer != nil else { return false }
            isStopping = true
            return true
        }
        if shouldWake { writerWake.signal() }
    }

    /// Joins a requested stop only until the caller's monotonic deadline.
    ///
    /// False means the recorder still owns its ring and writer. Its caller must
    /// retain the recorder; releasing it would turn a storage timeout into an
    /// IO-thread use-after-free.
    func joinWriter(until deadline: DispatchTime) -> Bool {
        guard stopLock.withLock({ writer != nil }) else { return true }
        guard writerFinished.wait(timeout: deadline) == .success else { return false }
        stopLock.withLock { writer = nil }
        return true
    }

    public func stop() {
        requestStop()
        // The writer normally sleeps for 100 ms between empty reads. Waking it
        // directly makes an idle stop immediate without raising its permanent
        // wake rate, and the completion semaphore is a real join rather than a
        // 20 ms polling loop on whichever thread asked to stop.
        _ = joinWriter(until: .distantFuture)
    }

    /// Makes the ordering testable without asking wall-clock scheduling to
    /// prove that an explicit wake happened.
    static func wakeWriterAndJoin(signal: () -> Void, wait: () -> Void) {
        signal()
        wait()
    }

    /// Waits until the writer has entered the loop that `stop()` wakes.
    ///
    /// Starting a `Thread` schedules it; it does not mean the thread has run.
    /// Keeping that distinction observable lets the stop-latency test measure
    /// the explicit wake rather than how long a saturated machine took to
    /// schedule a brand-new utility thread.
    func waitUntilWriterIsReady(timeout: DispatchTime) -> Bool {
        guard writerReady.wait(timeout: timeout) == .success else { return false }
        writerReady.signal()
        return true
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
        writerReady.signal()

        while true {
            let stopping = shouldStop
            let read = scratch.withUnsafeMutableBufferPointer {
                Int(yun_rt_ring_read(ring, $0.baseAddress!, UInt32($0.count)))
            }
            if read == 0 {
                if stopping { break }
                _ = writerWake.wait(timeout: .now() + .milliseconds(100))
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
                progressLock.lock()
                storedFramesWritten += Int64(frames)
                progressLock.unlock()
            } catch {
                progressLock.lock()
                storedLastError = error.localizedDescription
                progressLock.unlock()
                break
            }
        }
    }

    /// Samples the realtime side had to drop because the writer fell behind.
    public var droppedSamples: UInt64 { yun_rt_ring_dropped(ring) }

    /// Samples the realtime producer offered to this recorder's ring.
    public var producedSamples: UInt64 { UInt64(yun_rt_ring_written(ring)) }

    /// An application's name can contain anything, including a path separator.
    public static func sanitised(_ name: String) -> String {
        let allowed = name.map { character -> Character in
            character == "/" || character == ":" ? "-" : character
        }
        return String(allowed).trimmingCharacters(in: .whitespaces)
    }

    public var duration: TimeInterval {
        progressSnapshot.duration
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
