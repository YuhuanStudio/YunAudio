import Foundation
import YunAudioEngine

/// Bounded, indexed ownership of one attributed transcript.
///
/// Pages are immutable snapshots to consumers. Appending a chronological batch
/// copies at most one partial 128-line page; UUID membership is O(1), and the
/// visible window never materialises the complete meeting. Out-of-order final
/// lines are sorted within the submitted batch and merged page-wise.
struct TranscriptPagedStore {
    static let pageSize = 128
    static let visibleLineLimit = pageSize * 2
    static let maximumLines = 100_000
    static let maximumSerialisedBytes = 16 * 1_024 * 1_024
    static let maximumSpeakerBytes = 4 * 1_024
    static let maximumTextBytes = 64 * 1_024
    static let maximumMailboxLines = 1_024
    static let maximumLinesPerDrain = 64
    static let maximumJournalPages = 8
    static let maximumJournalBytes = 1 * 1_024 * 1_024

    enum JournalMode: Sendable, Equatable {
        /// Retains unacknowledged pages for a durable incremental writer.
        case boundedIncremental
        /// Relies on the existing explicit atomic snapshot save path.
        case snapshotOnly
    }

    enum Refusal: Sendable, Equatable {
        case duplicate
        case invalidTimestamp
        case speakerTooLarge
        case textTooLarge
        case lineLimit
        case byteLimit
        case mailboxOverflow
        case journalBackpressure
    }

    struct Admission: Sendable, Equatable {
        let accepted: Bool
        let refusal: Refusal?
        let serialisedBytes: Int
    }

    struct Statistics: Sendable, Equatable {
        let lines: Int
        let serialisedBytes: Int
        let pages: Int
        let duplicateLines: UInt64
        let refusedLines: UInt64
        let pendingJournalPages: Int
        let pendingJournalBytes: Int
    }

    struct JournalPage: Sendable, Equatable {
        let sequence: UInt64
        let lines: [Transcriber.Line]
        let serialisedBytes: Int
    }

    struct VisibleWindow: Sendable, Equatable {
        let lines: [Transcriber.Line]
        let pagesVisited: Int
    }

    private(set) var pages: [[Transcriber.Line]] = []
    private let journalMode: JournalMode
    private var ids: Set<UUID> = []
    private var bytes = 0
    private var duplicateLines: UInt64 = 0
    private var refusedLines: UInt64 = 0
    private var journal: [JournalPage] = []
    private var journalStaging: [Transcriber.Line] = []
    private var journalStagingBytes = 0
    private var journalBytes = 0
    private var nextJournalSequence: UInt64 = 0

