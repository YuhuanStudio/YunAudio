import Foundation
import Testing

@testable import YunAudioApp
@testable import YunAudioEngine

private final class TranscriptMailboxFlushCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var isComplete = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumes = lock.withLock {
                guard !isComplete else { return true }
                self.continuation = continuation
                return false
            }
            if resumes { continuation.resume() }
        }
    }

    func resolve() {
        let continuation = lock.withLock {
            isComplete = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}

private final class TranscriptHeldMainScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [@MainActor @Sendable () -> Void] = []

    func schedule(_ operation: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock { operations.append(operation) }
    }

    var count: Int { lock.withLock { operations.count } }

    @MainActor
    func runFirst() {
        let operation = lock.withLock { operations.removeFirst() }
        operation()
    }

    @MainActor
    func runAll() {
        while count > 0 { runFirst() }
    }
}

private final class TranscriptPageSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [[Transcriber.Line]]?

    func replace(_ pages: [[Transcriber.Line]]?) {
        lock.withLock { self.pages = pages }
    }

    var snapshot: [[Transcriber.Line]]? { lock.withLock { pages } }
}

@Suite("Paged transcript storage")
struct TranscriptPagedStoreTests {
    private func line(
        _ value: Int, id: UUID = UUID(), text: String? = nil,
        start: Double? = nil
    ) -> Transcriber.Line {
        Transcriber.Line(
            id: id, speaker: "Source \(value)", text: text ?? "line \(value)",
            start: start ?? Double(value), duration: 0.5)
    }

