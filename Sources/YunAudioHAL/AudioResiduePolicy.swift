import Foundation

/// Numeric state for audio owners retained after Core Audio did not prove them absent.
///
/// This snapshot contains no owner references or HAL object identifiers. It is safe to
/// expose to diagnostics without extending the lifetime it is describing.
public struct AudioResidueTelemetry: Sendable, Equatable {
    /// Owners currently retained because absence has not been proved.
    public let retainedEntries: Int
    /// Largest retained set observed during this process lifetime.
    public let maximumRetainedEntries: Int
    /// Cleanup calls made across every retained and completed entry.
    public let cleanupAttempts: UInt64
    /// Entries waiting for another scheduled cleanup attempt.
    public let scheduledRetries: Int
    /// Entries retained after consuming their complete retry budget.
    public let exhaustedEntries: Int
    /// Entries whose cleanup eventually proved absence and released their owner.
    public let completedEntries: UInt64
    /// New ownership requests refused while residue existed.
    public let deniedAdmissions: UInt64
    /// Largest delay the retry policy can schedule between attempts.
    public let maximumRetryDelay: TimeInterval
    /// Fixed number of cleanup calls available to one entry, including its first call.
    public let maximumAttemptsPerEntry: Int

    /// No new Core Audio ownership may begin while any uncertain owner remains.
    public var admitsNewAudioOwnership: Bool { retainedEntries == 0 }
}

/// One finite retry schedule shared by every deinitialiser fallback.
///
/// An individual cleanup call has its own two-second HAL deadline. Four calls, separated
/// by these three delays, give asynchronous removal time to settle without creating a
/// process-lifetime polling loop.
struct AudioResidueRetryPolicy: Sendable, Equatable {
    static let standard = AudioResidueRetryPolicy(delays: [0.25, 1, 4])

    let delays: [TimeInterval]

    var maximumAttempts: Int { delays.count + 1 }
    var maximumDelay: TimeInterval { delays.max() ?? 0 }

    /// Delay before the next call after `completedAttempts`, or nil when exhausted.
    func delayAfterFailure(completedAttempts: Int) -> TimeInterval? {
        guard completedAttempts > 0, completedAttempts <= delays.count else { return nil }
        return delays[completedAttempts - 1]
    }
}