    init(journalMode: JournalMode = .boundedIncremental) {
        self.journalMode = journalMode
    }

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }

    var statistics: Statistics {
        Statistics(
            lines: ids.count,
            serialisedBytes: bytes,
            pages: pages.count,
            duplicateLines: duplicateLines,
            refusedLines: refusedLines,
            pendingJournalPages: journal.count + (journalStaging.isEmpty ? 0 : 1),
            pendingJournalBytes: journalBytes)
    }

    /// Includes the exact UTF-8 representation saved today: timestamp prefix,
    /// speaker, separator, text and one newline. Counting that newline on the
    /// final line is conservative by one byte and keeps admission incremental.
    static func serialisedByteCount(for line: Transcriber.Line) -> Int? {
        guard line.start.isFinite, line.start >= 0, line.duration.isFinite,
            line.duration >= 0
        else { return nil }
        let seconds = UInt64(min(line.start.rounded(.down), Double(7 * 24 * 60 * 60)))
        let prefix = String(format: "[%02llu:%02llu] ", seconds / 60, seconds % 60)
        return prefix.utf8.count + line.speaker.utf8.count + 2 + line.text.utf8.count + 1
    }

    /// Appends one finalised line. Duplicate delivery is success-with-no-change:
    /// stop finalisation may race the event callback, and UUID identity makes the
    /// two paths exact-once without retaining a second history per transcriber.
    @discardableResult
    mutating func append(_ line: Transcriber.Line) -> Admission {
        appendBatch([line]).first!
    }

    /// Validates the whole batch against one projected byte/line frontier, then
    /// merges accepted lines. In bounded incremental mode, no prefix is
    /// committed if the journal cannot own its corresponding page, so storage
    /// pressure is explicit rather than a transcript silently missing its tail.
    mutating func appendBatch(_ lines: [Transcriber.Line]) -> [Admission] {
        guard !lines.isEmpty else { return [] }
        var batchIDs: Set<UUID> = []
        var accepted: [(line: Transcriber.Line, bytes: Int, input: Int)] = []
        var results = [Admission?](repeating: nil, count: lines.count)
        var projectedLines = ids.count
        var projectedBytes = bytes

        for (index, line) in lines.enumerated() {
            guard !ids.contains(line.id), batchIDs.insert(line.id).inserted else {
                duplicateLines &+= 1
                results[index] = Admission(
                    accepted: false, refusal: .duplicate, serialisedBytes: 0)
                continue
            }
            guard line.speaker.utf8.count <= Self.maximumSpeakerBytes else {
                refusedLines &+= 1
                results[index] = Admission(
                    accepted: false, refusal: .speakerTooLarge, serialisedBytes: 0)
                continue
            }
            guard line.text.utf8.count <= Self.maximumTextBytes else {
                refusedLines &+= 1
                results[index] = Admission(
                    accepted: false, refusal: .textTooLarge, serialisedBytes: 0)
                continue
            }
            guard let lineBytes = Self.serialisedByteCount(for: line) else {
                refusedLines &+= 1
                results[index] = Admission(
                    accepted: false, refusal: .invalidTimestamp, serialisedBytes: 0)
                continue
            }
            guard projectedLines < Self.maximumLines else {
                refusedLines &+= 1
                results[index] = Admission(
                    accepted: false, refusal: .lineLimit, serialisedBytes: lineBytes)
                continue
            }
            guard lineBytes <= Self.maximumSerialisedBytes - projectedBytes else {
                refusedLines &+= 1
                results[index] = Admission(
                    accepted: false, refusal: .byteLimit, serialisedBytes: lineBytes)
                continue
            }
            projectedLines += 1
            projectedBytes += lineBytes
            accepted.append((line, lineBytes, index))
        }

        guard !accepted.isEmpty else { return results.map { $0! } }
        accepted.sort { Self.precedes($0.line, $1.line) }
        let appendedBytes = accepted.reduce(0) { $0 + $1.bytes }
        if journalMode == .boundedIncremental {
            guard canEnqueueJournal(lineCount: accepted.count, bytes: appendedBytes) else {
                for item in accepted {
                    refusedLines &+= 1
                    results[item.input] = Admission(
                        accepted: false, refusal: .journalBackpressure,
                        serialisedBytes: item.bytes)
                }
                return results.map { $0! }
            }
        }

        insertSorted(accepted.map(\.line))
        for item in accepted {
            ids.insert(item.line.id)
            bytes += item.bytes
            results[item.input] = Admission(
                accepted: true, refusal: nil, serialisedBytes: item.bytes)
        }
        if journalMode == .boundedIncremental {
            enqueueJournal(accepted.map(\.line), bytes: appendedBytes)
        }
        return results.map { $0! }
    }

    /// The newest two pages are the only rows the transcript card needs to own.
    /// SwiftUI may virtualise those rows further with `LazyVStack`.
    func visibleLines() -> [Transcriber.Line] {
        visibleWindow().lines
    }

    /// Reads backwards from the tail. A 100,000-line meeting therefore visits
    /// three pages, not all 782 pages which precede the visible rows.
    func visibleWindow() -> VisibleWindow {
        let wanted = min(ids.count, Self.visibleLineLimit)
        guard wanted > 0 else { return VisibleWindow(lines: [], pagesVisited: 0) }
        var chunks: [[Transcriber.Line]] = []
        var remaining = wanted
        var pagesVisited = 0
        for page in pages.reversed() where remaining > 0 {
            pagesVisited += 1
            let count = min(remaining, page.count)
            chunks.append(Array(page.suffix(count)))
            remaining -= count
        }
        var lines: [Transcriber.Line] = []
        lines.reserveCapacity(wanted)
        for chunk in chunks.reversed() { lines.append(contentsOf: chunk) }
        return VisibleWindow(lines: lines, pagesVisited: pagesVisited)
    }

    func page(at index: Int) -> [Transcriber.Line]? {
        guard pages.indices.contains(index) else { return nil }
        return pages[index]
    }

    var pendingJournalPages: [JournalPage] { journal }

    /// Seals a partial page after the journal's two-second time boundary. A
    /// writer sees only sealed pages, so acknowledging an old snapshot can
    /// never discard lines appended to the same sequence afterwards.
    mutating func flushJournalStaging() {
        guard !journalStaging.isEmpty else { return }
        sealJournalStaging()
    }

    /// A writer acknowledges complete pages in sequence. Until then the store
    /// owns them, so a blocked volume is bounded at eight pages and one MiB.
    mutating func acknowledgeJournal(through sequence: UInt64) {
        var removedBytes = 0
        journal.removeAll { page in
            guard page.sequence <= sequence else { return false }
            removedBytes += page.serialisedBytes
            return true
        }
        journalBytes = max(0, journalBytes - removedBytes)
    }

    private func canEnqueueJournal(lineCount: Int, bytes: Int) -> Bool {
        let stagedLines = journalStaging.count + lineCount
        let projectedPages = journal.count + (stagedLines + Self.pageSize - 1) / Self.pageSize
        return projectedPages <= Self.maximumJournalPages
            && bytes <= Self.maximumJournalBytes - journalBytes
    }

    private mutating func enqueueJournal(_ lines: [Transcriber.Line], bytes: Int) {
        var offset = 0
        while offset < lines.count {
            let available = Self.pageSize - journalStaging.count
            let end = min(offset + available, lines.count)
            let addition = lines[offset..<end]
            let additionBytes = addition.reduce(0) { partial, line in
                partial + (Self.serialisedByteCount(for: line) ?? 0)
            }
            journalStaging.append(contentsOf: addition)
            journalStagingBytes += additionBytes
            journalBytes += additionBytes
            offset = end
            if journalStaging.count == Self.pageSize { sealJournalStaging() }
        }
        assert(lines.reduce(0) { $0 + (Self.serialisedByteCount(for: $1) ?? 0) } == bytes)
    }

    private mutating func sealJournalStaging() {
        nextJournalSequence &+= 1
        journal.append(
            JournalPage(
                sequence: nextJournalSequence, lines: journalStaging,
                serialisedBytes: journalStagingBytes))
        journalStaging = []
        journalStagingBytes = 0
    }

    /// The common chronological path appends in O(1). An out-of-order line
    /// binary-searches the page and then its at-most-128 elements; splitting
    /// copies only that page. No append scans, flattens or sorts old history.
    private mutating func insertSorted(_ incoming: [Transcriber.Line]) {
        for line in incoming { insertSorted(line) }
    }

    private mutating func insertSorted(_ line: Transcriber.Line) {
        guard !pages.isEmpty else {
            pages = [[line]]
            return
        }
        if let last = pages[pages.count - 1].last, !Self.precedes(line, last) {
            if pages[pages.count - 1].count < Self.pageSize {
                pages[pages.count - 1].append(line)
            } else {
                pages.append([line])
            }
            return
        }

        var lowerPage = 0
        var upperPage = pages.count
        while lowerPage < upperPage {
            let middle = lowerPage + (upperPage - lowerPage) / 2
            if let last = pages[middle].last, Self.precedes(last, line) {
                lowerPage = middle + 1
            } else {
                upperPage = middle
            }
        }
        let pageIndex = min(lowerPage, pages.count - 1)
        var lowerLine = 0
        var upperLine = pages[pageIndex].count
        while lowerLine < upperLine {
            let middle = lowerLine + (upperLine - lowerLine) / 2
            if !Self.precedes(line, pages[pageIndex][middle]) {
                lowerLine = middle + 1
            } else {
                upperLine = middle
            }
        }
        pages[pageIndex].insert(line, at: lowerLine)
        guard pages[pageIndex].count > Self.pageSize else { return }
        let split = pages[pageIndex].count / 2
        let overflow = Array(pages[pageIndex].suffix(from: split))
        pages[pageIndex].removeSubrange(split...)
        pages.insert(overflow, at: pageIndex + 1)
    }

    private static func precedes(_ lhs: Transcriber.Line, _ rhs: Transcriber.Line) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// Owns paged transcript mutation on the mailbox's serial lane.
