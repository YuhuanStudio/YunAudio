/// Processing facts carried by source identity rather than a graph slot.
///
/// A graph is allowed to have no routes. Its allocation still contains one
/// dummy slot, so deriving these facts from `routes[0]` turns an empty patchbay
/// into a false statement about the next route. This value outlives any one
/// topology and is the only input needed to rebuild the three realtime flags.
struct RouteProcessingPlan: Sendable, Equatable {
    struct Provenance: Sendable, Equatable {
        let usesIsolatedSource: Bool
        let usesCancelledSource: Bool
        let appliesInputTrim: Bool
    }

    /// The primary input. Trim and mute apply to every channel from this
    /// device, whether or not a processing stage is enabled.
    let microphoneDeviceUID: String
    /// The one source feeding the mono processing stage, when there is one.
    let processedSource: ChannelRef?
    /// Whether VoiceProcessingIO currently owns the microphone signal.
    let echoCancellationActive: Bool

    func provenance(for source: ChannelRef) -> Provenance {
        let fromMicrophone = source.deviceUID == microphoneDeviceUID
        let isolated = source == processedSource
        return Provenance(
            usesIsolatedSource: isolated,
            usesCancelledSource: fromMicrophone && echoCancellationActive && !isolated,
            appliesInputTrim: fromMicrophone)
    }

    /// Changes only the processing stage; topology changes keep this value
    /// untouched, including a transition through an empty route list.
    func replacingProcessedSource(_ source: ChannelRef?) -> Self {
        Self(
            microphoneDeviceUID: microphoneDeviceUID,
            processedSource: source,
            echoCancellationActive: echoCancellationActive)
    }
}
