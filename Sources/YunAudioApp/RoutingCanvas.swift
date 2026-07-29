import SwiftUI
import YunAudioEngine
import YunAudioHAL
import YunDesign

/// A patchbay: sources on the left, destinations on the right, cables between.
///
/// The engine has always routed an arbitrary N to M and, since the graph became
/// swappable, has been able to change that while audio flows. A list of rows
/// could never express it — a list has no way to show that one source feeds two
/// destinations, which is the whole reason the matrix exists. Clicking a port on
/// each side makes a cable; clicking a cable removes it.
struct RoutingCanvas: View {
    @Bindable var model: RouterModel

    /// The port waiting for its other end, if a source has been clicked.
    @State private var pendingSource: ChannelRef?
    /// The port under the cursor, when it carries cables. Highlights them.
    @State private var hoveredPort: ChannelRef?

    private var sources: [PortGroup] { model.canvasSources }
    private var destinations: [PortGroup] { model.canvasDestinations }

    var body: some View {
        let _ = BodyCount.tick("RoutingCanvas")
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            HStack {
                Text(loc("Patchbay"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .textCase(.uppercase)
                Spacer()
                if pendingSource != nil {
                    Text(loc("Pick a destination"))
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.info)
                    Button(loc("Cancel")) { pendingSource = nil }
                        .buttonStyle(YunButtonStyle(.ghost, small: true))
                }
            }

            YunCard(padding: Yun.Space.lg) {
                if sources.isEmpty || destinations.isEmpty {
                    YunEmptyState(
                        symbol: "cable.connector",
                        message: loc("Pick an input and an output to start patching.")
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: Yun.Space.sm) {
                        patchbay
                        if model.hiddenCanvasChannels > 0 || model.showsAllCanvasChannels {
                            Button {
                                model.showsAllCanvasChannels.toggle()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(
                                        systemName: model.showsAllCanvasChannels
                                            ? "chevron.up" : "chevron.down"
                                    )
                                    .font(.system(size: 8, weight: .semibold))
                                    Text(
                                        model.showsAllCanvasChannels
                                            ? loc("Fewer channels")
                                            : String(
                                                format: loc("Show %d more channels"),
                                                model.hiddenCanvasChannels))
                                }
                                .font(Yun.Text.caption)
                                .foregroundStyle(Yun.Palette.textTertiary)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                        }
                    }
                }
            }
        }
    }

    /// Width of each port column. The cables are anchored against it, so it is
    /// a constant rather than a layout result.
    private static let columnWidth: CGFloat = 132
    private static let dotRadius: CGFloat = 4.5

    private var patchbay: some View {
        // A fixed row pitch is what lets the cables be drawn from arithmetic
        // rather than from a preference-key dance to collect real port frames.
        let pitch: CGFloat = 26
        let rows = max(portCount(sources), portCount(destinations))
        let height = CGFloat(rows) * pitch + 8

        return ZStack(alignment: .topLeading) {
            GeometryReader { geometry in
                cables(in: geometry.size, pitch: pitch)
            }
            HStack(alignment: .top, spacing: 0) {
                column(sources, isSource: true, pitch: pitch)
                Spacer(minLength: Yun.Space.xl)
                column(destinations, isSource: false, pitch: pitch)
            }
        }
        .frame(height: height)
    }

    private func portCount(_ groups: [PortGroup]) -> Int {
        groups.reduce(0) { $0 + 1 + $1.channels.count }
    }

