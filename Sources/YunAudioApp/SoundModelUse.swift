import YunDesign

/// Why Apple's on-device sound model is loaded, which is not always the switch.
///
/// The switch beside 「Identify sounds」 reads like a master switch for the
/// model and is not one: automatic levelling and ducking both act on the
/// model's verdict, so either of them switched on loads it whatever the switch
/// says. The interface then showed a switch that was off directly above a
/// feature whose own caption says it needs the model — which is a contradiction
/// on screen, and the honest reading of it is that one of the two is lying.
///
/// Neither was. The switch decides whether the *readout* is kept up for its own
/// sake; the model's lifetime is the union of everything that needs it. This
/// says which of those is true so the caption can stop implying otherwise.
enum SoundModelUse: Equatable, Sendable {
    /// Nothing wants it, so it is not loaded.
    case notLoaded
    /// The switch is on: the readout is being kept up because somebody asked.
    case forTheReadout
    /// The switch is off and the model is loaded anyway, because levelling or
    /// ducking is acting on it. This is the case the interface used to deny.
    case forSomethingElse

    static func of(identifying: Bool, levelling: Bool, ducking: Bool) -> Self {
        if identifying { return .forTheReadout }
        return levelling || ducking ? .forSomethingElse : .notLoaded
    }

    /// True whenever the model is in memory, whatever the switch says.
    var isLoaded: Bool { self != .notLoaded }

    /// What to say under the switch.
    @MainActor var caption: String {
        switch self {
        case .forSomethingElse:
            loc(
                "Already loaded, because automatic levelling or ducking is using it. This switch only keeps the readout up."
            )
        case .notLoaded, .forTheReadout:
            loc(
                "Loads Apple's on-device sound model only while this readout, automatic levelling or ducking needs it."
            )
        }
    }
}
