import AppKit
import SwiftUI
import YunAudioHAL
import YunDesign

/// The list of applications whose audio can be mixed in.
///
/// Extracted because the panel and the window were carrying two copies of it
/// that had already begun to drift — one showed the badge before the spacer,
/// the other after — and because the icon lookup below wants a cache, which
/// duplicated code cannot share.
struct AppSourceList: View {
    @Bindable var model: RouterModel
    /// How many rows to show before the list is truncated. The panel has less
    /// room than the window and says so.
    var limit: Int
    var showsRefresh = true

    var body: some View {
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            if showsRefresh {
                HStack {
                    Text(loc("Pick the applications to mix in"))
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.textTertiary)
                    Spacer()
                    Button(loc("Refresh")) { model.refreshApps() }
                        .buttonStyle(YunButtonStyle(.ghost, small: true))
                }
            }

            let visible = model.visibleApps
            if visible.isEmpty {
                YunEmptyState(
                    symbol: "speaker.slash",
                    message: loc("Nothing is producing audio right now.")
                )
                .frame(maxWidth: .infinity)
            } else {
                ForEach(visible.prefix(limit)) { application in
                    AppSourceRow(model: model, application: application)
                }
                if visible.count > limit {
                    Text(
                        String(
                            format: loc("and %d more"), visible.count - limit)
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .padding(.leading, Yun.Space.sm)
                }
            }

            // The daemons are still reachable, just not first. Someone who
            // genuinely wants to capture `avconferenced` can, and everyone
            // else never sees it.
            if model.hiddenAppCount > 0 || model.showsBackgroundApps {
                Button {
                    model.showsBackgroundApps.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(
                            systemName: model.showsBackgroundApps
                                ? "chevron.down" : "chevron.right"
                        )
                        .font(.system(size: 8, weight: .semibold))
                        Text(
                            model.showsBackgroundApps
                                ? loc("Hide background processes")
                                : String(
                                    format: loc("Show %d background processes"),
                                    model.hiddenAppCount))
                    }
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .padding(.leading, Yun.Space.sm)
            }
        }
    }
}

private struct AppSourceRow: View {
    @Bindable var model: RouterModel
    let application: AudioApplication

    var body: some View {
        let isCaptured = model.capturedAppBundleIDs.contains(application.bundleID)
        Button {
            if isCaptured {
                model.capturedAppBundleIDs.remove(application.bundleID)
            } else {
                model.capturedAppBundleIDs.insert(application.bundleID)
            }
        } label: {
            YunHoverRow {
                HStack(spacing: Yun.Space.sm) {
                    Image(systemName: isCaptured ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(
                            isCaptured ? Yun.Palette.accent : Yun.Palette.textMuted)

                    AppIconView(url: application.bundleURL)

                    Text(application.name)
                        .font(Yun.Text.body)
                        .foregroundStyle(Yun.Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if application.isPlaying { YunBadge(loc("playing")) }

                    Spacer(minLength: 4)

                    // Discord is four processes. Saying so is the difference
                    // between "we picked one of them" and "we take all of it",
                    // and the second is what actually happens.
                    if application.processCount > 1 {
                        Text("×\(application.processCount)")
                            .font(Yun.Text.mono)
                            .foregroundStyle(Yun.Palette.textMuted)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(application.bundleID)
        .accessibilityLabel(Text(application.name))
        .accessibilityAddTraits(isCaptured ? [.isSelected] : [])
    }
}

/// An application's own icon, or a neutral glyph for the daemons that have no
/// bundle to take one from.
///
/// `NSWorkspace.icon(forFile:)` reads from disk, and this is called once per
/// row per redraw, so the results are kept. The cache is keyed on path and
/// never invalidated: an application's icon does not change while it runs.
private struct AppIconView: View {
    let url: URL?

    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        Group {
            if let image = Self.icon(for: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "gearshape")
                    .font(.system(size: 9))
                    .foregroundStyle(Yun.Palette.textMuted)
                    .frame(width: 16, height: 16)
                    .background(Yun.Palette.elevated, in: .rect(cornerRadius: 4))
            }
        }
        .frame(width: 16, height: 16)
    }

    @MainActor
    private static func icon(for url: URL?) -> NSImage? {
        guard let url else { return nil }
        if let cached = cache[url.path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[url.path] = image
        return image
    }
}
