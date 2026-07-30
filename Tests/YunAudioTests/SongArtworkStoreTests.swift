import Foundation
import Testing

@testable import YunAudioApp

@Suite("Song artwork resource store")
struct SongArtworkStoreTests {
    @Test("three concurrent views share one load and one decode")
    func concurrentRequestsAreSingleFlight() async {
        let url = URL(string: "https://example.com/shared-cover.png")!
        let probe = ArtworkResourceProbe()
        await probe.configure(url, byte: 7, suspended: true)
        let store = makeStore(probe: probe)

        let requests = (0..<3).map { _ in
            Task { await store.value(for: url) }
        }
        await probe.waitUntilLoaded(url)
        for _ in 0..<16 where await store.waiterCount(for: url) < 3 {
            await Task.yield()
        }

        #expect(await store.waiterCount(for: url) == 3)
        #expect(await probe.loadCount(for: url) == 1)
        await probe.release(url)
        var values: [Int?] = []
        for request in requests {
            values.append(await request.value)
        }

        #expect(values.compactMap(\.self) == [7, 7, 7])
        #expect(await probe.loadCount(for: url) == 1)
        #expect(await probe.decodeCount == 1)
    }

    @Test("a cancelled old URL cannot publish after a new URL")
    func cancellationSuppressesObsoleteResult() async {
        let oldURL = URL(string: "https://example.com/old.png")!
        let newURL = URL(string: "https://example.com/new.png")!
        let probe = ArtworkResourceProbe()
        await probe.configure(oldURL, byte: 1, suspended: true)
        await probe.configure(newURL, byte: 2)
        let store = makeStore(probe: probe)

        let obsolete = Task { await store.value(for: oldURL) }
        await probe.waitUntilLoaded(oldURL)
        obsolete.cancel()
        await probe.waitUntilCancelled(oldURL)
        let current = Task { await store.value(for: newURL) }
        let currentValue = await current.value
        let obsoleteValue = await obsolete.value

        #expect(currentValue == 2)
        #expect(obsoleteValue == nil)
        #expect(await probe.cancellationCount(for: oldURL) == 1)
        #expect(await probe.decodeCount == 1)
    }

    @Test("cancelling one waiter keeps a shared flight alive")
    func oneCancellationDoesNotCancelOtherWaiters() async {
        let url = URL(string: "https://example.com/two-views.png")!
        let probe = ArtworkResourceProbe()
        await probe.configure(url, byte: 4, suspended: true)
        let store = makeStore(probe: probe)

        let cancelled = Task { await store.value(for: url) }
        let survivor = Task { await store.value(for: url) }
        await probe.waitUntilLoaded(url)
        for _ in 0..<16 where await store.waiterCount(for: url) < 2 {
            await Task.yield()
        }
        #expect(await store.waiterCount(for: url) == 2)

        cancelled.cancel()
        for _ in 0..<8 {
            await Task.yield()
        }
        #expect(await probe.cancellationCount(for: url) == 0)
        await probe.release(url)

        #expect(await cancelled.value == nil)
        #expect(await survivor.value == 4)
        #expect(await probe.loadCount(for: url) == 1)
        #expect(await probe.decodeCount == 1)
    }

    @Test("oversized compressed input is rejected before decode")
    func oversizedInputSkipsDecoder() async {
        let url = URL(string: "https://example.com/oversized.png")!
        let probe = ArtworkResourceProbe()
        await probe.configure(url, byte: 3, count: 65)
        let store = makeStore(probe: probe, maximumInputBytes: 64)

        #expect(await store.value(for: url) == nil)
        #expect(await probe.loadCount(for: url) == 1)
        #expect(await probe.decodeCount == 0)
        #expect(await store.cachedCount == 0)
    }

    @Test("decoded cache stays within count and cost limits")
    func cacheIsBounded() async {
        let urls = (0..<3).map {
            URL(string: "https://example.com/cover-\($0).png")!
        }
        let probe = ArtworkResourceProbe()
        for (index, url) in urls.enumerated() {
            await probe.configure(url, byte: UInt8(index + 1))
        }
        let store = makeStore(
            probe: probe,
            countLimit: 2,
            totalCostLimit: 2)

        for url in urls {
            _ = await store.value(for: url)
        }
        #expect(await store.cachedCount == 2)
        #expect(await store.cachedCost == 2)

        #expect(await store.value(for: urls[0]) == 1)
        #expect(await probe.totalLoadCount == 4)
        #expect(await store.cachedCount == 2)
        #expect(await store.cachedCost == 2)
    }

