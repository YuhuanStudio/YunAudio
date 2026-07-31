import Foundation
import Testing

@testable import YunAudioApp

/// How large the stage opens, on the screens people actually have.
///
/// The old answer was 1080 by 720 on every one of them. What is asserted here
/// is that no screen produces something somebody would immediately resize:
/// never smaller than the minimum, never larger than the screen, and never
/// hanging off an edge.
@Suite("the size the stage opens at")
struct KTVWindowSizeTests {

    /// Usable areas, not panel sizes: `visibleFrame` is what is left after the
    /// menu bar and the Dock.
    private let screens: [(String, CGSize)] = [
        ("MacBook Pro 14-inch", CGSize(width: 1512, height: 892)),
        ("MacBook Pro 16-inch", CGSize(width: 1728, height: 1017)),
        ("4K at default scaling", CGSize(width: 1920, height: 1055)),
        ("5K studio display", CGSize(width: 2560, height: 1415)),
        ("ultrawide", CGSize(width: 3440, height: 1375)),
        ("portrait", CGSize(width: 1080, height: 1860)),
        ("an old 1280 by 800 panel", CGSize(width: 1280, height: 750)),
    ]

    @Test("it never opens smaller than the stage can be used at")
    func neverBelowMinimum() {
        for (name, visible) in screens {
            let size = KTVWindowSize.size(forVisible: visible)
            #expect(size.width >= KTVWindowSize.minimum.width, "\(name)")
            #expect(size.height >= KTVWindowSize.minimum.height, "\(name)")
        }
    }

    @Test("and never larger than the screen it opens on")
    func neverOffTheScreen() {
        for (name, visible) in screens {
            let size = KTVWindowSize.size(forVisible: visible)
            #expect(size.width <= max(visible.width, KTVWindowSize.minimum.width), "\(name)")
            #expect(
                size.height <= max(visible.height, KTVWindowSize.minimum.height), "\(name)")
        }
    }

    @Test("a bigger screen gets a bigger stage, which is the whole point")
    func itGrowsWithTheScreen() {
        let laptop = KTVWindowSize.size(forVisible: CGSize(width: 1512, height: 892))
        let studio = KTVWindowSize.size(forVisible: CGSize(width: 2560, height: 1415))
        #expect(studio.width > laptop.width)
        #expect(studio.height > laptop.height)
        // And the old fixed answer is beaten on the display this is developed
        // against, which is the complaint that started this.
        #expect(studio.width > 1080)
    }

    @Test("but it stops growing before the words become a wall")
    func itIsCapped() {
        let ultrawide = KTVWindowSize.size(forVisible: CGSize(width: 3440, height: 1375))
        #expect(ultrawide.width <= KTVWindowSize.maximumWidth)
        // A 5120-point screen must not produce a 3686-point window.
        let huge = KTVWindowSize.size(forVisible: CGSize(width: 5120, height: 2700))
        #expect(huge.width <= KTVWindowSize.maximumWidth)
    }

    @Test("a tall narrow screen gets a stage that fits its height")
    func portraitFits() {
        let visible = CGSize(width: 1080, height: 1860)
        let size = KTVWindowSize.size(forVisible: visible)
        #expect(size.width <= visible.width)
        #expect(size.height <= visible.height)
    }

    @Test("a screen barely larger than the minimum still opens")
    func tinyScreen() {
        // Smaller than the minimum in both directions: the stage takes what
        // there is rather than refusing, and the caller's window will clamp.
        let size = KTVWindowSize.size(forVisible: CGSize(width: 640, height: 400))
        #expect(size.width == KTVWindowSize.minimum.width)
        #expect(size.height == KTVWindowSize.minimum.height)
    }

    @Test("it is placed inside the screen, a little above centre")
    func placement() {
        for (name, visible) in screens {
            // Screens do not start at zero: a second display sits at an offset,
            // and a frame computed as though it did opens on the wrong one.
            let area = CGRect(x: 1512, y: -200, width: visible.width, height: visible.height)
            let frame = KTVWindowSize.frame(inVisible: area)
            #expect(frame.minX >= area.minX, "\(name)")
            #expect(frame.maxX <= area.maxX + 1, "\(name)")
            #expect(frame.minY >= area.minY, "\(name)")
            #expect(frame.maxY <= area.maxY + 1, "\(name)")
            // Above centre in AppKit's coordinates means a larger y than the
            // exact middle would give.
            let centred = area.minY + (area.height - frame.height) / 2
            #expect(frame.minY >= centred - 1, "\(name)")
        }
    }

    @Test("whole points, so the hairlines inside land on pixels")
    func wholePoints() {
        for (_, visible) in screens {
            let size = KTVWindowSize.size(forVisible: visible)
            #expect(size.width == size.width.rounded())
            #expect(size.height == size.height.rounded())
        }
    }

    @Test("the autosave key is the one AppKit actually writes")
    func autosaveKey() {
        // If this is wrong the window is placed on every launch and somebody's
        // chosen position is thrown away — which is the second half of the bug
        // this replaced.
        #expect(
            KTVWindowSize.autosaveDefaultsKey(for: "YunAudioKTVWindow")
                == "NSWindow Frame YunAudioKTVWindow")
    }
}

/// The shapes the stage refuses.
///
/// The frame saved on this machine was 1180 × 520 — flatter than 2:1 — and it
/// is what the stage opened as, because a saved frame beats any default. The
/// artwork sits beside the words, so a strip leaves neither of them room.
@Suite("the shape the stage refuses")
struct KTVWindowShapeTests {

    @Test("the shape that was actually saved is refused")
    func theReportedShape() {
        let clamped = KTVWindowSize.clamp(CGSize(width: 1180, height: 520))
        #expect(clamped.width == 1180)
        #expect(clamped.height > 520)
        #expect(clamped.height / clamped.width >= KTVWindowSize.minimumAspect)
    }

    @Test("a drag can never produce a letterbox")
    func draggingIsBounded() {
        for width in stride(from: 820.0, through: 3000.0, by: 130.0) {
            let clamped = KTVWindowSize.clamp(CGSize(width: width, height: 100))
            #expect(clamped.height / clamped.width >= KTVWindowSize.minimumAspect - 0.001)
            #expect(clamped.height >= KTVWindowSize.minimum.height)
        }
    }

    @Test("but a taller window is left alone")
    func tallIsFine() {
        // The clamp is a floor on height, not a ratio the window is held to:
        // somebody who wants a tall stage keeps it.
        let tall = KTVWindowSize.clamp(CGSize(width: 1000, height: 1400))
        #expect(tall.height == 1400)
        #expect(tall.width == 1000)
    }

    @Test("and the default is never a shape it would refuse")
    func theDefaultPassesItsOwnClamp() {
        for visible in [
            CGSize(width: 1512, height: 892), CGSize(width: 2560, height: 1415),
            CGSize(width: 3440, height: 1375), CGSize(width: 1080, height: 1860),
            CGSize(width: 640, height: 400),
        ] {
            let size = KTVWindowSize.size(forVisible: visible)
            #expect(KTVWindowSize.clamp(size) == size, "\(visible)")
        }
    }
}
