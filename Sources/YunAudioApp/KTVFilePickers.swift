import AppKit
import UniformTypeIdentifiers
import YunDesign

/// Opening a song or a lyric file, from either presentation.
///
/// The panel had both of these as private methods and the stage had neither, so
/// the one place people actually sing from could not be handed a song. Sharing
/// the *action* rather than the button is what makes the two agree: the layouts
/// differ and should, but "open a song" cannot mean two things.
@MainActor
enum KTVFilePickers {

    /// A song this application plays itself.
    ///
    /// The one source that costs nothing to follow: no Apple event, no
    /// permission prompt, and a position that is a count of samples rather than
    /// a second-old answer extrapolated forward.
    ///
    /// - Parameters:
    ///   - model: The queue that receives the chosen songs.
    ///   - playingNext: 插播 — after the song being sung rather than behind
    ///     everything already queued.
    static func chooseSongs(into model: RouterModel, playingNext: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = LocalSongPlayer.openableTypes
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        guard playingNext, model.isPlayingOwnSong else {
            open(panel.urls, in: model)
            return
        }
        // Reversed, so choosing three files puts them next in the order they
        // were chosen rather than backwards: each insert lands directly after
        // the song being sung.
        for url in panel.urls.reversed() { model.playSongNext(url) }
    }

    private static func open(_ urls: [URL], in model: RouterModel) {
        guard !model.openSongs(at: urls) else { return }
        let alert = NSAlert()
        alert.messageText = loc("That file could not be played")
        alert.informativeText = loc(
            "Nothing on this Mac could decode it. Try an MP3, M4A, WAV or AIFF.")
        alert.runModal()
    }

    /// A `.lrc` beside the file, or anywhere else.
    static func chooseWords(for model: RouterModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "lrc") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.directoryURL = RouterModel.lyricsDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.openWords(at: url)
    }
}
