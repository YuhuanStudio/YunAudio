import Dispatch

/// How long a test waits on a gate it means to be signalled.
///
/// These waits are synchronisation, not measurement. A test holds a worker
/// inside its callback, submits ten thousand things behind it, and then
/// releases it — and the timeout on that wait exists only so a genuine deadlock
/// fails instead of hanging the suite for ever.
///
/// It was two seconds, which is a bet that ten thousand submissions finish in
/// under two. With three hundred suites running in parallel they routinely do
/// not, so the gate let itself go early, the worker started before the
/// submissions were in, and a coalescing count that is exact by construction
/// came back short. Every one of those failures described the machine's load
/// and blamed the code — and each one passed alone, which is how a suite
/// teaches people to stop reading it.
///
/// Thirty seconds cannot be reached by a loaded machine and is reached
/// immediately by a deadlock, which is the only thing this number is for.
enum TestGate {
    static let deadlock = DispatchTimeInterval.seconds(30)
    /// The same number where a `TimeInterval` is what the API takes.
    static let deadlockSeconds: Double = 30

    /// Iterations of a millisecond-sleep polling loop that is waiting for
    /// something to finish.
    ///
    /// Three thousand, so the loop gives up only on a deadlock. Two hundred was
    /// a two-second bet on ten thousand callbacks landing, and under a full
    /// parallel run they do not — after which every assertion below the loop
    /// describes a job that had not finished rather than one that finished
    /// wrongly.
    ///
    /// Not for a loop that is asserting something does *not* happen: those want
    /// a short, deliberate window, and raising one would turn a check into a
    /// wait.
    static let polls = 3_000
}
