import Testing

@testable import YunAudioApp

/// What "and N more" means in the application list.
///
/// The two halves of that list overlap: the top takes anything playing or
/// recording, the lower one takes anything in the background that is not
/// playing — so a background application that is *recording* belongs to both.
/// The count used to be "how many the truncation cut", which counted that
/// application even while it sat on the screen in the other half. The panel
/// offered one more than it had and pressing it revealed nothing.
///
/// The flow check found it once its accounting was taken from one snapshot
/// instead of two: `23 row(s) + 1 overflow against 23 application(s)`.
@Suite("what the application list says is missing")
struct AppListingOverflowTests {

    private typealias Listing = RouterModel.AppListing

    @Test("nothing hidden, nothing offered")
    func nothingHidden() {
        #expect(Listing.overflow(offered: ["a", "b"], showing: ["a", "b"]) == 0)
    }

    @Test("what the truncation really cut is offered")
    func genuinelyCut() {
        #expect(Listing.overflow(offered: ["a", "b", "c"], showing: ["a"]) == 2)
    }

    @Test("an application cut from one half but shown in the other is not missing")
    func shownInTheOtherHalf() {
        // The case that was wrong: "c" is a background application that is
        // recording, so it is offered *and* listed below. Truncated out of the
        // top half it is still on the screen.
        #expect(Listing.overflow(offered: ["a", "b", "c"], showing: ["a", "b", "c"]) == 0)
        #expect(Listing.overflow(offered: ["a", "b", "c"], showing: ["a", "c"]) == 1)
    }

    @Test("and the rows plus the overflow account for everything offered")
    func accountingBalances() {
        // The invariant the flow check asserts, at the level of the rule.
        let offered = ["a", "b", "c", "d", "e"]
        for shownCount in 0...offered.count {
            let showing = Array(offered.prefix(shownCount))
            let missing = Listing.overflow(offered: offered, showing: showing)
            #expect(showing.count + missing == offered.count)
        }
    }

    @Test("a row that is showing but was never offered does not go negative")
    func extraRows() {
        // The background half can list applications the top half never offered.
        #expect(Listing.overflow(offered: ["a"], showing: ["a", "x", "y"]) == 0)
    }
}
