import Darwin
import Foundation
import YunAudioEngine

struct TranscriptSaveRequest: Sendable {
    let generation: UInt64
    /// Immutable COW pages, preserving the store's bounded ownership shape.
    let pages: [[Transcriber.Line]]
    let directory: URL?
    let date: Date
    let timeout: Duration

    init(
        generation: UInt64,
        lines: [Transcriber.Line],
        directory: URL? = nil,
        date: Date = Date(),
        timeout: Duration = TranscriptSaveOperation.defaultTimeout
    ) {
        self.generation = generation
        pages = lines.isEmpty ? [] : [lines]
        self.directory = directory
        self.date = date
        self.timeout = timeout
    }

    init(
        generation: UInt64,
        pages: [[Transcriber.Line]],
        directory: URL? = nil,
        date: Date = Date(),
        timeout: Duration = TranscriptSaveOperation.defaultTimeout
    ) {
        self.generation = generation
        self.pages = pages
        self.directory = directory
        self.date = date
        self.timeout = timeout
    }

    var lineCount: Int {
        pages.reduce(into: 0) { count, page in
            let addition = count.addingReportingOverflow(page.count)
            count = addition.overflow ? Int.max : addition.partialValue
        }
    }
}

enum TranscriptSaveFailure: Sendable, Equatable {
    case empty
    case tooManyLines
    case inputTooLarge
    case timedOut
    case writeFailed
}

struct TranscriptSaveSnapshot: Sendable, Equatable {
    let generation: UInt64
    let outputURL: URL?
    let linesWritten: Int
    let bytesWritten: Int
    let failure: TranscriptSaveFailure?
}

enum TranscriptAtomicWriteResult: Sendable, Equatable {
    case complete
    case timedOut
    case failed
}

struct TranscriptFileSystem: Sendable {
    let writeAtomically:
        @Sendable (Data, URL, ExternalIODeadline) -> TranscriptAtomicWriteResult

    static let system = TranscriptFileSystem { data, url, deadline in
        guard !deadline.hasExpired else { return .timedOut }
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".transcript-\(UUID().uuidString).tmp")
        let descriptor = open(
            temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return .failed }
        var isOpen = true
        var wasRenamed = false
        defer {
            if isOpen { _ = close(descriptor) }
            if !wasRenamed { _ = unlink(temporary.path) }
        }

        let wroteEverything = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < raw.count {
                guard !deadline.hasExpired else { return false }
                let count = Darwin.write(
                    descriptor, base.advanced(by: offset), raw.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wroteEverything else {
            return deadline.hasExpired ? .timedOut : .failed
        }
        guard fsync(descriptor) == 0 else {
            return deadline.hasExpired ? .timedOut : .failed
        }
        let closeStatus = close(descriptor)
        isOpen = false
        guard closeStatus == 0, !deadline.hasExpired else {
            return deadline.hasExpired ? .timedOut : .failed
        }
        guard rename(temporary.path, url.path) == 0 else { return .failed }
        wasRenamed = true
        return .complete
    }
}

/// Formats and atomically writes one immutable transcript snapshot off MainActor.
enum TranscriptSaveOperation {
    static let defaultTimeout: Duration = .seconds(2)
    static let maximumLines = 100_000
    static let maximumSpeakerBytes = 4 * 1_024
    static let maximumTextBytes = 1 * 1_024 * 1_024
    static let maximumOutputBytes = 16 * 1_024 * 1_024
    static let maximumTimestampSeconds: UInt64 = 7 * 24 * 60 * 60

