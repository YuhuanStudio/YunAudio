import Foundation
import ImageIO

/// A decoded, display-sized cover that can safely cross from a utility task.
struct DecodedSongArtwork: @unchecked Sendable {
    let image: CGImage
    let cost: Int
}

/// ImageIO decoding kept off the main actor and bounded to what the view draws.
enum SongArtworkDecoder {
    static func decode(_ data: Data, maxPixelSize: Int) -> DecodedSongArtwork? {
        guard maxPixelSize > 0,
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary)
        else { return nil }
        return DecodedSongArtwork(
            image: image,
            cost: image.bytesPerRow * image.height)
    }
}

/// Coalesces concurrent resource work and retains only successful, recent values.
///
/// Loading and decoding are injected so the concurrency and memory contracts can
/// be asserted without networking, files or AppKit.
actor SingleFlightResourceStore<Value: Sendable> {
    typealias Loader = @Sendable (URL, Int) async throws -> Data
    typealias Decoder = @Sendable (Data) async -> Value?
    typealias Cost = @Sendable (Value) -> Int

    private struct Cached: Sendable {
        let value: Value
        let cost: Int
    }

    private struct Flight: Sendable {
        let identifier: UInt64
        let task: Task<Value?, Never>
        var waiters: Set<UInt64>
    }

    private let maximumInputBytes: Int
    private let countLimit: Int
    private let totalCostLimit: Int
    private let loader: Loader
    private let decoder: Decoder
    private let cost: Cost

    private var nextFlightIdentifier: UInt64 = 0
    private var nextWaiterIdentifier: UInt64 = 0
    private var flights: [URL: Flight] = [:]
    private var cached: [URL: Cached] = [:]
    private var recency: [URL] = []
    private var totalCost = 0

    init(
        maximumInputBytes: Int,
        countLimit: Int,
        totalCostLimit: Int,
        loader: @escaping Loader,
        decoder: @escaping Decoder,
        cost: @escaping Cost
    ) {
        self.maximumInputBytes = max(0, maximumInputBytes)
        self.countLimit = max(0, countLimit)
        self.totalCostLimit = max(0, totalCostLimit)
        self.loader = loader
        self.decoder = decoder
        self.cost = cost
    }

    func value(for url: URL) async -> Value? {
        guard !Task.isCancelled else { return nil }
        if let hit = cached[url] {
            markMostRecent(url)
            return Task.isCancelled ? nil : hit.value
        }

        nextWaiterIdentifier &+= 1
        let waiterIdentifier = nextWaiterIdentifier
        let flight: Flight
        if var pending = flights[url] {
            pending.waiters.insert(waiterIdentifier)
            flights[url] = pending
            flight = pending
        } else {
            nextFlightIdentifier &+= 1
            let identifier = nextFlightIdentifier
            let maximumInputBytes = maximumInputBytes
            let loader = loader
            let decoder = decoder
            let task: Task<Value?, Never> = Task.detached(priority: .utility) {
                do {
                    try Task.checkCancellation()
                    guard maximumInputBytes > 0 else { return nil }
                    let data = try await loader(url, maximumInputBytes)
                    try Task.checkCancellation()
                    guard data.count <= maximumInputBytes else { return nil }
                    let value = await decoder(data)
                    try Task.checkCancellation()
                    return value
                } catch {
                    return nil
                }
            }
            flight = Flight(
                identifier: identifier,
                task: task,
                waiters: [waiterIdentifier])
            flights[url] = flight
        }

        return await withTaskCancellationHandler {
            let value = await flight.task.value
            return finish(
                url: url,
                flightIdentifier: flight.identifier,
                waiterIdentifier: waiterIdentifier,
                value: value,
                callerWasCancelled: Task.isCancelled)
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    url: url,
                    flightIdentifier: flight.identifier,
                    waiterIdentifier: waiterIdentifier)
            }
        }
    }

    var cachedCount: Int {
        cached.count
    }

    var cachedCost: Int {
        totalCost
    }

    func waiterCount(for url: URL) -> Int {
        flights[url]?.waiters.count ?? 0
    }

    /// How long an abandoned flight is kept before it is cancelled.
    ///
    /// Long enough for a view rebuild to re-subscribe — that happens in the
    /// same run loop turn — and short enough that a song nobody is waiting for
    /// stops downloading promptly.
    nonisolated var abandonedFlightGrace: Double { 1.5 }

    private func cancelIfStillAbandoned(url: URL, flightIdentifier: UInt64) {
        guard let flight = flights[url],
            flight.identifier == flightIdentifier,
            flight.waiters.isEmpty
        else { return }
        flights[url] = nil
        flight.task.cancel()
    }

    private func cancelWaiter(
        url: URL,
        flightIdentifier: UInt64,
        waiterIdentifier: UInt64
    ) {
        guard var flight = flights[url],
            flight.identifier == flightIdentifier,
            flight.waiters.remove(waiterIdentifier) != nil
        else { return }
        if flight.waiters.isEmpty {
            // Not cancelled on the spot. A caller that goes away is routinely
            // not a caller losing interest: SwiftUI cancels a `.task` whenever
            // the view holding it is rebuilt, and the KTV stage rebuilds
            // whenever the window crosses an arrangement boundary. Every
            // capture of that stage reported `artwork cancelled` — the download
            // started, a rebuild killed it, it started again and was killed
            // again, so the cover never arrived and the placeholder was
            // permanent.
            //
            // A grace period tells the two apart without the store having to
            // know which happened. A rebuild re-subscribes within milliseconds
            // and joins the flight already running; a song that has genuinely
            // changed never comes back, and its flight is cancelled — which is
            // what stops an obsolete URL publishing over a current one.
            flights[url] = flight
            Task { [grace = abandonedFlightGrace] in
                try? await Task.sleep(for: .seconds(grace))
                self.cancelIfStillAbandoned(
                    url: url, flightIdentifier: flightIdentifier)
            }
        } else {
            flights[url] = flight
        }
    }

    private func finish(
        url: URL,
        flightIdentifier: UInt64,
        waiterIdentifier: UInt64,
        value: Value?,
        callerWasCancelled: Bool
    ) -> Value? {
        guard var flight = flights[url],
            flight.identifier == flightIdentifier,
            flight.waiters.remove(waiterIdentifier) != nil
        else { return callerWasCancelled ? nil : value }

        if flight.waiters.isEmpty {
            flights[url] = nil
            if let value {
                insert(value, for: url)
            }
        } else {
            flights[url] = flight
        }
        return callerWasCancelled ? nil : value
    }

    private func insert(_ value: Value, for url: URL) {
        let valueCost = max(0, cost(value))
        guard countLimit > 0, valueCost <= totalCostLimit else { return }

        if let previous = cached.updateValue(
            Cached(value: value, cost: valueCost), forKey: url)
        {
            totalCost -= previous.cost
        }
        totalCost += valueCost
        markMostRecent(url)

        while cached.count > countLimit || totalCost > totalCostLimit {
            guard let oldest = recency.first else { break }
            recency.removeFirst()
            if let removed = cached.removeValue(forKey: oldest) {
                totalCost -= removed.cost
            }
        }
    }

    private func markMostRecent(_ url: URL) {
        if let index = recency.firstIndex(of: url) {
            recency.remove(at: index)
        }
        recency.append(url)
    }
}

