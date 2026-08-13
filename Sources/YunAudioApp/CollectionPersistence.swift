import Foundation

/// The finite shape shared by the two user-authored JSON collections.
struct CollectionPersistenceLimits: Equatable, Sendable {
    let maximumRecords: Int
    let maximumEncodedBytes: Int

    static let userCollection = CollectionPersistenceLimits(
        maximumRecords: 256,
        maximumEncodedBytes: 1_048_576)
}

/// Why one collection value was not admitted or persisted.
enum CollectionPersistenceRefusal: Equatable, Sendable {
    case invalidEstimate
    case recordLimit(requested: Int, maximum: Int)
    case estimatedEncodedSize(requested: Int, maximum: Int)
    case persistedEncodedSize(requested: Int, maximum: Int)
    case encodedSize(requested: Int, maximum: Int)
    case encodingFailed
    case decodingFailed
    case sinkFailed
    case synchronisationFailed
}

enum CollectionPersistenceSubmission: Equatable, Sendable {
    case accepted
    case refused(CollectionPersistenceRefusal)
}

enum CollectionPersistenceLoadResult<Value> {
    case absent
    case loaded(Value)
    case refused(CollectionPersistenceRefusal)
}

enum JSONArrayCapacityInspection: Equatable, Sendable {
    case withinLimit(Int)
    case exceedsLimit(Int)
    case malformed
}

/// Counts only top-level array elements without allocating decoded records.
struct JSONArrayCapacityInspector {
    static func inspect(_ data: Data, maximumRecords: Int) -> JSONArrayCapacityInspection {
        guard maximumRecords >= 0 else { return .malformed }
        let bytes = Array(data)
        var index = 0
        skipWhitespace(in: bytes, index: &index)
        guard index < bytes.count, bytes[index] == 0x5B else { return .malformed }
        index += 1
        skipWhitespace(in: bytes, index: &index)
        if index < bytes.count, bytes[index] == 0x5D {
            index += 1
            skipWhitespace(in: bytes, index: &index)
            return index == bytes.count ? .withinLimit(0) : .malformed
        }

        var stack: [UInt8] = [0x5B]
        var inString = false
        var isEscaped = false
        var count = 1

        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5C {
                    isEscaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }

            switch byte {
            case 0x22:
                inString = true
            case 0x5B, 0x7B:
                stack.append(byte)
            case 0x5D:
                guard stack.last == 0x5B else { return .malformed }
                stack.removeLast()
                if stack.isEmpty {
                    skipWhitespace(in: bytes, index: &index)
                    guard index == bytes.count else { return .malformed }
                    return count <= maximumRecords
                        ? .withinLimit(count) : .exceedsLimit(count)
                }
            case 0x7D:
                guard stack.last == 0x7B else { return .malformed }
                stack.removeLast()
            case 0x2C where stack.count == 1:
                count += 1
            default:
                break
            }
        }
        return .malformed
    }

    private static func skipWhitespace(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count,
            bytes[index] == 0x20 || bytes[index] == 0x09
                || bytes[index] == 0x0A || bytes[index] == 0x0D
        {
            index += 1
        }
    }
}

/// Pure admission for a value whose JSON upper bound was calculated by its model.
struct CollectionPersistenceAdmission {
    let limits: CollectionPersistenceLimits

    func refusal(
        recordCount: Int, estimatedEncodedBytes: Int?
    )
        -> CollectionPersistenceRefusal?
    {
        guard recordCount >= 0, let estimatedEncodedBytes, estimatedEncodedBytes >= 0 else {
            return .invalidEstimate
        }
        guard recordCount <= limits.maximumRecords else {
            return .recordLimit(requested: recordCount, maximum: limits.maximumRecords)
        }
        guard estimatedEncodedBytes <= limits.maximumEncodedBytes else {
            return .estimatedEncodedSize(
                requested: estimatedEncodedBytes,
                maximum: limits.maximumEncodedBytes)
        }
        return nil
    }
}

/// A saturating upper bound for JSON emitted by `JSONEncoder`.
///
/// A string byte can become a six-byte escape. Four-byte scalars which become
/// a surrogate pair still fit inside that bound, so this can reject before a
/// value reaches the UI without doing the real encoding there. Work also stops
/// as soon as the collection has crossed its hard byte cap.
struct JSONEncodedSizeBudget {
    private let limit: Int
    private(set) var bytes = 0
    private(set) var isValid = true

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    var hasExceededLimit: Bool { bytes > limit }
    var upperBound: Int? { isValid ? bytes : nil }

