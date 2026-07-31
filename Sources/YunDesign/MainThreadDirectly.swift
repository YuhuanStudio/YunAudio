import Foundation

/// Runs main-actor work from a callback the system has already put on the main
/// thread, without asking the concurrency runtime whether it did.
///
/// `MainActor.assumeIsolated` is the sanctioned way to write this and is what
/// this application used until it was measured. What that call does is a
/// *dynamic* check: it reads the current task and its executor out of
/// thread-local state and compares them against the main actor. In this process
/// that check faults — `EXC_BAD_ACCESS` reading `0x1e`, inside
/// `swift_task_isCurrentExecutorImpl`, between three and three and a half
/// minutes after launch, in seven separate crash reports. A minimal
/// reproduction — plain AppKit, the same check twenty times a second, the same
/// toolchain — ran 300 seconds and 6000 checks without a fault, so the check is
/// not wrong in general; something in this process makes the state it reads
/// unreadable, and the check is where the process finds out.
///
/// The alternative that avoids the check is a resident `@MainActor` task loop,
/// which is statically isolated and needs no check at all. It was tried, and it
/// costs more than it saves: a nested run loop — which is what
/// `WindowCapture`'s settle and every modal panel on this stage run — services
/// a `Timer` and does not service a continuation, so the polling stops for the
/// duration and twenty-seven flow assertions go quietly wrong. Something still
/// moving with nobody watching is the failure this project least tolerates.
///
/// So: keep the timer, drop the check. The check answers a question — "is this
/// the main thread's executor" — that a main-run-loop timer callback answers by
/// construction, and the cheap half of that question is asked here anyway.
/// `Thread.isMainThread` reads the thread's own identity rather than the
/// concurrency runtime's bookkeeping, so it cannot fault the way the check
/// does, and it turns "the timer somehow fired somewhere else" from an
/// undebuggable bad access into a sentence.
///
/// - Precondition: The caller really is on the main thread. Every use is a
///   `Timer` on the main run loop, an AppKit action, or an application delegate
///   callback, all of which the operating system guarantees.
public func onTheMainThread<T>(
    _ body: @MainActor () throws -> T,
    file: StaticString = #fileID,
    line: UInt = #line
) rethrows -> T {
    precondition(
        Thread.isMainThread,
        "onTheMainThread called off the main thread", file: file, line: line)
    // Isolation is not part of a closure's representation — a `@MainActor`
    // closure and a plain one are both a function pointer and a context
    // reference, of the same size and the same calling convention — so this
    // reinterpretation changes nothing about what runs, only what the compiler
    // insists be proven first. The precondition above is the proof.
    return try withoutActuallyEscaping(body) { escaping in
        try unsafeBitCast(escaping, to: (() throws -> T).self)()
    }
}