///
/// MainActor receives only an immutable COW snapshot and the newest 256 rows.
/// In particular, a final 1,024-line Speech tail never sorts pages or rebuilds
/// the visible window while AppKit is trying to stop the route.
final class TranscriptStoreWorker: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        let generation: UInt64
        let visibleLines: [Transcriber.Line]
        let statistics: TranscriptPagedStore.Statistics
        let containsRefusal: Bool
    }

    struct Statistics: Sendable, Equatable {
        let applications: UInt64
        let publications: UInt64
        let stalePublications: UInt64
        let mainThreadApplications: UInt64
        let maximumPendingPublications: Int
        let pageSnapshotRequests: UInt64
        let refusedPageSnapshotRequests: UInt64
        let maximumPendingPageSnapshots: Int
    }

    typealias WorkScheduler = @Sendable (@escaping @Sendable () -> Void) -> Void
    typealias MainScheduler =
        @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

    private struct PublicationState {
        var latest: Snapshot
        var version: UInt64 = 0
        var publicationIsScheduled = false
        var applications: UInt64 = 0
        var publications: UInt64 = 0
        var stalePublications: UInt64 = 0
        var mainThreadApplications: UInt64 = 0
        var maximumPendingPublications = 0
        var pageSnapshotRequests: UInt64 = 0
        var refusedPageSnapshotRequests: UInt64 = 0
        var nextPageRequestToken: UInt64 = 0
        var activePageRequestToken: UInt64?
        var maximumPendingPageSnapshots = 0
    }

    private let lock = NSLock()
    private let scheduleWork: WorkScheduler
    private let scheduleMain: MainScheduler
    private let publish: @MainActor @Sendable (Snapshot) -> Void
    private var store = TranscriptPagedStore(journalMode: .snapshotOnly)
    private var generation: UInt64 = 0
    private var containsRefusal = false
    private var publicationState = PublicationState(
        latest: Snapshot(
            generation: 0, visibleLines: [],
            statistics: TranscriptPagedStore(journalMode: .snapshotOnly).statistics,
            containsRefusal: false))
    private var latestRequestedGeneration: UInt64 = 0

    init(
        scheduleWork: @escaping WorkScheduler,
        scheduleMain: @escaping MainScheduler = MainRunLoopDelivery.perform,
        publish: @escaping @MainActor @Sendable (Snapshot) -> Void
    ) {
        self.scheduleWork = scheduleWork
        self.scheduleMain = scheduleMain
        self.publish = publish
    }

    /// Orders a fresh store before any drain submitted for the new generation.
    func activate(generation: UInt64) {
        lock.withLock {
            latestRequestedGeneration = generation
            publicationState.activePageRequestToken = nil
        }
        scheduleWork { [self] in
            self.generation = generation
            store = TranscriptPagedStore(journalMode: .snapshotOnly)
            containsRefusal = false
            recordSnapshot()
        }
    }

    /// Called only by the mailbox's serial drain lane.
    func receive(_ lines: [Transcriber.Line], generation: UInt64) {
        guard generation == self.generation,
            lock.withLock({ latestRequestedGeneration == generation })
        else { return }
        if Thread.isMainThread {
            lock.withLock { publicationState.mainThreadApplications &+= 1 }
        }
        let admissions = store.appendBatch(lines)
        containsRefusal =
            containsRefusal
            || admissions.contains { !$0.accepted && $0.refusal != .duplicate }
        recordSnapshot()
    }

    var snapshot: Snapshot { lock.withLock { publicationState.latest } }

    /// Copies the outer COW page index only for an explicit save operation.
    /// Stable append publications deliberately never carry the complete history.
    @discardableResult
    func requestPages(
        generation: UInt64,
        completion: @escaping @MainActor @Sendable ([[Transcriber.Line]]?) -> Void
    ) -> Bool {
        let token: UInt64? = lock.withLock {
            guard latestRequestedGeneration == generation,
                publicationState.activePageRequestToken == nil
            else {
                publicationState.refusedPageSnapshotRequests &+= 1
                return nil
            }
            publicationState.nextPageRequestToken &+= 1
            let token = publicationState.nextPageRequestToken
            publicationState.activePageRequestToken = token
            publicationState.pageSnapshotRequests &+= 1
            publicationState.maximumPendingPageSnapshots = max(
                publicationState.maximumPendingPageSnapshots, 1)
            return token
        }
        guard let token else { return false }
        scheduleWork { [self] in
            guard self.generation == generation,
                lock.withLock({
                    latestRequestedGeneration == generation
                        && publicationState.activePageRequestToken == token
                })
            else {
                scheduleMain { [weak self] in
                    self?.completePageRequest(
                        token: token, generation: generation, pages: nil,
                        completion: completion)
                }
                return
            }
            let pages = store.pages
            scheduleMain { [weak self] in
                self?.completePageRequest(
                    token: token, generation: generation, pages: pages,
                    completion: completion)
            }
        }
        return true
    }

    var statistics: Statistics {
        lock.withLock {
            Statistics(
                applications: publicationState.applications,
                publications: publicationState.publications,
                stalePublications: publicationState.stalePublications,
                mainThreadApplications: publicationState.mainThreadApplications,
                maximumPendingPublications: publicationState.maximumPendingPublications,
                pageSnapshotRequests: publicationState.pageSnapshotRequests,
                refusedPageSnapshotRequests: publicationState.refusedPageSnapshotRequests,
                maximumPendingPageSnapshots:
                    publicationState.maximumPendingPageSnapshots)
        }
    }

    @MainActor
    private func completePageRequest(
        token: UInt64, generation: UInt64, pages: [[Transcriber.Line]]?,
        completion: @escaping @MainActor @Sendable ([[Transcriber.Line]]?) -> Void
    ) {
        let isCurrent = lock.withLock {
            guard publicationState.activePageRequestToken == token else { return false }
            publicationState.activePageRequestToken = nil
            return latestRequestedGeneration == generation
        }
        completion(isCurrent ? pages : nil)
    }

    private func recordSnapshot() {
        let visible = store.visibleWindow().lines
        let snapshot = Snapshot(
            generation: generation, visibleLines: visible,
            statistics: store.statistics, containsRefusal: containsRefusal)
        let scheduled: (version: UInt64, generation: UInt64)? = lock.withLock {
            publicationState.applications &+= 1
            publicationState.version &+= 1
            publicationState.latest = snapshot
            guard !publicationState.publicationIsScheduled else {
                publicationState.maximumPendingPublications = max(
                    publicationState.maximumPendingPublications, 1)
                return nil
            }
            publicationState.publicationIsScheduled = true
            publicationState.maximumPendingPublications = max(
                publicationState.maximumPendingPublications, 1)
            return (publicationState.version, snapshot.generation)
        }
        if let scheduled {
            schedulePublication(
                version: scheduled.version, generation: scheduled.generation)
        }
    }

    private func schedulePublication(version: UInt64, generation: UInt64) {
        scheduleMain { [weak self] in
            self?.publishLatest(
                scheduledVersion: version, scheduledGeneration: generation)
        }
    }

    @MainActor
    private func publishLatest(
        scheduledVersion: UInt64, scheduledGeneration: UInt64
    ) {
        let adopted = lock.withLock {
            (publicationState.version, publicationState.latest)
        }
        let isCurrent = lock.withLock {
            scheduledVersion <= adopted.0
                && latestRequestedGeneration == scheduledGeneration
                && adopted.1.generation == scheduledGeneration
        }
        if isCurrent { publish(adopted.1) }
        let reschedule: (version: UInt64, generation: UInt64)? = lock.withLock {
            guard isCurrent else {
                publicationState.stalePublications &+= 1
                publicationState.publicationIsScheduled = false
                guard publicationState.latest.generation == latestRequestedGeneration else {
                    return nil
                }
                publicationState.publicationIsScheduled = true
                return (
                    publicationState.version,
                    publicationState.latest.generation
                )
            }
            publicationState.publications &+= 1
            if publicationState.version == adopted.0 {
                publicationState.publicationIsScheduled = false
                return nil
            }
            return (
                publicationState.version,
                publicationState.latest.generation
            )
        }
        if let reschedule {
            schedulePublication(
                version: reschedule.version, generation: reschedule.generation)
        }
    }
}

