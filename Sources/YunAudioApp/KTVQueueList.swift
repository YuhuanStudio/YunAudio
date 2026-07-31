import AppKit
import SwiftUI
import YunDesign

/// 點歌單: the songs that have been put on, and the buttons that put them there.
///
/// `KTVQueue` was written as a value, tested to death — 插播 goes next not last,
/// the end stops rather than starting the evening again, removing the song being
/// sung plays whatever moved up — wired into the transport and asserted in the
/// flow check. And then it had no interface at all. Not one button, on the stage
/// or in the panel, for putting a song on or seeing what was coming.
///
/// A feature nobody can reach was not delivered. This is the part that was
/// missing.
struct KTVQueueList: View {
    @Bindable var model: RouterModel
    /// The stage sits on a darkened photograph and the inspector on a card, so
    /// the two need different text colours for the same list.
    var onDarkStage = true

    var body: some View {
        let _ = BodyCount.tick("KTVQueueList")
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            header
            if model.allQueuedSongs.isEmpty {
                Text(loc("Nothing is on yet. Put a song on and it starts; put more on and they wait."))
                    .font(Yun.Text.caption)
                    .foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                list
            }
        }
        .frame(minWidth: 300, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: Yun.Space.sm) {
            Text(loc("Songs on"))
                .font(Yun.Text.title)
                .foregroundStyle(primary)
            Spacer(minLength: Yun.Space.sm)
            // 重唱: on a real machine this is a button, not a setting buried in
            // a menu — the moment somebody wants a song again is the moment it
            // ends.
            Toggle(loc("Sing it again"), isOn: $model.repeatsOneSong)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel(loc("Sing it again"))
                .accessibilityIdentifier("KTVRepeatOne")
            Image(systemName: "repeat.1")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.repeatsOneSong ? Yun.Palette.accent : secondary)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.allQueuedSongs.enumerated()), id: \.offset) { position, url in
                row(position: position, url: url)
            }
            HStack(spacing: Yun.Space.sm) {
                Button(loc("Add songs…")) {
                    KTVFilePickers.chooseSongs(into: model)
                }
                    .buttonStyle(YunButtonStyle(.primary, small: true))
                    .accessibilityIdentifier("KTVAddSongs")
                Button(loc("插播")) {
                    KTVFilePickers.chooseSongs(into: model, playingNext: true)
                }
                    .buttonStyle(YunButtonStyle(.secondary, small: true))
                    .accessibilityIdentifier("KTVPlayNext")
                Button(loc("Choose the words…")) {
                    KTVFilePickers.chooseWords(for: model)
                }
                .buttonStyle(YunButtonStyle(.secondary, small: true))
                .accessibilityIdentifier("KTVChooseWords")
                Spacer(minLength: 0)
                Button(loc("Clear")) { model.clearSongQueue() }
                    .buttonStyle(YunButtonStyle(.ghost, small: true))
                    .accessibilityIdentifier("KTVClearQueue")
            }
            .padding(.top, Yun.Space.sm)
        }
    }

    private func row(position: Int, url: URL) -> some View {
        let isCurrent = model.currentQueueIndex == position
        let isSung = (model.currentQueueIndex ?? Int.max) > position
        return HStack(spacing: Yun.Space.sm) {
            Image(systemName: isCurrent ? "music.note" : "\(min(position + 1, 50)).circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isCurrent ? Yun.Palette.accent : secondary)
                .frame(width: 16)
            Text(url.deletingPathExtension().lastPathComponent)
                .font(isCurrent ? Yun.Text.label : Yun.Text.body)
                .foregroundStyle(isCurrent ? primary : (isSung ? secondary.opacity(0.6) : primary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Yun.Space.sm)
            Button {
                model.removeQueuedSong(at: position)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc("Take it off"))
        }
        .padding(.horizontal, Yun.Space.sm)
        .padding(.vertical, 5)
        .background(
            isCurrent ? Yun.Palette.accent.opacity(0.14) : .clear,
            in: .rect(cornerRadius: Yun.Radius.control)
        )
        .contentShape(.rect)
        // Pointing at a line plays it, which is what the list is for.
        .onTapGesture { model.chooseQueuedSong(at: position) }
        .accessibilityIdentifier("KTVQueueRow\(position)")
    }

    private var primary: Color { onDarkStage ? .white : Yun.Palette.textPrimary }
    private var secondary: Color {
        onDarkStage ? .white.opacity(0.6) : Yun.Palette.textSecondary
    }

}