/// Reads compressed image bytes without allowing an artwork source to consume
/// unbounded memory before ImageIO gets a chance to reject it.
enum SongArtworkDataLoader {
    enum LoadError: Error {
        case unsupportedURL
        case unsuccessfulResponse
        case inputTooLarge
    }

    static func load(_ url: URL, maximumBytes: Int) async throws -> Data {
        guard maximumBytes > 0 else { throw LoadError.inputTooLarge }
        if url.isFileURL {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = values.fileSize, fileSize > maximumBytes {
                throw LoadError.inputTooLarge
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var data = Data()
            if let fileSize = values.fileSize {
                data.reserveCapacity(fileSize)
            }
            while true {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: 64 * 1_024),
                    !chunk.isEmpty
                else { return data }
                guard chunk.count <= maximumBytes - data.count else {
                    throw LoadError.inputTooLarge
                }
                data.append(chunk)
            }
        }

        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw LoadError.unsupportedURL
        }
        var request = URLRequest(url: url)
        // Image formats are already compressed. Identity transfer encoding
        // makes the streamed byte limit describe both the transfer and input
        // that ImageIO will inspect.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return try await BoundedHTTPTransfer(maximumBytes: maximumBytes)
            .load(request)
    }
}

/// URLSession delivers payloads as bounded chunks. Accumulating those delegate
/// chunks avoids both an unbounded `data(for:)` allocation and AsyncBytes'
/// per-byte suspension overhead.
private final class BoundedHTTPTransfer: NSObject, URLSessionDataDelegate,
    @unchecked Sendable
{
    private let maximumBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func load(_ request: URLRequest) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: queue)
                let task = session.dataTask(with: request)
                let shouldStart = lock.withLock {
                    guard !finished else { return false }
                    self.continuation = continuation
                    self.session = session
                    self.task = task
                    return true
                }
                if shouldStart {
                    task.resume()
                } else {
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard
            let response = response as? HTTPURLResponse,
            (200..<300).contains(response.statusCode)
        else {
            completionHandler(.cancel)
            finish(.failure(SongArtworkDataLoader.LoadError.unsuccessfulResponse))
            return
        }
        guard
            response.expectedContentLength < 0
                || response.expectedContentLength <= Int64(maximumBytes)
        else {
            completionHandler(.cancel)
            finish(.failure(SongArtworkDataLoader.LoadError.inputTooLarge))
            return
        }
        if response.expectedContentLength > 0 {
            lock.withLock {
                data.reserveCapacity(Int(response.expectedContentLength))
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive chunk: Data) {
        let accepted = lock.withLock {
            guard !finished, chunk.count <= maximumBytes - data.count else {
                return false
            }
            data.append(chunk)
            return true
        }
        if !accepted {
            finish(.failure(SongArtworkDataLoader.LoadError.inputTooLarge))
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            finish(.failure(error))
        } else {
            let result = lock.withLock { data }
            finish(.success(result))
        }
    }

    private func cancel() {
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Data, any Error>) {
        let state = lock.withLock {
            guard !finished else {
                return (
                    nil as CheckedContinuation<Data, any Error>?,
                    nil as URLSessionDataTask?,
                    nil as URLSession?
                )
            }
            finished = true
            let state = (continuation, task, session)
            continuation = nil
            task = nil
            session = nil
            return state
        }
        state.1?.cancel()
        state.2?.invalidateAndCancel()
        state.0?.resume(with: result)
    }
}

enum SongArtworkResources {
    static let maximumInputBytes = 8 * 1_024 * 1_024
    static let maximumPixelSize = 256
    static let shared = SingleFlightResourceStore<DecodedSongArtwork>(
        maximumInputBytes: maximumInputBytes,
        countLimit: 32,
        totalCostLimit: 8 * 1_024 * 1_024,
        loader: SongArtworkDataLoader.load,
        decoder: { data in
            SongArtworkDecoder.decode(data, maxPixelSize: maximumPixelSize)
        },
        cost: \.cost)
}