    mutating func addSyntax(_ count: Int = 1) {
        guard isValid, !hasExceededLimit, count >= 0 else {
            if count < 0 { isValid = false }
            return
        }
        let remaining = limit - bytes
        bytes = count > remaining ? limit + 1 : bytes + count
    }

    mutating func addString(_ value: String) {
        addSyntax(2)
        guard !hasExceededLimit else { return }
        let (escapedBytes, overflowed) = value.utf8.count.multipliedReportingOverflow(by: 6)
        guard !overflowed else {
            isValid = false
            return
        }
        addSyntax(escapedBytes)
    }

    mutating func addFiniteNumber<T: BinaryFloatingPoint>(_ value: T) {
        guard value.isFinite else {
            isValid = false
            return
        }
        // Decimal plus exponent output for every binary floating-point value
        // is shorter than this; the slack keeps the bound independent of the
        // encoder's spelling choices.
        addSyntax(32)
    }

    mutating func addInteger() { addSyntax(32) }
    mutating func addBoolean() { addSyntax(5) }

    mutating func addField(_ key: String, string value: String?) {
        guard let value, !hasExceededLimit else { return }
        addString(key)
        addSyntax()
        addString(value)
        addSyntax()
    }

    mutating func addField<T: BinaryFloatingPoint>(_ key: String, number value: T?) {
        guard let value, !hasExceededLimit else { return }
        addString(key)
        addSyntax()
        addFiniteNumber(value)
        addSyntax()
    }

    mutating func addIntegerField(_ key: String) {
        guard !hasExceededLimit else { return }
        addString(key)
        addSyntax()
        addInteger()
        addSyntax()
    }

    mutating func addBooleanField(_ key: String) {
        guard !hasExceededLimit else { return }
        addString(key)
        addSyntax()
        addBoolean()
        addSyntax()
    }

    mutating func addField(_ key: String, boolean value: Bool?) {
        guard value != nil, !hasExceededLimit else { return }
        addBooleanField(key)
    }

    mutating func addStringArrayField(_ key: String, values: [String]?) {
        guard let values, !hasExceededLimit else { return }
        addString(key)
        addSyntax(2)
        for value in values {
            addString(value)
            addSyntax()
            if hasExceededLimit { return }
        }
        addSyntax(2)
    }

    mutating func addFloatDictionaryField(_ key: String, values: [String: Float]?) {
        guard let values, !hasExceededLimit else { return }
        addString(key)
        addSyntax(2)
        for (key, value) in values {
            addString(key)
            addSyntax()
            addFiniteNumber(value)
            addSyntax()
            if hasExceededLimit || !isValid { return }
        }
        addSyntax(2)
    }
}

/// Telemetry for a sole serial JSON writer.
struct CollectionPersistenceStatistics: Equatable, Sendable {
    var admittedSubmissions: UInt64 = 0
    var refusedSubmissions: UInt64 = 0
    var successfulWrites: UInt64 = 0
    var failedWrites: UInt64 = 0
    var refusedLoads: UInt64 = 0
    var successfulLoads: UInt64 = 0
    var lastRefusal: CollectionPersistenceRefusal?
    var workerStarts: Int = 0
    var maximumConcurrentWrites: Int = 0
    var maximumRetainedSnapshots: Int = 0
}

/// One background encoder and sink with a first/active/latest memory bound.
final class BoundedCollectionPersistence<Value: Sendable>: @unchecked Sendable {
    private final class Telemetry: @unchecked Sendable {
        private let lock = NSLock()
        private var statistics = CollectionPersistenceStatistics()

        func admit() {
            lock.withLock { statistics.admittedSubmissions &+= 1 }
        }

        func refuseSubmission(_ refusal: CollectionPersistenceRefusal) {
            lock.withLock {
                statistics.refusedSubmissions &+= 1
                statistics.lastRefusal = refusal
            }
        }

        func completeWrite() {
            lock.withLock { statistics.successfulWrites &+= 1 }
        }

        func refuseWrite(_ refusal: CollectionPersistenceRefusal) {
            lock.withLock {
                statistics.failedWrites &+= 1
                statistics.lastRefusal = refusal
            }
        }

        func completeLoad() {
            lock.withLock { statistics.successfulLoads &+= 1 }
        }

        func refuseLoad(_ refusal: CollectionPersistenceRefusal) {
            lock.withLock {
                statistics.refusedLoads &+= 1
                statistics.lastRefusal = refusal
            }
        }

