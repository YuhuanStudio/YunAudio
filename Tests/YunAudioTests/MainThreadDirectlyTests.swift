import Foundation
import Testing

@testable import YunDesign

/// The hop that replaced `MainActor.assumeIsolated` at every site that faulted.
///
/// What is worth asserting is narrow but load-bearing: the body must actually
/// run, its result must come back, throwing must propagate rather than be
/// swallowed, and — the whole point — main-actor state must be reachable inside
/// it. A reinterpretation that quietly did nothing would look exactly like a
/// fixed crash.
@Suite("running on the main thread without asking the runtime")
struct MainThreadDirectlyTests {

    @MainActor
    private final class Counter {
        var value = 0
    }

    @Test("the body runs, once")
    @MainActor
    func theBodyRuns() {
        var runs = 0
        onTheMainThread { runs += 1 }
        #expect(runs == 1)
    }

    @Test("a result comes back")
    @MainActor
    func resultsComeBack() {
        #expect(onTheMainThread { 6 * 7 } == 42)
        #expect(onTheMainThread { "慢冷" } == "慢冷")
    }

    @Test("main-actor state is reachable inside")
    @MainActor
    func mainActorStateIsReachable() {
        let counter = Counter()
        // The reason the call exists. If isolation were lost rather than
        // assumed, this would not compile; if the body did not run, the count
        // would stay at nought.
        for _ in 0..<3 { onTheMainThread { counter.value += 1 } }
        #expect(counter.value == 3)
    }

    @Test("throwing propagates rather than being swallowed")
    @MainActor
    func throwingPropagates() {
        struct Nope: Error {}
        var caught = false
        do {
            try onTheMainThread { throw Nope() }
        } catch {
            caught = true
        }
        #expect(caught)
    }

    @Test("it is reentrant, because a poll can open a panel that polls")
    @MainActor
    func nesting() {
        var order: [Int] = []
        onTheMainThread {
            order.append(1)
            onTheMainThread { order.append(2) }
            order.append(3)
        }
        #expect(order == [1, 2, 3])
    }

    @Test("calling it many times allocates nothing that accumulates")
    @MainActor
    func repeatedUse() {
        // Twenty times a second for an evening is the real load; a hundred
        // thousand here is that in a fraction of a second and would show a leak
        // of anything held per call as a hang or a crash rather than a number.
        let counter = Counter()
        for _ in 0..<100_000 { onTheMainThread { counter.value += 1 } }
        #expect(counter.value == 100_000)
    }
}
