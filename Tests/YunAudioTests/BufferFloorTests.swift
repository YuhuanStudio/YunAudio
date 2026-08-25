import Foundation
import Testing

@testable import YunAudioApp
@testable import YunAudioEngine

/// What the application does when the audio starts breaking up.
///
/// A missed deadline is cured by a longer IO cycle, and applying one means
/// rebuilding the route — a gap. So the rule here is: notice the difference
/// between a click and a route that cannot hold its cycle, say so, offer the
/// fix, and let the person decide.
@MainActor
@Suite("A buffer a destination has earned")
struct BufferFloorTests {

    private func dropout(_ model: RouterModel, at seconds: Double) {
        model.recordDropout(.init(device: 7, at: seconds))
    }

    /// One click on a healthy machine is not a fault to act on: the cold start
    /// of a wired route produced exactly one in its first 1541 cycles, and none
    /// in the three runs after it.
    @Test("one miss is a click, not an offer")
    func oneMissOffersNothing() {
        let model = RouterModel()
        dropout(model, at: 1)
        #expect(model.suggestedBufferFrames == nil)
    }

    /// Three inside ten seconds is a route that cannot hold its cycle.
    ///
    /// The offer still needs a route to rebuild, so with nothing running there
    /// is nothing to offer — which is also what stops a tally from a previous
    /// session producing a button out of nowhere at launch.
    @Test("nothing is offered when nothing is running")
    func nothingIsOfferedWhenStopped() {
        let model = RouterModel()
        for second in [1.0, 2.0, 3.0] { dropout(model, at: second) }
        #expect(!model.isRunning)
        #expect(model.suggestedBufferFrames == nil)
    }

    /// Spread out, the same three misses are three separate clicks.
    @Test("misses far apart never cluster")
    func spreadOutMissesDoNotCluster() {
        var kept: [Double] = []
        for second in [0.0, 30.0, 60.0, 90.0] {
            kept.append(second)
            kept = RouterModel.dropoutsInsideTheWindow(kept, at: second)
            #expect(!RouterModel.isBreakingUp(kept), "clustered at \(second)s")
        }
        #expect(kept == [90.0])
    }

    /// Three inside the window is the case this exists for.
    @Test("three inside ten seconds is a route failing")
    func threeCloseTogetherCluster() {
        var kept: [Double] = []
        for second in [1.0, 4.5, 9.0] {
            kept.append(second)
            kept = RouterModel.dropoutsInsideTheWindow(kept, at: second)
        }
        #expect(kept.count == 3)
        #expect(RouterModel.isBreakingUp(kept))
    }

    /// The window slides: two old misses and one new one is not a cluster,
    /// which is what stops a long session accumulating its way into an offer.
    @Test("the window slides rather than accumulating")
    func windowSlides() {
        var kept: [Double] = [1.0, 2.0]
        kept.append(40.0)
        kept = RouterModel.dropoutsInsideTheWindow(kept, at: 40.0)
        #expect(kept == [40.0])
        #expect(!RouterModel.isBreakingUp(kept))
    }

    /// A floor raises the buffer and never lowers it: somebody who chose 512 by
    /// hand keeps 512 whatever a headset once proved about 256.
    @Test("a floor raises the buffer and cannot lower it")
    func floorOnlyRaises() {
        let model = RouterModel()
        model.bufferFrames = 512
        #expect(model.effectiveBufferFrames == 512)
        model.bufferFrames = 64
        #expect(model.effectiveBufferFrames == 64)
    }

    /// The offer is the next size up, and stops at the top of the range.
    ///
    /// Past 512 frames the latency costs more than the safety buys, and an
    /// offer that cannot fix anything is worse than saying nothing.
    @Test("the ladder has a top")
    func ladderHasATop() {
        #expect(RouterModel.bufferSizes.first { $0 > 128 } == 256)
        #expect(RouterModel.bufferSizes.first { $0 > 256 } == 512)
        #expect(RouterModel.bufferSizes.first { $0 > 512 } == nil)
    }

    /// The count survives a restart on purpose — an old fault stays visible —
    /// which is exactly why it is the wrong thing to decide "breaking up right
    /// now" from. The window is.
    @Test("the tally and the cluster are different questions")
    func tallyAndClusterAreDifferent() {
        let model = RouterModel()
        for second in stride(from: 0.0, through: 100.0, by: 20.0) {
            dropout(model, at: second)
        }
        // The count mirrors the engine's, which is the whole point of it: two
        // numbers for one fact can disagree, and this one cannot. With no route
        // there have been no overloads, whatever this test just posted.
        #expect(model.dropoutCount == 0)
        #expect(model.dropoutWarning == nil)
    }

    /// A floor belongs to the destination that earned it.
    @Test("a floor is remembered per destination and can be forgotten")
    func floorIsPerDestination() {
        let model = RouterModel()
        #expect(model.bufferFloors.isEmpty)
        model.clearBufferFloor(forDestination: "nobody")
        #expect(model.bufferFloors.isEmpty)
    }
}