    static func save(
        _ request: TranscriptSaveRequest,
        fileSystem: TranscriptFileSystem = .system
    ) -> TranscriptSaveSnapshot {
        let lineCount = request.lineCount
        guard lineCount > 0 else { return failed(request, .empty) }
        guard lineCount <= maximumLines else {
            return failed(request, .tooManyLines)
        }
        let deadline = ExternalIODeadline(timeout: request.timeout)
        guard !deadline.hasExpired else { return failed(request, .timedOut) }

        var output = Data()
        output.reserveCapacity(min(maximumOutputBytes, lineCount * 96))
        var index = 0
        for page in request.pages {
            for line in page {
                guard !deadline.hasExpired else { return failed(request, .timedOut) }
                let speakerBytes = line.speaker.utf8.count
                let textBytes = line.text.utf8.count
                guard speakerBytes <= maximumSpeakerBytes, textBytes <= maximumTextBytes else {
                    return failed(request, .inputTooLarge)
                }
                let seconds = boundedSeconds(line.start)
                let prefix = String(
                    format: "[%02llu:%02llu] ", seconds / 60, seconds % 60)
                let separatorBytes = index + 1 == lineCount ? 2 : 3
                let required = saturatingSum(
                    [prefix.utf8.count, speakerBytes, textBytes, separatorBytes],
                    ceiling: maximumOutputBytes + 1)
                guard required <= maximumOutputBytes - min(output.count, maximumOutputBytes)
                else {
                    return failed(request, .inputTooLarge)
                }
                output.append(contentsOf: prefix.utf8)
                output.append(contentsOf: line.speaker.utf8)
                output.append(contentsOf: ": ".utf8)
                output.append(contentsOf: line.text.utf8)
                if index + 1 != lineCount { output.append(0x0A) }
                index += 1
            }
        }

        guard !deadline.hasExpired else { return failed(request, .timedOut) }
        let directory = request.directory ?? defaultDirectory()
        let url = destination(in: directory, date: request.date)
        switch fileSystem.writeAtomically(output, url, deadline) {
        case .complete:
            return TranscriptSaveSnapshot(
                generation: request.generation,
                outputURL: url,
                linesWritten: lineCount,
                bytesWritten: output.count,
                failure: nil)
        case .timedOut:
            return failed(request, .timedOut)
        case .failed:
            return failed(request, .writeFailed)
        }
    }

    static func destination(in directory: URL, date: Date) -> URL {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [
            .withYear, .withMonth, .withDay, .withTime, .withFractionalSeconds,
        ]
        let name = stamp.string(from: date).replacingOccurrences(of: ":", with: "-")
        return directory.appendingPathComponent("YunAudio \(name).txt")
    }

    private static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    private static func boundedSeconds(_ value: Double) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        return UInt64(min(value.rounded(.down), Double(maximumTimestampSeconds)))
    }

    private static func saturatingSum(_ values: [Int], ceiling: Int) -> Int {
        var result = 0
        for value in values where value > 0 {
            guard result < ceiling else { return ceiling }
            result += min(value, ceiling - result)
        }
        return result
    }

    private static func failed(
        _ request: TranscriptSaveRequest, _ failure: TranscriptSaveFailure
    ) -> TranscriptSaveSnapshot {
        TranscriptSaveSnapshot(
            generation: request.generation,
            outputURL: nil,
            linesWritten: 0,
            bytesWritten: 0,
            failure: failure)
    }
}

final class TranscriptSaveWorker: @unchecked Sendable {
    private let lane: LatestExternalWorkLane<TranscriptSaveRequest, TranscriptSaveSnapshot>

    init(
        fileSystem: TranscriptFileSystem = .system,
        publish: @escaping @MainActor @Sendable (TranscriptSaveSnapshot) -> Void
    ) {
        lane = LatestExternalWorkLane(
            queue: DispatchQueue(
                label: "com.yuhuanstudio.yunaudio.transcript-save", qos: .utility),
            apply: { TranscriptSaveOperation.save($0, fileSystem: fileSystem) },
            publish: publish)
    }

    var statistics:
        LatestExternalWorkLane<
            TranscriptSaveRequest, TranscriptSaveSnapshot
        >.Statistics
    {
        lane.statistics
    }

    @discardableResult
    func submit(_ request: TranscriptSaveRequest) -> Bool { lane.submit(request) }

    func invalidate() { lane.invalidate() }

    func shutdown() { lane.shutdown() }
}