/// One scheduled off-main drain regardless of producer count. The mailbox is
/// deliberately lossless until its explicit 1,024-line capacity: overflow must
/// stop/report the session, never turn into a plausible but incomplete record.
final class TranscriptLineMailbox: @unchecked Sendable {
    struct Statistics: Sendable, Equatable {
        let pending: Int
        let maximumPending: Int
        let scheduledDrains: UInt64
        let delivered: UInt64
        let overflowed: UInt64
        let revoked: UInt64
    }

    private struct Entry: Sendable {
        let generation: UInt64
        let line: Transcriber.Line
    }

    private let lock = NSLock()
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let deliver: @Sendable (UInt64, [Transcriber.Line]) -> Void
    private let overflow: @MainActor @Sendable (UInt64, Transcriber.Line) -> Void
    private var entries: [Entry?] = [Entry?](
        repeating: nil, count: TranscriptPagedStore.maximumMailboxLines)
    private var head = 0
    private var tail = 0
    private var count = 0
    private var scheduled = false
    private var epoch: UInt64 = 0
    private var acceptingGeneration: UInt64?
    private var overflowReportGeneration: UInt64?
    private var maximumPending = 0
    private var scheduledDrains: UInt64 = 0
    private var delivered: UInt64 = 0
    private var overflowed: UInt64 = 0
    private var revoked: UInt64 = 0