    @Test("one hundred thousand lines occupy 782 bounded pages")
    func exactPageBoundary() {
        #expect(TranscriptPagedStore.pageSize == 128)
        #expect(
            (TranscriptPagedStore.maximumLines + TranscriptPagedStore.pageSize - 1)
                / TranscriptPagedStore.pageSize == 782)
        #expect(TranscriptPagedStore.visibleLineLimit == 256)
        #expect(TranscriptPagedStore.maximumSerialisedBytes == 16_777_216)
        #expect(TranscriptPagedStore.maximumTextBytes == 65_536)
    }

    @Test("UUID deduplication makes callback plus stop catch-up exact once")
    func stopCatchUpIsExactOnce() {
        var store = TranscriptPagedStore()
        let id = UUID()
        let finalised = line(1, id: id)

        let callback = store.append(finalised)
        let stopCatchUp = store.append(finalised)

        #expect(callback.accepted)
        #expect(!stopCatchUp.accepted)
        #expect(stopCatchUp.refusal == .duplicate)
        #expect(store.count == 1)
        #expect(store.statistics.duplicateLines == 1)
    }

    @Test("batch merge is chronological and page sized")
    func chronologicalPages() {
        var store = TranscriptPagedStore()
        let input = (0..<300).reversed().map { line($0) }

        let admissions = store.appendBatch(input)

        #expect(admissions.allSatisfy { $0.accepted })
        #expect(store.statistics.lines == 300)
        #expect(store.statistics.pages == 3)
        #expect(store.page(at: 0)?.count == 128)
        #expect(store.page(at: 1)?.count == 128)
        #expect(store.page(at: 2)?.count == 44)
        #expect(store.page(at: 0)?.first?.start == 0)
        #expect(store.page(at: 2)?.last?.start == 299)
        #expect(store.visibleLines().count == 256)
        #expect(store.visibleLines().first?.start == 44)
        #expect(store.visibleLines().last?.start == 299)
    }

    @Test("two visible pages preserve the exact last 256 of 257 lines")
    func visibleWindowOrder() {
        var store = TranscriptPagedStore()
        #expect(store.appendBatch((0..<257).map { line($0) }).allSatisfy { $0.accepted })

        #expect(store.visibleLines().map(\.text) == (1..<257).map { "line \($0)" })
    }

    @Test("the transcript card virtualises its bounded visible window")
    func transcriptCardIsLazy() throws {
        let root = PreferencesCompletenessTests.sourceRootForTests
        let source = try String(
            contentsOfFile: root + "Sources/YunAudioApp/MainWindow.swift",
            encoding: .utf8)
        let start = try #require(source.range(of: "private var transcription: some View"))
        let end = try #require(
            source.range(
                of: "private func transcriptLine",
                range: start.upperBound..<source.endIndex))
        let card = source[start.lowerBound..<end.lowerBound]

        #expect(card.contains("LazyVStack("))
        #expect(!card.contains("ForEach(model.transcript.prefix"))
        #expect(TranscriptPagedStore.visibleLineLimit == 256)
    }

    @Test("UTF-8 accounting includes the saved prefix separators and newline")
    func byteAccounting() throws {
        let value = Transcriber.Line(
            speaker: "麥克風", text: "你好", start: 65, duration: 1)
        let expected = "[01:05] 麥克風: 你好\n".utf8.count

        #expect(TranscriptPagedStore.serialisedByteCount(for: value) == expected)
        var store = TranscriptPagedStore()
        let admitted = store.append(value)
        #expect(admitted.serialisedBytes == expected)
        #expect(store.statistics.serialisedBytes == expected)
    }

    @Test("a sixty-four KiB line is accepted and the next byte is refused")
    func perLineTextBoundary() {
        var acceptedStore = TranscriptPagedStore()
        let accepted = acceptedStore.append(
            line(1, text: String(repeating: "x", count: 65_536)))
        var refusedStore = TranscriptPagedStore()
        let refused = refusedStore.append(
            line(2, text: String(repeating: "x", count: 65_537)))

        #expect(accepted.accepted)
        #expect(refused.refusal == .textTooLarge)
        #expect(refusedStore.isEmpty)
    }

    @Test("journal pressure refuses a whole incoming batch without a partial tail")
    func journalBackpressure() {
        var store = TranscriptPagedStore()
        for batch in 0..<TranscriptPagedStore.maximumJournalPages {
            let admissions = store.appendBatch(
                (0..<TranscriptPagedStore.pageSize).map {
                    line(batch * TranscriptPagedStore.pageSize + $0)
                })
            #expect(admissions.allSatisfy { $0.accepted })
        }
        let before = store.statistics
        let refused = store.appendBatch([line(10_000), line(10_001)])

        #expect(refused.map(\.refusal) == [.journalBackpressure, .journalBackpressure])
        #expect(store.count == before.lines)
        #expect(store.statistics.pendingJournalPages == 8)
        #expect(store.pendingJournalPages.map(\.sequence) == Array(1...8))
        store.acknowledgeJournal(through: 1)
        #expect(store.statistics.pendingJournalPages == 7)
        #expect(store.append(line(10_002)).accepted)
    }

    @Test("snapshot mode passes the journal frontier without weakening runtime caps")
    func snapshotModeHasNoJournalBackpressure() {
        var store = TranscriptPagedStore(journalMode: .snapshotOnly)
        let accepted = store.appendBatch(
            (0..<(TranscriptPagedStore.maximumMailboxLines + 1)).map { line($0) })

        #expect(accepted.allSatisfy { $0.accepted })
        #expect(store.count == 1_025)
        #expect(store.statistics.pendingJournalPages == 0)
        #expect(store.statistics.pendingJournalBytes == 0)
        #expect(store.pendingJournalPages.isEmpty)
        #expect(
            store.append(line(2_000, text: String(repeating: "x", count: 65_537)))
                .refusal == .textTooLarge)
        #expect(store.count == 1_025)
        #expect(store.statistics.serialisedBytes < 16_777_216)
    }

    @Test("invalid time and an oversized speaker never enter a page")
    func invalidFields() {
        var store = TranscriptPagedStore()
        let time = store.append(line(1, start: .infinity))
        let speaker = store.append(
            Transcriber.Line(
                speaker: String(repeating: "s", count: 4_097), text: "line",
                start: 0, duration: 1))

        #expect(time.refusal == .invalidTimestamp)
        #expect(speaker.refusal == .speakerTooLarge)
        #expect(store.isEmpty)
        #expect(store.statistics.refusedLines == 2)
    }

    @Test("one hundred thousand interleaved lines stay under the page latency gate")
    func longMeetingLatency() {
        var store = TranscriptPagedStore(journalMode: .snapshotOnly)
        var milliseconds: [Double] = []
        for batchStart in stride(
            from: 0, to: TranscriptPagedStore.maximumLines,
            by: TranscriptPagedStore.pageSize)
        {
            let batchEnd = min(
                batchStart + TranscriptPagedStore.pageSize,
                TranscriptPagedStore.maximumLines)
            // Four sources arrive interleaved and in reverse callback order.
            let batch = (batchStart..<batchEnd).reversed().map { value in
                Transcriber.Line(
                    speaker: "Source \(value % 4)", text: "line \(value)",
                    start: Double(value / 4) + Double(value % 4) / 1_000,
                    duration: 0.5)
            }
            let started = DispatchTime.now().uptimeNanoseconds
            let result = store.appendBatch(batch)
            milliseconds.append(
                Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            #expect(result.allSatisfy { $0.accepted })
        }

        let ordered = milliseconds.sorted()
        let percentile99 = ordered[min(ordered.count - 1, ordered.count * 99 / 100)]
        #expect(store.count == 100_000)
        #expect(store.statistics.pages == 782)
        #expect(store.statistics.pendingJournalPages == 0)
        #expect(percentile99 <= 2)
        #expect((ordered.last ?? .infinity) <= 8)
        let visible = store.visibleWindow()
        #expect(visible.lines.count == 256)
        #expect(visible.pagesVisited == 3)
        #expect(visible.lines.first?.start == 24_936)
        #expect(visible.lines.last?.start == 24_999.003)
        #expect(store.append(line(100_001)).refusal == .lineLimit)
    }

    @Test("a full 1,024-line stop tail flushes within eight milliseconds")
    func fullMailboxStopTailLatency() async {
        let lane = DispatchQueue(label: "yunaudio.transcript-tail.test")
        let releaseLane = DispatchSemaphore(value: 0)
        lane.async { releaseLane.wait() }
        let storeWorker = TranscriptStoreWorker(
            scheduleWork: { work in lane.async(execute: work) },
            publish: { _ in })
        let mailbox = TranscriptLineMailbox(
            schedule: { work in lane.async(execute: work) },
            deliver: { generation, lines in
                storeWorker.receive(lines, generation: generation)
            },
            overflow: { _, _ in Issue.record("the exact-capacity tail overflowed") })
        storeWorker.activate(generation: 7)
        mailbox.activate(generation: 7)
        for value in 0..<TranscriptPagedStore.maximumMailboxLines {
            #expect(mailbox.submit(line(value), generation: 7))
        }
        #expect(mailbox.statistics.pending == 1_024)

        let started = DispatchTime.now().uptimeNanoseconds
        let completion = TranscriptMailboxFlushCompletion()
        mailbox.flush(generation: 7) { completion.resolve() }
        let submission = DispatchTime.now().uptimeNanoseconds - started
        releaseLane.signal()
        await completion.wait()

        #expect(mailbox.statistics.pending == 0)
        #expect(mailbox.statistics.delivered == 1_024)
        #expect(storeWorker.snapshot.statistics.lines == 1_024)
        #expect(storeWorker.snapshot.visibleLines.count == 256)
        #expect(storeWorker.statistics.applications == 17)
        #expect(storeWorker.statistics.mainThreadApplications == 0)
        #expect(storeWorker.statistics.maximumPendingPublications == 1)
        #expect(submission < 8_000_000)
    }

    @MainActor
    @Test("an old queued store publication cannot cover a new transcript")
    func storePublicationGenerationGate() {
        let lane = DispatchQueue(label: "yunaudio.transcript-generation.test")
        let held = TranscriptHeldMainScheduler()
        var published: [TranscriptStoreWorker.Snapshot] = []
        let worker = TranscriptStoreWorker(
            scheduleWork: { work in lane.async(execute: work) },
            scheduleMain: held.schedule,
            publish: { published.append($0) })

        worker.activate(generation: 1)
        lane.sync {}
        #expect(held.count == 1)
        held.runFirst()
        published = []
        let tail = (0..<TranscriptPagedStore.maximumMailboxLines).map { line($0) }
        lane.sync { worker.receive(tail, generation: 1) }
        #expect(worker.snapshot.statistics.lines == 1_024)
        #expect(held.count == 1)

        worker.activate(generation: 2)
        lane.sync {}

        held.runFirst()
        #expect(published.isEmpty)
        #expect(worker.statistics.stalePublications == 1)
        #expect(held.count == 1)
        held.runFirst()

        #expect(published.map(\.generation) == [2])
        #expect(published.first?.statistics.lines == 0)
        #expect(published.first?.visibleLines.isEmpty == true)
        #expect(worker.statistics.publications == 2)
    }

    @MainActor
    @Test("stable updates publish only the tail and full pages require one explicit request")
    func fullPagesAreExplicit() async {
        let lane = DispatchQueue(label: "yunaudio.transcript-pages.test")
        let held = TranscriptHeldMainScheduler()
        let pageSnapshot = TranscriptPageSnapshotBox()
        let worker = TranscriptStoreWorker(
            scheduleWork: { work in lane.async(execute: work) },
            scheduleMain: held.schedule,
            publish: { _ in })
        worker.activate(generation: 9)

        let batchDurations = await withCheckedContinuation { continuation in
            lane.async {
                var durations: [UInt64] = []
                for offset in stride(from: 0, to: 100_000, by: 64) {
                    let lines = (offset..<min(offset + 64, 100_000)).map { value in
                        Transcriber.Line(
                            speaker: "Source \(value)", text: "line \(value)",
                            start: Double(value), duration: 0.5)
                    }
                    let started = DispatchTime.now().uptimeNanoseconds
                    worker.receive(lines, generation: 9)
                    durations.append(DispatchTime.now().uptimeNanoseconds - started)
                }
                continuation.resume(returning: durations)
            }
        }

        #expect(worker.snapshot.statistics.lines == 100_000)
        #expect(worker.snapshot.statistics.pages == 782)
        #expect(worker.snapshot.visibleLines.count == 256)
        #expect(worker.statistics.maximumPendingPublications == 1)
        #expect(worker.statistics.mainThreadApplications == 0)
        #expect(worker.statistics.pageSnapshotRequests == 0)
        #expect((batchDurations.max() ?? .max) < 8_000_000)

        var acceptedRequests = 0
        let started = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<10_000 {
            if worker.requestPages(
                generation: 9,
                completion: { pages in
                    pageSnapshot.replace(pages)
                })
            {
                acceptedRequests += 1
            }
        }
        let submission = DispatchTime.now().uptimeNanoseconds - started
        for _ in 0..<2_000 where held.count < 2 {
            try? await Task.sleep(for: .milliseconds(1))
        }
        held.runAll()

        #expect(acceptedRequests == 1)
        #expect(submission < 8_000_000)
        #expect(pageSnapshot.snapshot?.count == 782)
        #expect(pageSnapshot.snapshot?.reduce(0) { $0 + $1.count } == 100_000)
        #expect(worker.statistics.pageSnapshotRequests == 1)
        #expect(worker.statistics.refusedPageSnapshotRequests == 9_999)
        #expect(worker.statistics.maximumPendingPageSnapshots == 1)
    }

    @Test("runtime byte admission reaches but never crosses sixteen MiB")
    func runtimeByteBoundary() {
        var store = TranscriptPagedStore()
        let text = String(repeating: "x", count: 60 * 1_024)
        var value = 0
        while true {
            let candidate = line(value, text: text)
            let remaining =
                TranscriptPagedStore.maximumSerialisedBytes
                - store.statistics.serialisedBytes
            guard
                let lineBytes = TranscriptPagedStore.serialisedByteCount(for: candidate),
                lineBytes <= remaining
            else { break }
            #expect(store.append(candidate).accepted)
            store.flushJournalStaging()
            if let sequence = store.pendingJournalPages.last?.sequence {
                store.acknowledgeJournal(through: sequence)
            }
            value += 1
        }
        let refused = store.append(line(value, text: text))

        #expect(refused.refusal == .byteLimit)
        #expect(store.statistics.serialisedBytes <= 16_777_216)
        #expect(
            16_777_216 - store.statistics.serialisedBytes
                < (refused.serialisedBytes))
    }

    @Test("acknowledging a sealed page cannot discard newer staged lines")
    func journalAcknowledgementFrontier() throws {
        var store = TranscriptPagedStore()
        #expect(store.append(line(1)).accepted)
        store.flushJournalStaging()
        let oldSequence = try #require(store.pendingJournalPages.first?.sequence)
        #expect(store.append(line(2)).accepted)

        store.acknowledgeJournal(through: oldSequence)

        #expect(store.count == 2)
        #expect(store.statistics.pendingJournalPages == 1)
        #expect(store.statistics.pendingJournalBytes > 0)
        #expect(store.pendingJournalPages.isEmpty)
        store.flushJournalStaging()
        #expect(store.pendingJournalPages.map { $0.lines.first?.text } == ["line 2"])
    }
}

