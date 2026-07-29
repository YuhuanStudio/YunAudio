import YunAudioControl
import YunDesign

extension RemoteCommand {
    /// What to call this where somebody is choosing something to automate.
    ///
    /// The one part of the vocabulary that stayed behind when the rest moved
    /// into `YunAudioControl`: it is the only member that needs `loc()`, and a
    /// command-line tool has no use for a translated label.
    var title: String {
        switch self {
        case .routing: loc("Start / stop routing")
        case .mute: loc("Mute / unmute")
        case .record: loc("Record")
        case .transcribe: loc("Transcribe")
        case .config(let name): name
        case .preset(let name): loc(name)
        case .script: loc("Run a script")
        }
    }
}