    init(
        schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
        deliver: @escaping @Sendable (UInt64, [Transcriber.Line]) -> Void,
        overflow: @escaping @MainActor @Sendable (UInt64, Transcriber.Line) -> Void
    ) {
        self.schedule = schedule
        self.deliver = deliver
        self.overflow = overflow
    }

    func activate(generation: UInt64) {
        lock.withLock {
            epoch &+= 1
            acceptingGeneration = generation
            overflowReportGeneration = nil
            revoked &+= UInt64(count)
            clearLocked()
        }
    }

    /// Delivers every accepted final line before an asynchronous Stop barrier.
    ///
    /// Result callbacks normally drain in 64-line turns to keep the run loop
    /// fair. Stop has already ended admission and needs a stronger boundary:
    /// once every transcriber result sequence has ended, its queued tail must be
    /// in the store before a new session can revoke this generation.
    func flush(
        generation: UInt64,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        let expectedEpoch = lock.withLock { epoch }
        schedule { [weak self] in
            guard let self else {
                MainRunLoopDelivery.perform(completion)
                return
            }
            while lock.withLock({
                acceptingGeneration == generation && expectedEpoch == epoch && count > 0
            }) {
                drain(epoch: expectedEpoch, schedulesContinuation: false)
            }
            MainRunLoopDelivery.perform(completion)
        }
    }