@MainActor
@Suite("Transcript line mailbox")
struct TranscriptLineMailboxTests {
    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) { self.value = value }

        func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
        var snapshot: Value { lock.withLock { value } }
    }

    private final class Scheduled: @unchecked Sendable {
        private let lock = NSLock()
        private var work: [@Sendable () -> Void] = []

        func schedule(_ body: @escaping @Sendable () -> Void) {
            lock.withLock { work.append(body) }
        }

        func runOne() {
            let next = lock.withLock { work.isEmpty ? nil : work.removeFirst() }
            next?()
        }

        var count: Int { lock.withLock { work.count } }
    }

    private func line(_ value: Int) -> Transcriber.Line {
        Transcriber.Line(
            speaker: "Source", text: "\(value)", start: Double(value), duration: 1)
    }

    @Test("generation zero is closed until a session is explicitly activated")
    func startsClosed() {
        let scheduled = Scheduled()
        let received = LockedBox(0)
        let mailbox = TranscriptLineMailbox(
            schedule: scheduled.schedule,
            deliver: { _, lines in received.update { $0 += lines.count } },
            overflow: { _, _ in })

        #expect(!mailbox.submit(line(0), generation: 0))
        #expect(mailbox.statistics.pending == 0)
        #expect(mailbox.statistics.revoked == 1)
        #expect(scheduled.count == 0)
        #expect(received.snapshot == 0)
    }

    @Test("ten thousand producers retain one bounded off-main drain")
    func stormIsBounded() async {
        let scheduled = Scheduled()
        let received = LockedBox<[Transcriber.Line]>([])
        var overflows = 0
        let mailbox = TranscriptLineMailbox(
            schedule: scheduled.schedule,
            deliver: { _, lines in received.update { $0.append(contentsOf: lines) } },
            overflow: { _, _ in overflows += 1 })
        mailbox.activate(generation: 7)

        for value in 0..<10_000 { _ = mailbox.submit(line(value), generation: 7) }

        #expect(mailbox.statistics.pending == 1_024)
        #expect(mailbox.statistics.maximumPending == 1_024)
        #expect(mailbox.statistics.overflowed == 8_976)
        #expect(mailbox.statistics.scheduledDrains == 1)
        #expect(scheduled.count == 2)
        while scheduled.count > 0 { scheduled.runOne() }
        for _ in 0..<2_000 where overflows == 0 {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(received.snapshot.count == 1_024)
        #expect(received.snapshot.map(\.text) == (0..<1_024).map(String.init))
        #expect(overflows == 1)
        #expect(mailbox.statistics.delivered == 1_024)
        #expect(mailbox.statistics.pending == 0)
        #expect(mailbox.statistics.scheduledDrains == 16)
        #expect(!mailbox.submit(line(10_001), generation: 7))
        #expect(mailbox.statistics.pending == 0)
        #expect(mailbox.statistics.overflowed == 8_977)
        #expect(scheduled.count == 0)
    }

    @Test("a new generation revokes every queued old line")
    func generationRevocation() {
        let scheduled = Scheduled()
        let received = LockedBox<[String]>([])
        let mailbox = TranscriptLineMailbox(
            schedule: scheduled.schedule,
            deliver: { _, lines in
                received.update { $0.append(contentsOf: lines.map(\.text)) }
            },
            overflow: { _, _ in })
        mailbox.activate(generation: 1)
        for value in 0..<100 { #expect(mailbox.submit(line(value), generation: 1)) }

        mailbox.activate(generation: 2)
        #expect(!mailbox.submit(line(200), generation: 1))
        #expect(mailbox.submit(line(201), generation: 2))
        #expect(scheduled.count == 2)
        // The old epoch's already-queued closure must not drain generation 2.
        scheduled.runOne()
        #expect(received.snapshot.isEmpty)
        #expect(mailbox.statistics.pending == 1)
        while scheduled.count > 0 { scheduled.runOne() }

        #expect(received.snapshot == ["201"])
        #expect(mailbox.statistics.revoked == 101)
        #expect(mailbox.statistics.delivered == 1)
        #expect(mailbox.statistics.scheduledDrains == 2)
    }
}