        func snapshot(
            writer: CoalescedPreferenceWriter<Value>.Metrics
        ) -> CollectionPersistenceStatistics {
            lock.withLock {
                var copy = statistics
                copy.workerStarts = writer.workerStarts
                copy.maximumConcurrentWrites = writer.maximumConcurrentWrites
                copy.maximumRetainedSnapshots = writer.maximumRetainedSnapshots
                return copy
            }
        }
    }

    let limits: CollectionPersistenceLimits
    private let admission: CollectionPersistenceAdmission
    private let telemetry: Telemetry
    private let writer: CoalescedPreferenceWriter<Value>

    init(
        limits: CollectionPersistenceLimits = .userCollection,
        queue: DispatchQueue = DispatchQueue(
            label: "com.yuhuanstudio.yunaudio.collection-persistence",
            qos: .utility),
        encode: @escaping @Sendable (Value) -> Data?,
        sink: @escaping @Sendable (Data) -> Bool,
        synchronise: @escaping @Sendable () -> Bool
    ) {
        self.limits = limits
        admission = CollectionPersistenceAdmission(limits: limits)
        let telemetry = Telemetry()
        self.telemetry = telemetry
        writer = CoalescedPreferenceWriter<Value>(
            delay: .zero,
            queue: queue,
            durableWrite: { value in
                guard let data = encode(value) else {
                    telemetry.refuseWrite(.encodingFailed)
                    return false
                }
                guard data.count <= limits.maximumEncodedBytes else {
                    telemetry.refuseWrite(
                        .encodedSize(
                            requested: data.count,
                            maximum: limits.maximumEncodedBytes))
                    return false
                }
                guard sink(data) else {
                    telemetry.refuseWrite(.sinkFailed)
                    return false
                }
                guard synchronise() else {
                    telemetry.refuseWrite(.synchronisationFailed)
                    return false
                }
                telemetry.completeWrite()
                return true
            },
            synchronise: { true })
    }

    func refusal(
        recordCount: Int, estimatedEncodedBytes: Int?
    )
        -> CollectionPersistenceRefusal?
    {
        admission.refusal(
            recordCount: recordCount,
            estimatedEncodedBytes: estimatedEncodedBytes)
    }

    func preflightRefusal(
        recordCount: Int, estimatedEncodedBytes: Int?
    ) -> CollectionPersistenceRefusal? {
        guard
            let refusal = refusal(
                recordCount: recordCount,
                estimatedEncodedBytes: estimatedEncodedBytes)
        else { return nil }
        telemetry.refuseSubmission(refusal)
        return refusal
    }

    @discardableResult
    func submit(
        _ value: Value,
        recordCount: Int,
        estimatedEncodedBytes: Int?
    ) -> CollectionPersistenceSubmission {
        if let refusal = refusal(
            recordCount: recordCount,
            estimatedEncodedBytes: estimatedEncodedBytes)
        {
            telemetry.refuseSubmission(refusal)
            return .refused(refusal)
        }
        telemetry.admit()
        writer.submit(value)
        return .accepted
    }

    func load(
        _ data: Data?,
        decode: (Data) -> Value?,
        recordCount: (Value) -> Int
    ) -> CollectionPersistenceLoadResult<Value> {
        guard let data else { return .absent }
        guard data.count <= limits.maximumEncodedBytes else {
            let refusal = CollectionPersistenceRefusal.persistedEncodedSize(
                requested: data.count,
                maximum: limits.maximumEncodedBytes)
            telemetry.refuseLoad(refusal)
            return .refused(refusal)
        }
        if case .exceedsLimit(let count) = JSONArrayCapacityInspector.inspect(
            data, maximumRecords: limits.maximumRecords)
        {
            let refusal = CollectionPersistenceRefusal.recordLimit(
                requested: count,
                maximum: limits.maximumRecords)
            telemetry.refuseLoad(refusal)
            return .refused(refusal)
        }
        guard let value = decode(data) else {
            telemetry.refuseLoad(.decodingFailed)
            return .refused(.decodingFailed)
        }
        let count = recordCount(value)
        guard count <= limits.maximumRecords else {
            let refusal = CollectionPersistenceRefusal.recordLimit(
                requested: count,
                maximum: limits.maximumRecords)
            telemetry.refuseLoad(refusal)
            return .refused(refusal)
        }
        telemetry.completeLoad()
        return .loaded(value)
    }

    var latestValue: Value? { writer.latestValue }

    var statistics: CollectionPersistenceStatistics {
        telemetry.snapshot(writer: writer.metrics)
    }

    @MainActor
    func flush(
        timeout: Duration = .seconds(1),
        completion: @escaping @MainActor @Sendable (PreferenceFlushResult) -> Void
    ) {
        writer.flush(timeout: timeout, completion: completion)
    }
}