    @discardableResult
    func submit(_ line: Transcriber.Line, generation: UInt64) -> Bool {
        var schedules = false
        var schedulesOverflow = false
        var accepted = false
        var scheduledEpoch: UInt64 = 0
        lock.lock()
        if generation != acceptingGeneration {
            revoked &+= 1
        } else if overflowReportGeneration == generation {
            // Once one line was lost, accepting a later line would make the
            // record look complete again. Stay fail-closed until activation of
            // a new session and retain one explicit report for this generation.
            overflowed &+= 1
        } else if count == entries.count {
            overflowed &+= 1
            if overflowReportGeneration != generation {
                overflowReportGeneration = generation
                schedulesOverflow = true
                scheduledEpoch = epoch
            }
        } else {
            accepted = true
            entries[tail] = Entry(generation: generation, line: line)
            tail = (tail + 1) % entries.count
            count += 1
            maximumPending = max(maximumPending, count)
            if !scheduled {
                scheduled = true
                scheduledDrains &+= 1
                schedules = true
                scheduledEpoch = epoch
            }
        }
        lock.unlock()

        let epochForSchedule = scheduledEpoch
        if schedules {
            schedule { [weak self] in self?.drain(epoch: epochForSchedule) }
        }
        if schedulesOverflow {
            schedule { [weak self] in
                self?.reportOverflow(generation, line, epoch: epochForSchedule)
            }
        }
        return accepted
    }

