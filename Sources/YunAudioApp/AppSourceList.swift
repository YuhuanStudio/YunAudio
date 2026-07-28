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

            let listing = model.appListing(limit: limit)
            if listing.applications.isEmpty {
                YunEmptyState(
                    symbol: "speaker.slash",
                    message: loc("Nothing is producing audio right now.")
                )
                .frame(maxWidth: .infinity)
            } else {
                ForEach(listing.applications) { application in
                    AppSourceRow(model: model, application: application)
                }
                if listing.overflow > 0 {
                    Text(String(format: loc("and %d more"), listing.overflow))
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

            // Shown in full, and in their own scroll region: nineteen daemons
            // is taller than the panel, and the truncation that used to swallow
            // them is exactly what made the toggle look broken.
            if !listing.background.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: Yun.Space.sm) {
                        ForEach(listing.background) { application in
                            AppSourceRow(model: model, application: application)
                        }
                    }
                }
                .frame(maxHeight: Self.backgroundListHeight)
            }
        }
        // The list was refreshed by the Refresh button and by starting a route,
        // and by nothing else — so the first time anybody opened this it was
        // empty, and said so, on a machine that was playing three things.
        .task { model.refreshAppsIfStale() }
    }

    /// Enough for about eight rows. The daemons scroll rather than pushing
    /// everything below them off the panel.
    private static let backgroundListHeight: CGFloat = 200
}

private struct AppSourceRow: View {
    @Bindable var model: RouterModel
    let application: AudioApplication

    var body: some View {
        let isCaptured = model.capturedAppBundleIDs.contains(application.bundleID)
        let isExcluded = model.isExcluded(application.bundleID)
        Button {
            guard !isExcluded else { return }
            if isCaptured {
                model.capturedAppBundleIDs.remove(application.bundleID)
            } else {
                model.capturedAppBundleIDs.insert(application.bundleID)
            }
        } label: {
            YunHoverRow {
                HStack(spacing: Yun.Space.sm) {
                    Image(
                        systemName: isExcluded
                            ? "nosign"
                            : (isCaptured ? "checkmark.circle.fill" : "circle")
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(
                        isExcluded
                            ? Yun.Palette.textMuted
                            : (isCaptured ? Yun.Palette.accent : Yun.Palette.textMuted))

                    AppIconView(url: application.bundleURL)

                    Text(application.name)
                        .font(Yun.Text.body)
                        .foregroundStyle(
                            isExcluded ? Yun.Palette.textMuted : Yun.Palette.textPrimary
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if application.isPlaying, !isExcluded { YunBadge(loc("playing")) }
                    if isExcluded { YunBadge(loc("never")) }

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
        // A right-click rather than a control on every row. Excluding something
        // is a thing somebody does once, for a reason they already have — a DAW
        // they lost a take in — and a permanent control for it would put a
        // second decision on a list whose whole job is one easy decision.
        .contextMenu {
            Button(isExcluded ? loc("Allow capturing this") : loc("Never capture this")) {
                model.setExcluded(!isExcluded, bundleID: application.bundleID)
            }
        }
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
