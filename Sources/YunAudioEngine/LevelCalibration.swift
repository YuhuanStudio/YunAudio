import Foundation

/// Balances several sources against each other from a short measurement.
///
/// Setting up a call with two people on two microphones, or a voice over music,
/// is a job everybody does by ear and nobody does well: you cannot hear your own
/// mix the way the far end does, and the two sources are never loud at the same
/// moment, so there is nothing to compare. Every tool in this category leaves it
/// as two faders and a shrug.
///
/// The measurement is a fixed window in which everyone speaks in turn. Each
/// source is measured only while it is actually producing something — a person
/// who talks for three seconds of ten must not be measured as a third as loud as
/// one who talked the whole time — and the offsets that follow put the voices on
/// the same level and the music underneath them.
public struct LevelCalibration: Sendable, Equatable {

    /// What a source is for, which decides where it should end up.
    public enum Role: String, Sendable, CaseIterable, Codable {
        /// A person talking. All of these end up at the same level.
        case voice
        /// Music or a game. Sits below the voices by a fixed amount.
        case background

        public var title: String {
            switch self {
            case .voice: "Voice"
            case .background: "Background"
            }
        }

        /// What an application is, on the evidence of its bundle identifier.
        ///
        /// Getting this backwards puts a voice call underneath the music, which
        /// is the one arrangement nobody wants — so anything that carries a
        /// person talking is a voice and everything else, including anything
        /// unidentified, is background. A game wrongly treated as a voice is
        /// loud and obvious; a call wrongly treated as background is quiet and
        /// easy to miss until somebody says they cannot hear the guest.
        public static func `default`(forBundleID bundleID: String?) -> Role {
            guard let bundleID = bundleID?.lowercased() else { return .background }
            let voices = [
                "discord", "zoom", "slack", "teams", "skype", "webex", "facetime",
                "whatsapp", "telegram", "meet",
            ]
            return voices.contains(where: { bundleID.contains($0) }) ? .voice : .background
        }
    }

    /// One source's measured level.
    public struct Measurement: Sendable, Equatable {
        public let id: Int
        public let role: Role
        /// Gated RMS in dBFS, or -infinity when the source never produced
        /// anything worth measuring.
        public let decibels: Double
        /// Seconds of material that passed the gate. Below a second there is
        /// not enough to draw a conclusion from.
        public let seconds: Double
        /// The gain this source is already running at, in decibels, so the
        /// proposal is expressed against where the fader is rather than against
        /// unity.
        public let currentGain: Double

        public init(
            id: Int, role: Role, decibels: Double, seconds: Double, currentGain: Double
        ) {
            self.id = id
            self.role = role
            self.decibels = decibels
            self.seconds = seconds
            self.currentGain = currentGain
        }

        /// True when there is enough material to act on.
        public var isUsable: Bool { decibels.isFinite && seconds >= 1 }
    }

    /// What to change, and to what.
    public struct Proposal: Sendable, Equatable {
        public let id: Int
        /// The gain to set, in decibels.
        public let gain: Double
        /// How far it moves from where it is now.
        public let change: Double
    }

    /// Where the voices should land, in dBFS RMS.
    ///
    /// Speech at −20 dBFS RMS peaks around −6 to −10, which leaves the headroom
    /// a transient needs without being so quiet that the far end's automatic
    /// gain has to make up the difference.
    public static let voiceTarget: Double = -20

    /// How far below the voices the background sits.
    ///
    /// Broadcast practice is 15 to 20 LU under speech for music that is meant to
    /// be heard but not listened to. Twelve is a little closer than that,
    /// because a stream is not a documentary and the music is part of it.
    public static let backgroundOffset: Double = -12

    /// The most any single source may be moved.
    ///
    /// A proposal larger than this is not a balance problem — it is a
    /// microphone pointed the wrong way or a gain knob at zero — and quietly
    /// applying 30 dB of make-up would hide that rather than fix it.
    public static let maximumChange: Double = 18

    /// Works out what to change.
    ///
    /// - Returns: One entry per usable source. Sources with too little material
    ///   are left out entirely rather than given a guess.
    public static func propose(from measurements: [Measurement]) -> [Proposal] {
        let usable = measurements.filter(\.isUsable)
        guard !usable.isEmpty else { return [] }

        return usable.compactMap { measurement in
            let target =
                measurement.role == .voice
                ? voiceTarget : voiceTarget + backgroundOffset
            // The measurement was taken after the fader, so the fader's own
            // contribution has to be added back to say where it should be
            // rather than how far it should move.
            let wanted = measurement.currentGain + (target - measurement.decibels)
            let change = wanted - measurement.currentGain
            let limited = max(-maximumChange, min(maximumChange, change))
            // A change smaller than half a decibel is not worth showing
            // somebody, let alone applying.
            guard abs(limited) >= 0.5 else { return nil }
            return Proposal(
                id: measurement.id,
                gain: measurement.currentGain + limited,
                change: limited)
        }
    }

    /// Why a calibration could not conclude, when it could not.
    public enum Problem: Sendable, Equatable {
        /// Nothing was loud enough for long enough.
        case nothingHeard
        /// Some sources produced nothing. Names the ones that did not, because
        /// "it did not work" is not something anybody can act on.
        case silentSources([Int])
    }

    /// Checks a set of measurements before proposing anything.
    public static func problem(with measurements: [Measurement]) -> Problem? {
        guard !measurements.isEmpty else { return .nothingHeard }
        let silent = measurements.filter { !$0.isUsable }.map(\.id)
        if silent.count == measurements.count { return .nothingHeard }
        return silent.isEmpty ? nil : .silentSources(silent)
    }
}
