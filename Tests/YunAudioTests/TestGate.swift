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
}