    var statistics: Statistics {
        lock.withLock {
            Statistics(
                pending: count, maximumPending: maximumPending,
                scheduledDrains: scheduledDrains, delivered: delivered,
                overflowed: overflowed, revoked: revoked)
        }
    }

    private func drain(epoch expectedEpoch: UInt64, schedulesContinuation: Bool = true) {
        var batch: [Entry] = []
        var schedules = false
        lock.lock()
        guard expectedEpoch == epoch else {
            lock.unlock()
            return
        }
        batch.reserveCapacity(min(count, TranscriptPagedStore.maximumLinesPerDrain))
        while batch.count < TranscriptPagedStore.maximumLinesPerDrain, count > 0 {
            if let entry = entries[head] { batch.append(entry) }
            entries[head] = nil
            head = (head + 1) % entries.count
            count -= 1
        }
        scheduled = false
        let current = acceptingGeneration
        let accepted = batch.filter { $0.generation == current }
        revoked &+= UInt64(batch.count - accepted.count)
        delivered &+= UInt64(accepted.count)
        if schedulesContinuation, count > 0 {
            scheduled = true
            scheduledDrains &+= 1
            schedules = true
        }
        lock.unlock()

        if let current, !accepted.isEmpty { deliver(current, accepted.map(\.line)) }
        if schedules {
            schedule { [weak self] in self?.drain(epoch: expectedEpoch) }
        }
    }

    private func reportOverflow(
        _ generation: UInt64, _ line: Transcriber.Line, epoch expectedEpoch: UInt64
    ) {
        guard
            lock.withLock({
                generation == acceptingGeneration && expectedEpoch == epoch
            })
        else { return }
        MainRunLoopDelivery.perform { [weak self] in
            self?.overflow(generation, line)
        }
    }

    private func clearLocked() {
        for index in entries.indices { entries[index] = nil }
        head = 0
        tail = 0
        count = 0
        scheduled = false
    }
}
