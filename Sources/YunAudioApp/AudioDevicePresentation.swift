import YunAudioHAL
import YunDesign

extension AudioDevice {
    /// Exact channel detail, or an honest placeholder while a Bluetooth endpoint
    /// remains metadata-only. Showing `0ch` would claim the picker row cannot do
    /// the very job it is being offered for.
    var inputChannelDetail: String {
        hasCompleteTopology
            ? "\(inputChannels)ch"
            : loc("Bluetooth · loads after selection")
    }

    var outputChannelDetail: String {
        hasCompleteTopology
            ? "\(outputChannels)ch"
            : loc("Bluetooth · loads after selection")
    }
}
