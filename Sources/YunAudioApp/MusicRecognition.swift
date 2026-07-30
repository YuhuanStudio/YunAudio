import AVFAudio
import Foundation
import ShazamKit

/// Public, source-independent now-playing metadata from captured audio.
///
/// QQ Music and NetEase Cloud Music publish no AppleScript dictionary on
/// macOS. Scraping their windows would require Accessibility access and would
/// break whenever either application rearranged a label; MediaRemote is a
/// private framework. ShazamKit instead identifies the exact recording already
/// flowing through YunAudio and returns its reference timecode, so the same
/// path also covers browsers and future players without pretending they expose
/// an integration they do not.
final class MusicRecognition: @unchecked Sendable {

    struct Match: Sendable, Equatable {
        let title: String
        let artist: String
        let album: String
        let identity: String
        let position: Double
        let duration: Double
        let confidence: Float
        let artworkURL: URL?
        let appleMusicURL: URL?
    }

    enum Failure: Error, Sendable, Equatable {
        case catalogueAccessNotEnabled
        case failed(String)
    }

    typealias Handler = @MainActor @Sendable (Result<Match, Failure>) -> Void

    private let queue = DispatchQueue(
        label: "com.yuhuanstudio.yunaudio.music-recognition", qos: .utility)
    private let session = SHSession()
    private let handler: Handler
    private var pending: [Float] = []
    private var sampleRate: Double = 0
    private var isMatching = false
    private var isDisabled = false
    private var generation = 0
    private var cooldownSamples = 0

    /// Six seconds was measured as enough for the specified Chinese release
    /// while keeping the first answer comfortably below one lyric line.
    static let querySeconds: Double = 6
    /// Twelve seconds between completed catalogue attempts. With the six-second
    /// signature this bounds an open panel to about three requests a minute.
    static let retrySeconds: Double = 12
    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Adds mono samples copied from one captured application.
    func add(_ samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty, Self.supportedRates.contains(sampleRate) else { return }
        queue.async { [self] in
            guard !isDisabled else { return }
            if self.sampleRate != sampleRate {
                self.pending.removeAll(keepingCapacity: true)
                self.pending.reserveCapacity(Int(Self.querySeconds * sampleRate))
                self.sampleRate = sampleRate
                self.cooldownSamples = 0
            }
            if cooldownSamples > 0 {
                let split = Self.consumeCooldown(
                    sampleCount: samples.count, cooldownSamples: cooldownSamples)
                cooldownSamples = split.remaining
                guard split.discarded < samples.count else { return }
                pending.append(contentsOf: samples[split.discarded...])
            } else {
                self.pending.append(contentsOf: samples)
            }
            self.startMatchWhenReady()
        }
    }

    /// Invalidates the current request and clears accumulated audio.
    ///
    /// Closing KTV releases the six-second allocation rather than retaining
    /// 1,152,000 bytes for a panel that may never open again.
    func reset(releasingBuffers: Bool = false) {
        queue.async { [self] in
            if releasingBuffers {
                pending = []
            } else {
                pending.removeAll(keepingCapacity: true)
            }
            sampleRate = 0
            isMatching = false
            isDisabled = false
            generation += 1
            cooldownSamples = 0
        }
    }

    private func startMatchWhenReady() {
        guard !isMatching, sampleRate > 0 else { return }
        let queryCount = Int(Self.querySeconds * sampleRate)
        guard pending.count >= queryCount else { return }

        let rate = sampleRate
        let buffer = pending.withUnsafeBufferPointer { samples in
            Self.buffer(
                samples: UnsafeBufferPointer(start: samples.baseAddress, count: queryCount),
                sampleRate: rate)
        }
        pending.removeAll(keepingCapacity: true)
        isMatching = true
        let requestedGeneration = generation

        guard let buffer else {
            isMatching = false
            return
        }
        do {
            let generator = SHSignatureGenerator()
            try generator.append(buffer, at: nil)
            let signature = generator.signature()
            Task { [self] in
                let result = await session.result(from: signature)
                receive(result, generation: requestedGeneration)
            }
        } catch {
            isMatching = false
            let failure = Self.describe(error)
            isDisabled = true
            Task { @MainActor [handler] in handler(.failure(failure)) }
        }
    }

    private func receive(_ result: SHSession.Result, generation requestedGeneration: Int) {
        queue.async { [self] in
            guard requestedGeneration == generation else { return }
            isMatching = false
            // Audio accumulated while the catalogue request was in flight
            // belongs to the same attempt. Starting another request
            // immediately would be a request loop, not faster recognition.
            pending.removeAll(keepingCapacity: true)
            cooldownSamples = Int(Self.retrySeconds * sampleRate)
            switch result {
            case let .match(match):
                guard let item = match.mediaItems.first,
                    let title = item.title?.nonEmpty,
                    let artist = item.artist?.nonEmpty
                else { return }
                let answer = Match(
                    title: title, artist: artist, album: item.subtitle ?? "",
                    identity: item.shazamID.map { "shazam:\($0)" }
                        ?? "shazam:\(artist):\(title)",
                    position: max(0, item.predictedCurrentMatchOffset),
                    // `timeRanges` describe the reference-signature ranges
                    // represented by the match, not the recording's total
                    // duration. Using their upper bound (or the current match
                    // offset) as an end time froze the lyric clock exactly
                    // where QQ Music or NetEase was first recognised.
                    duration: 0,
                    confidence: item.confidence, artworkURL: item.artworkURL,
                    appleMusicURL: item.appleMusicURL)
                Task { @MainActor [handler] in handler(.success(answer)) }
            case .noMatch:
                break
            case let .error(error, _):
                let failure = Self.describe(error)
                isDisabled = true
                Task { @MainActor [handler] in handler(.failure(failure)) }
            }
        }
    }

    static func describe(_ error: Error) -> Failure {
        let cocoa = error as NSError
        if cocoa.domain == "com.apple.ShazamCore", cocoa.code == 102 {
            return .catalogueAccessNotEnabled
        }
        return .failed(cocoa.localizedDescription)
    }

    /// Divides one captured block at the end of a retry cooldown.
    ///
    /// Dropping the whole block delayed a new signature by whatever audio
    /// followed the boundary — up to the full drain size — even though only
    /// the prefix belonged to the cooldown.
    static func consumeCooldown(
        sampleCount: Int, cooldownSamples: Int
    ) -> (discarded: Int, remaining: Int) {
        let discarded = min(max(0, sampleCount), max(0, cooldownSamples))
        return (discarded, max(0, cooldownSamples - discarded))
    }

    /// A separate pure construction point so the frame count and sample
    /// values can be asserted without making a network match.
    static func buffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        samples.withUnsafeBufferPointer {
            buffer(samples: $0, sampleRate: sampleRate)
        }
    }

    /// The signature accumulator already owns six seconds in one contiguous
    /// array. Borrow it so constructing an AVAudio buffer does not first copy
    /// another 1.15 MB at 48 kHz.
    static func buffer(
        samples: UnsafeBufferPointer<Float>, sampleRate: Double
    ) -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let source = samples.baseAddress else { return buffer }
        channel.update(from: source, count: samples.count)
        return buffer
    }

    private static let supportedRates: Set<Double> = [16_000, 32_000, 44_100, 48_000]
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
