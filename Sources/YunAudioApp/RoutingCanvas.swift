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
    @State private var hoveredRoute: Route?

    private var sources: [PortGroup] { model.canvasSources }
    private var destinations: [PortGroup] { model.canvasDestinations }

    var body: some View {
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
                    patchbay
                }
            }
        }
    }

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
        VStack(alignment: isSource ? .leading : .trailing, spacing: 0) {
            ForEach(groups) { group in
                Text(group.name)
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(height: pitch, alignment: isSource ? .leading : .trailing)
                ForEach(group.channels, id: \.self) { channel in
                    port(
                        ChannelRef(deviceUID: group.uid, channel: channel),
                        label: "\(loc("Ch")) \(channel + 1)",
                        isSource: isSource, pitch: pitch)
                }
            }
        }
        .frame(width: 132, alignment: isSource ? .leading : .trailing)
    }

    private func port(
        _ reference: ChannelRef, label: String, isSource: Bool, pitch: CGFloat
    ) -> some View {
        let isPending = pendingSource == reference
        let isConnected = model.activeRoutes.contains {
            isSource ? $0.source == reference : $0.destination == reference
        }
        return Button {
            tap(reference, isSource: isSource)
        } label: {
            HStack(spacing: 6) {
                if !isSource { Spacer(minLength: 0) }
                if isSource { Text(label) }
                Circle()
                    .fill(
                        isPending
                            ? Yun.Palette.info
                            : (isConnected ? Yun.Palette.accent : Yun.Palette.elevated)
                    )
                    .overlay { Circle().strokeBorder(Yun.Palette.border, lineWidth: 1) }
                    .frame(width: 9, height: 9)
                if !isSource { Text(label) }
                if isSource { Spacer(minLength: 0) }
            }
            .font(Yun.Text.caption)
            .foregroundStyle(Yun.Palette.textSecondary)
            .frame(height: pitch)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
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

                let from = CGPoint(x: 132, y: start)
                let to = CGPoint(x: size.width - 132, y: end)
                var path = Path()
                path.move(to: from)
                // A flat S rather than a straight line: parallel diagonals of
                // different lengths are hard to follow, curves are not.
                path.addCurve(
                    to: to,
                    control1: CGPoint(x: from.x + (to.x - from.x) * 0.5, y: from.y),
                    control2: CGPoint(x: from.x + (to.x - from.x) * 0.5, y: to.y))
                context.stroke(
                    path,
                    with: .color(
                        hoveredRoute == route
                            ? Yun.Palette.danger : Yun.Palette.accent.opacity(0.5)),
                    lineWidth: hoveredRoute == route ? 2 : 1.5)
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
        model.connect(source: source, destination: reference)
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