    @Test("a failed load is not cached")
    func failureDoesNotPoisonCache() async {
        let url = URL(string: "https://example.com/retry.png")!
        let probe = ArtworkResourceProbe()
        await probe.configure(url, byte: 9, failures: 1)
        let store = makeStore(probe: probe)

        #expect(await store.value(for: url) == nil)
        #expect(await store.cachedCount == 0)
        #expect(await store.value(for: url) == 9)
        #expect(await probe.loadCount(for: url) == 2)
        #expect(await probe.decodeCount == 1)
        #expect(await store.cachedCount == 1)
    }

    private func makeStore(
        probe: ArtworkResourceProbe,
        maximumInputBytes: Int = 1_024,
        countLimit: Int = 8,
        totalCostLimit: Int = 8
    ) -> SingleFlightResourceStore<Int> {
        SingleFlightResourceStore(
            maximumInputBytes: maximumInputBytes,
            countLimit: countLimit,
            totalCostLimit: totalCostLimit,
            loader: { url, maximumBytes in
                try await probe.load(url, maximumBytes: maximumBytes)
            },
            decoder: { data in
                await probe.decode(data)
            },
            cost: { _ in 1 })
    }
}

private actor ArtworkResourceProbe {
    private struct Configuration {
        let data: Data
        var failures: Int
        var suspended: Bool
    }

    private enum ProbeError: Error {
        case requestedFailure
    }

    private var configurations: [URL: Configuration] = [:]
    private var loads: [URL: Int] = [:]
    private var startedWaiters: [URL: [CheckedContinuation<Void, Never>]] = [:]
    private var cancelledWaiters: [URL: [CheckedContinuation<Void, Never>]] = [:]
    private var cancellations: [URL: Int] = [:]
    private(set) var decodeCount = 0

    var totalLoadCount: Int {
        loads.values.reduce(0, +)
    }

    func configure(
        _ url: URL,
        byte: UInt8,
        count: Int = 1,
        failures: Int = 0,
        suspended: Bool = false
    ) {
        configurations[url] = Configuration(
            data: Data(repeating: byte, count: count),
            failures: failures,
            suspended: suspended)
    }

    func load(_ url: URL, maximumBytes _: Int) async throws -> Data {
        loads[url, default: 0] += 1
        let waiters = startedWaiters.removeValue(forKey: url) ?? []
        for waiter in waiters {
            waiter.resume()
        }

        guard var configuration = configurations[url] else {
            throw ProbeError.requestedFailure
        }
        if configuration.failures > 0 {
            configuration.failures -= 1
            configurations[url] = configuration
            throw ProbeError.requestedFailure
        }
        if configuration.suspended {
            do {
                while configurations[url]?.suspended == true {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            } catch {
                cancellations[url, default: 0] += 1
                let waiters = cancelledWaiters.removeValue(forKey: url) ?? []
                for waiter in waiters {
                    waiter.resume()
                }
                throw error
            }
        }
        return configuration.data
    }

    func decode(_ data: Data) -> Int? {
        decodeCount += 1
        return data.first.map(Int.init)
    }

    func loadCount(for url: URL) -> Int {
        loads[url, default: 0]
    }

    func waitUntilLoaded(_ url: URL) async {
        guard loads[url, default: 0] == 0 else { return }
        await withCheckedContinuation { continuation in
            startedWaiters[url, default: []].append(continuation)
        }
    }

    func release(_ url: URL) {
        if var configuration = configurations[url] {
            configuration.suspended = false
            configurations[url] = configuration
        }
    }

    func cancellationCount(for url: URL) -> Int {
        cancellations[url, default: 0]
    }

    func waitUntilCancelled(_ url: URL) async {
        guard cancellations[url, default: 0] == 0 else { return }
        await withCheckedContinuation { continuation in
            cancelledWaiters[url, default: []].append(continuation)
        }
    }
}