    private func column(_ groups: [PortGroup], isSource: Bool, pitch: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groups) { group in
                Text(group.name)
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(
                        maxWidth: .infinity, minHeight: pitch, maxHeight: pitch,
                        alignment: isSource ? .leading : .trailing)
                ForEach(group.channels, id: \.self) { channel in
                    port(
                        ChannelRef(deviceUID: group.uid, channel: channel),
                        label: isSource
                            ? model.sourceChannelLabel(channel)
                            : "\(loc("Ch")) \(channel + 1)",
                        isSource: isSource, pitch: pitch)
                }
            }
        }
        .frame(width: Self.columnWidth)
    }

    private func port(
        _ reference: ChannelRef, label: String, isSource: Bool, pitch: CGFloat
    ) -> some View {
        let isPending = pendingSource == reference
        let isConnected = model.activeRoutes.contains {
            isSource ? $0.source == reference : $0.destination == reference
        }
        // The dot is pinned to the column's inner edge in both columns, because
        // that edge is where `cables` starts and ends its curves. Letting the
        // label's width decide where the dot lands is what left a forty-point
        // gap between every cable and the port it claimed to reach.
        let dot = Circle()
            .fill(
                isPending
                    ? Yun.Palette.info
                    : (isConnected ? Yun.Palette.accent : Yun.Palette.elevated)
            )
            .overlay { Circle().strokeBorder(Yun.Palette.border, lineWidth: 1) }
            .frame(width: Self.dotRadius * 2, height: Self.dotRadius * 2)

        return Button {
            tap(reference, isSource: isSource)
        } label: {
            HStack(spacing: 6) {
                if isSource {
                    Text(label)
                    Spacer(minLength: 4)
                    dot
                } else {
                    dot
                    Text(label)
                    Spacer(minLength: 4)
                }
            }
            .font(Yun.Text.caption)
            .foregroundStyle(
                isConnected ? Yun.Palette.textPrimary : Yun.Palette.textSecondary
            )
            .frame(maxWidth: .infinity, minHeight: pitch, maxHeight: pitch)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Hovering a connected port lights the cables it carries, so what a
        // click is about to remove is visible before the click.
        .onHover { inside in
            if inside {
                hoveredPort = isConnected ? reference : nil
            } else if hoveredPort == reference {
                hoveredPort = nil
            }
        }
        .help(
            isSource
                ? loc("Click to start a cable from this channel.")
                : (isConnected
                    ? loc("Click to pull every cable reaching this channel.")
                    : loc("Click to land the pending cable here."))
        )
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isConnected ? [.isSelected] : [])
    }

    /// Draws the cables. Positions come from the same arithmetic the columns
    /// use, so the two cannot drift apart.
    private func cables(in size: CGSize, pitch: CGFloat) -> some View {
        Canvas { context, _ in
            for route in model.activeRoutes {
                guard let start = position(of: route.source, in: sources, pitch: pitch),
                    let end = position(of: route.destination, in: destinations, pitch: pitch)
                else { continue }

                let from = CGPoint(x: Self.columnWidth - Self.dotRadius, y: start)
                let to = CGPoint(x: size.width - Self.columnWidth + Self.dotRadius, y: end)
                var path = Path()
                path.move(to: from)
                // A flat S rather than a straight line: parallel diagonals of
                // different lengths are hard to follow, curves are not.
                path.addCurve(
                    to: to,
                    control1: CGPoint(x: from.x + (to.x - from.x) * 0.5, y: from.y),
                    control2: CGPoint(x: from.x + (to.x - from.x) * 0.5, y: to.y))

                // Red rather than merely brighter: hovering a destination is
                // one click away from pulling these out, and the colour should
                // say which way that click goes.
                let isHighlighted =
                    hoveredPort == route.source || hoveredPort == route.destination
                let willBeRemoved = hoveredPort == route.destination

                // The cable carries its own level. A patchbay whose cables all
                // look the same cannot answer the question anybody actually has
                // in front of it — which of these is carrying anything — and
                // the meters that could are in a different card.
                let level = model.level(of: route)
                let lit = min(1, Double(level) * 4)

                context.stroke(
                    path,
                    with: .color(
                        willBeRemoved
                            ? Yun.Palette.danger
                            : Yun.Palette.accent.opacity(isHighlighted ? 0.9 : 0.35)),
                    lineWidth: isHighlighted ? 2 : 1.5)

                if lit > 0.02 && !willBeRemoved {
                    // Drawn over the top rather than instead: the quiet line
                    // stays as the route, and this is the signal on it.
                    context.stroke(
                        path,
                        with: .color(Yun.Palette.success.opacity(0.35 + 0.65 * lit)),
                        lineWidth: 1.5 + 2 * lit)
                }
            }
        }
    }

    private func position(
        of reference: ChannelRef, in groups: [PortGroup], pitch: CGFloat
    ) -> CGFloat? {
        var row = 0
        for group in groups {
            row += 1  // the device name
            for channel in group.channels {
                if group.uid == reference.deviceUID && channel == reference.channel {
                    return CGFloat(row) * pitch + pitch / 2
                }
                row += 1
            }
        }
        return nil
    }

    private func tap(_ reference: ChannelRef, isSource: Bool) {
        if isSource {
            pendingSource = pendingSource == reference ? nil : reference
            return
        }
        // Clicking a connected destination with nothing pending removes what
        // reaches it, which is how a cable gets pulled out.
        guard let source = pendingSource else {
            model.disconnect(destination: reference)
            return
        }
        // Picking a source and clicking a destination it already feeds used to
        // do nothing at all: `connect` guards on the route existing, so the
        // pending source was silently dropped and the canvas looked broken.
        // Pulling that one cable is the only other thing the gesture can mean,
        // and it is the only way to reach `disconnectRoute` — with two sources
        // on one destination there was no way to remove just one of them
        // without pulling both and patching the survivor back.
        if model.activeRoutes.contains(
            where: { $0.source == source && $0.destination == reference })
        {
            model.disconnectRoute(source: source, destination: reference)
        } else {
            model.connect(source: source, destination: reference)
        }
        pendingSource = nil
    }
}

/// One device's ports on the canvas.
struct PortGroup: Identifiable, Hashable {
    let uid: String
    let name: String
    let channels: [Int]
    var id: String { uid }
}
