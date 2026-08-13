import Foundation

/// Session-wide admission for the per-source speech stack.
///
/// The realtime graph can route sixty-four sources, but that does not make
/// sixty-four speech models an acceptable background workload. Four admitted
/// sources bound every resource which otherwise multiplied independently: tap
/// rings, converter backlog, analyser input, conversion lanes and result tasks.
public enum TranscriptionAdmission {
    public static let maximumSources = 4
    public static let maximumUIDBytes = 1_024
    public static let maximumNameBytes = 4 * 1_024
    public static let ringFramesPerSource = 65_536
    public static let backlogFramesPerSource = 192_000
    public static let maximumAnalyzerInputsPerSource = 32
    public static let maximumConcurrentStarts = 2

    public static let ringBytesPerSource =
        ringFramesPerSource * MemoryLayout<Float>.stride
    public static let backlogBytesPerSource =
        backlogFramesPerSource * MemoryLayout<Float>.stride
    public static let maximumRingBytes = maximumSources * ringBytesPerSource
    public static let maximumBacklogBytes = maximumSources * backlogBytesPerSource
    public static let maximumAnalyzerInputs =
        maximumSources * maximumAnalyzerInputsPerSource

    /// A logical source rather than a route. A stereo source still needs one
    /// mono speech feed and therefore consumes one admission slot.
    public struct Source: Sendable, Equatable {
        public let uid: String
        public let name: String

        public init(uid: String, name: String) {
            self.uid = uid
            self.name = name
        }
    }

    public enum RefusalReason: Sendable, Equatable {
        case emptyUID
        case uidTooLarge(maximumBytes: Int)
        case emptyName
        case nameTooLarge(maximumBytes: Int)
        case duplicateUID
        case sourceLimit(maximum: Int)
    }

    /// Carries identity even on refusal so the interface can say exactly which
    /// source was not transcribed, rather than reporting one anonymous count.
    public struct Refusal: Sendable, Equatable {
        public let source: Source
        public let reason: RefusalReason
    }

    public struct Resources: Sendable, Equatable {
        public let sourceCount: Int
        public let ringBytes: Int
        public let backlogBytes: Int
        public let analyzerInputs: Int
        public let converterLanes: Int
        public let resultTasks: Int
        public let modelInstances: Int
        public let concurrentStarts: Int
    }

    public struct Plan: Sendable, Equatable {
        public let admitted: [Source]
        public let refused: [Refusal]
        public let resources: Resources
    }

    /// Preserves request order and admits the first occurrence of each UID.
    /// Stable order matters because tap slots and speaker labels use this plan
    /// independently and must never disagree about which source an index means.
    public static func plan(_ requested: [Source]) -> Plan {
        var seen: Set<String> = []
        var admitted: [Source] = []
        var refused: [Refusal] = []
        admitted.reserveCapacity(min(requested.count, maximumSources))
        refused.reserveCapacity(max(0, requested.count - maximumSources))

        for source in requested {
            guard !source.uid.isEmpty else {
                refused.append(Refusal(source: source, reason: .emptyUID))
                continue
            }
            guard source.uid.utf8.count <= maximumUIDBytes else {
                refused.append(
                    Refusal(
                        source: source,
                        reason: .uidTooLarge(maximumBytes: maximumUIDBytes)))
                continue
            }
            guard !source.name.isEmpty else {
                refused.append(Refusal(source: source, reason: .emptyName))
                continue
            }
            guard source.name.utf8.count <= maximumNameBytes else {
                refused.append(
                    Refusal(
                        source: source,
                        reason: .nameTooLarge(maximumBytes: maximumNameBytes)))
                continue
            }
            guard seen.insert(source.uid).inserted else {
                refused.append(Refusal(source: source, reason: .duplicateUID))
                continue
            }
            guard admitted.count < maximumSources else {
                refused.append(
                    Refusal(
                        source: source,
                        reason: .sourceLimit(maximum: maximumSources)))
                continue
            }
            admitted.append(source)
        }

        let count = admitted.count
        return Plan(
            admitted: admitted,
            refused: refused,
            resources: Resources(
                sourceCount: count,
                ringBytes: count * ringBytesPerSource,
                backlogBytes: count * backlogBytesPerSource,
                analyzerInputs: count * maximumAnalyzerInputsPerSource,
                converterLanes: count,
                resultTasks: count,
                modelInstances: count,
                concurrentStarts: min(count, maximumConcurrentStarts)))
    }
}
