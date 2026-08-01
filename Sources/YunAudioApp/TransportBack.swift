import Foundation

/// What ⏮ means, which depends on where the song is.
///
/// Every transport control ever built answers this the same way and the answer
/// is not obvious from the button: near the start it goes to the previous song,
/// further in it goes to the start of this one. Somebody who has sung two
/// verses and presses it wants the verse again, not the song before; somebody
/// who has just heard the first line wants the song before.
///
/// A value because the boundary is a judgement — and because the two
/// presentations, the media keys and the flow check all have to agree about it.
enum TransportBack: Equatable, Sendable {
    case previousSong
    case restart
    /// No queue at all: ten seconds back, which is what it always did.
    case rewind

    /// How far into a song ⏮ still means "the one before".
    ///
    /// Three seconds. Long enough that pressing it twice quickly walks back
    /// through a queue, short enough that nobody who has started singing loses
    /// their place by reaching for it.
    static let withinSeconds = 3.0

    static func of(position: Double, hasPreviousSong: Bool) -> Self {
        guard hasPreviousSong else { return position > withinSeconds ? .restart : .rewind }
        return position <= withinSeconds ? .previousSong : .restart
    }
}
