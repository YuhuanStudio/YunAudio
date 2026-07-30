import SwiftUI

/// What a key does on the KTV stage.
///
/// A pure mapping rather than a pile of closures in the view, because the view
/// cannot be exercised: nothing in this project can post a key event at the
/// window server, so the only part of a keyboard shortcut that can be checked
/// by a test is the decision. That is the part that carries the choices —
/// which key seeks and which key shifts the words, and that neither of them is
/// the key that types a space into a text field somewhere else.
enum KTVKeyCommand: Equatable, Sendable {
    /// Play or pause, the one every player gives to the space bar.
    case playPause
    /// Move through the song, in seconds; negative goes back.
    case skip(Double)
    /// Larger or smaller words, in steps; zero means back to what the window
    /// implies.
    case resizeLyrics(Double)
    /// Look up or down the words without moving the music.
    case browse(Int)
    /// Shift the words against the music, in seconds.
    case nudgeLyrics(Double)
    /// Fill the screen, and leave it.
    case toggleFullScreen

    /// Five seconds, which is roughly a line: far enough to be worth a press
    /// and short enough that holding the key is a scrub rather than a jump.
    static let skipStep: Double = 5

    /// Half a second, the same step the two arrows beside the words take.
    static let nudgeStep: Double = 0.5

    /// A tenth, which is two presses to a noticeable change and eight from one
    /// end of the range to the other.
    static let sizeStep: Double = 0.1

    /// The mapping. Nil means the stage does not want the key, and returning
    /// that rather than swallowing it is what leaves ⌘Q, ⌘W and the rest alone.
    static func resolve(_ key: KeyEquivalent, modifiers: EventModifiers = []) -> KTVKeyCommand? {
        // Anything held is somebody else's shortcut. Shift is allowed through
        // because the bracket keys are shifted on some layouts.
        guard !modifiers.contains(.command), !modifiers.contains(.control),
            !modifiers.contains(.option)
        else { return nil }
        // On the character, because `KeyEquivalent` is not equatable and the
        // arrows are ordinary Unicode characters to it.
        switch key.character {
        case KeyEquivalent.space.character: return .playPause
        case KeyEquivalent.leftArrow.character: return .skip(-skipStep)
        case KeyEquivalent.rightArrow.character: return .skip(skipStep)
        case KeyEquivalent.upArrow.character: return .browse(-1)
        case KeyEquivalent.downArrow.character: return .browse(1)
        // Where every application that has a text size puts them.
        case "-", "_": return .resizeLyrics(-sizeStep)
        case "=", "+": return .resizeLyrics(sizeStep)
        case "0": return .resizeLyrics(0)
        case "[": return .nudgeLyrics(-nudgeStep)
        case "]": return .nudgeLyrics(nudgeStep)
        case "f", "F": return .toggleFullScreen
        default: return nil
        }
    }
}
