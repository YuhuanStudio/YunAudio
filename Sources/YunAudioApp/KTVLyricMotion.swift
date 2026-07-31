import SwiftUI

/// How the column falls away from the line being sung, and how it moves.
///
/// Three ramps that are one idea: the further a line is from the one the music
/// is on, the quieter, the softer and the later it is. Kept as values rather
/// than as numbers inside the view because none of it can be photographed — a
/// still frame cannot show a delay, and the offscreen render draws one moment
/// of one line. The part that carries the choices is the shape of the ramps,
/// and that is the part a test can hold.
enum KTVLyricMotion {

    /// How visible a line is, by its distance from the one being sung.
    ///
    /// Not symmetrical: the line *after* is the one being read next and the
    /// line before has already been sung, so the same distance ahead is worth
    /// more than behind.
    ///
    /// It used to be three cases — the line before, the line after, and 0.16
    /// for everything else — which was written when the stage drew two lines
    /// each way. It now draws up to four ahead and three behind, so "everything
    /// else" had become four lines at one flat value: the fourth line ahead was
    /// exactly as present as the second, and the column stopped receding after
    /// one step.
    static func opacity(forOffset offset: Int) -> Double {
        switch offset {
        case 0: 1
        case 1: 0.48
        case 2: 0.34
        case 3: 0.24
        case -1: 0.30
        case -2: 0.20
        default: abs(offset) >= 4 && offset > 0 ? 0.16 : 0.14
        }
    }

    /// How soft a line is, in points, at the size it is drawn.
    ///
    /// Proportional to the type rather than fixed: 1.2 points blurred a line at
    /// the size the window used to pick and does nothing at all on a stage set
    /// for a room, where a character is eighty points across.
    ///
    /// Nothing within one line of the centre. The line ahead is the one
    /// somebody is about to sing and the line behind is the one they may still
    /// be finishing; softening either to make the column prettier costs the
    /// person the reason the column is there.
    ///
    /// The old rule was `abs(offset) == 2 ? 1.2 : 0`, which left the third and
    /// fourth lines ahead sharper than the second — the depth of field ran the
    /// wrong way at the far end, and the furthest line was the crispest thing
    /// on the stage after the one being sung.
    static func blurRadius(forOffset offset: Int, pointSize: CGFloat) -> CGFloat {
        let fraction: CGFloat =
            switch abs(offset) {
            case 0, 1: 0
            case 2: 0.030
            case 3: 0.048
            default: 0.064
            }
        return (pointSize * fraction).rounded(toPlaces: 2)
    }

    /// How long a line waits before it follows the one being sung, in seconds.
    ///
    /// A band whose rows all start and stop together moves like a slide
    /// changing, which is what 「生硬」 is. Paper does not do that: the sheet
    /// nearest the hand leads and the ones further away follow it. A step per
    /// line is enough to read as one movement with a shape rather than as
    /// several movements.
    ///
    /// Bounded, because the delay is spent on top of the spring's own settling
    /// time: the far line arriving a fifth of a second after the near one is
    /// the column flowing, and half a second later is the column lagging.
    static let staggerStep: Double = 0.028

    static func stagger(forOffset offset: Int) -> Double {
        min(0.12, Double(abs(offset)) * staggerStep)
    }

    /// What the whole column moves with.
    ///
    /// A spring rather than a curve. `easeOut` arrives and stops dead, which is
    /// the other half of 「生硬」: the line lands like a slide changing. A
    /// spring with a little overshoot left in it settles the way a hand moving
    /// paper does, and the response is long enough to read as motion rather
    /// than as a jump.
    static let advanceResponse: Double = 0.55
    static let advanceDamping: Double = 0.78

    static func advance(forOffset offset: Int) -> Animation {
        .spring(response: advanceResponse, dampingFraction: advanceDamping)
            .delay(stagger(forOffset: offset))
    }
}

extension CGFloat {
    /// Rounded so the value a test asserts is the value the view is given.
    fileprivate func rounded(toPlaces places: Int) -> CGFloat {
        let scale = pow(10, CGFloat(places))
        return (self * scale).rounded() / scale
    }
}
