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
                self.sampleRate = sampleRate
                self.cooldownSamples = 0
            }
            if cooldownSamples > 0 {
                cooldownSamples = max(0, cooldownSamples - samples.count)
                return
            }
            self.pending.append(contentsOf: samples)
            self.startMatchWhenReady()
        }
    }

    func reset() {
        queue.async { [self] in
            pending.removeAll(keepingCapacity: true)
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

        let samples = Array(pending.prefix(queryCount))
        pending.removeAll(keepingCapacity: true)
        isMatching = true
        let requestedGeneration = generation

        guard let buffer = Self.buffer(samples: samples, sampleRate: sampleRate) else {
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
                let duration = item.timeRanges.map(\.upperBound).max() ?? 0
                let answer = Match(
                    title: title, artist: artist, album: item.subtitle ?? "",
                    identity: item.shazamID.map { "shazam:\($0)" }
                        ?? "shazam:\(artist):\(title)",
                    position: max(0, item.predictedCurrentMatchOffset),
                    duration: max(duration, item.predictedCurrentMatchOffset),
                    confidence: item.confidence)
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

    /// A separate pure construction point so the frame count and sample
    /// values can be asserted without making a network match.
    static func buffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: source.count)
        }
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
