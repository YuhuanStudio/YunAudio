import SwiftUI
import YunAudioEngine
import YunAudioHAL
import YunDesign

/// The inputs and outputs beyond the first of each.
///
/// One component for both ends, and one copy shared by the window and the
/// panel. The two ends differ in exactly three things — the symbol, the words,
/// and whether a channel can be chosen — and writing them twice is how the
/// application list, the recording controls and the level row each ended up as
/// two versions that had already begun to drift.
///
/// It renders nothing at all when there is nothing extra and nothing that could
/// be added, so a machine with one microphone and one pair of speakers sees the
/// interface it saw before this existed.
struct ExtraDeviceList: View {
    @Bindable var model: RouterModel
    /// Which end of the signal this list is for.
    let isInput: Bool

    var body: some View {
        let extras = isInput ? model.additionalSourceUIDs : model.additionalDestinationUIDs
        let addable = isInput ? model.addableSourceDevices : model.addableDestinationDevices
        let dropped = isInput ? model.droppedExtraInputNames : model.droppedExtraOutputNames
        if extras.isEmpty && addable.isEmpty && dropped.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: Yun.Space.sm) {
                ForEach(extras, id: \.self) { uid in
                    row(uid)
                }
                // A device the engine gave up on is out of the list above, so
                // without this line it simply disappeared — which is the exact
                // silent failure the fallback was added to avoid causing.
                if !dropped.isEmpty {
                    Text(
                        String(
                            format: loc("%@ would not join, so it is not in the route."),
                            dropped.joined(separator: ", "))
                    )
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !addable.isEmpty {
                    addButton(addable)
                }
            }
        }
    }

    private func row(_ uid: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            nameRow(uid)
            // A level of its own, under the name, exactly as the primary
            // device above has one under its picker. Without it an extra
            // output was the only thing in the window with nowhere to set its
            // volume — the master is one global gain over the whole mix and
            // cannot say "this output quieter than that one" — and an extra
            // input's fader was only in the mixer, three sections away from
            // the row that put it there.
            levelRow(uid)
        }
    }

    private func nameRow(_ uid: String) -> some View {
        YunHoverRow {
            HStack(spacing: Yun.Space.sm) {
                Image(systemName: isInput ? "mic.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Yun.Palette.textMuted)
                    .frame(width: 14)

                // Given the room before the controls get theirs. Without the
                // priority the name was truncated to "Razer Seiren V…" with
                // half the row empty beside it, because a fixed-size control
                // and a truncatable label resolve in the control's favour.
                // The short name, as the menu bar panel and the status pills
                // already use: a list row shares its width with a channel
                // picker and a remove button, and "Razer Seiren V2 X" arrived
                // truncated to "Razer Seiren V2…" — which drops the only part
                // of the name that tells it from the microphone above it.
                Text(model.shortDeviceName(uid))
                    .font(Yun.Text.body)
                    .foregroundStyle(Yun.Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: Yun.Space.sm)

                // Which channels of an extra input are taken, and a way to
                // change it. Without this a four-channel interface added as a
                // second source silently used whatever its topology pointed at,
                // with nothing in the interface saying which that was — the
                // same defect the primary source's picker exists to prevent,
                // one device along.
                //
                // At the trailing edge, where the picker above puts its own
                // channel badge, so the eye finds the same fact in the same
                // place whichever row it is looking at.
                if isInput {
                    channelMenu(uid)
                }

                Button {
                    if isInput { model.removeSource(uid) } else { model.removeDestination(uid) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Yun.Palette.textMuted)
                        .frame(width: 18, height: 18)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityLabel(Text(loc("Remove")))
                .help(
                    isInput
                        ? loc("Stop mixing this input in.")
                        : loc("Stop sending the mix to this output."))
            }
        }
    }

    /// The one control that differs by end: an input's own fader, or an
    /// output's own level.
    ///
    /// The input's is the same value the mixer strip moves, not a second copy
    /// of it — one number, two places to reach it, which is the opposite of
    /// the duplication this project keeps finding.
    @ViewBuilder
    private func levelRow(_ uid: String) -> some View {
        if isInput {
            // The stored level rather than the running route's gain. Read off
            // the route, the control simply was not there while the router was
            // stopped — which is most of the time somebody is setting one up,
            // and it left the input row with no volume beside an output row
            // that had one.
            slider(
                symbol: "speaker.wave.2.fill",
                decibels: Binding(
                    get: { model.sourceLevel(of: uid) },
                    set: { model.setSourceLevel($0, for: uid) }),
                range: RouterModel.minimumDecibels...RouterModel.maximumOutputTrim,
                help: loc("How loud this input is in the mix."))
        } else {
            slider(
                symbol: "speaker.wave.2.fill",
                decibels: Binding(
                    get: { model.outputTrim(of: uid) },
                    set: { model.setOutputTrim($0, for: uid) }),
                range: RouterModel.minimumDecibels...RouterModel.maximumOutputTrim,
                help: loc("How loud the mix is on this output, on its own."))
        }
    }

    private func slider(
        symbol: String, decibels: Binding<Float>, range: ClosedRange<Float>, help: String
    ) -> some View {
        // Laid out like the level rows above it — icon, slider, reading — so
        // the eye reads a column of levels rather than a new kind of control.
        HStack(spacing: Yun.Space.sm) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(Yun.Palette.textMuted)
                .frame(width: 22, height: 22)
            YunSlider(
                fraction: Binding(
                    get: {
                        Double(
                            (decibels.wrappedValue - range.lowerBound)
                                / (range.upperBound - range.lowerBound))
                    },
                    set: {
                        decibels.wrappedValue =
                            range.lowerBound
                            + Float($0) * (range.upperBound - range.lowerBound)
                    }))
            Text(
                decibels.wrappedValue <= RouterModel.minimumDecibels
                    ? "−∞" : String(format: "%+.1f dB", decibels.wrappedValue)
            )
            .font(Yun.Text.mono)
            .foregroundStyle(Yun.Palette.textTertiary)
            .monospacedDigit()
            .frame(width: 58, alignment: .trailing)
        }
        .help(help)
    }

    private func channelMenu(_ uid: String) -> some View {
        let channels = model.inputDevices.first { $0.uid == uid }?.inputChannels ?? 0
        let choice = model.channelChoice(forSourceUID: uid)
        return Menu {
            if channels >= 2 {
                Button(loc("Stereo")) {
                    model.setChannelChoice(mode: .stereo, channel: 0, forSourceUID: uid)
                }
            }
            ForEach(0..<max(channels, 0), id: \.self) { channel in
                Button(model.channelLabel(channel, ofDeviceUID: uid)) {
                    model.setChannelChoice(
                        mode: .mono, channel: channel, forSourceUID: uid)
                }
            }
        } label: {
            // A pill with a chevron rather than `YunBadge`, which is what this
            // was: the badge is the vocabulary for a fact about a thing — the
            // channel count beside a device name — and it read as one here.
            // The primary source's channel choice is a row of buttons nobody
            // could mistake for a label, and this has to say the same thing in
            // the space of a list row.
            HStack(spacing: 3) {
                Text(
                    choice.mode == .stereo
                        ? loc("Stereo")
                        : model.channelLabel(choice.channel, ofDeviceUID: uid)
                )
                .font(.system(size: 10, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
            }
            .foregroundStyle(Yun.Palette.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Yun.Palette.elevated, in: .rect(cornerRadius: Yun.Radius.pill))
            .overlay {
                RoundedRectangle(cornerRadius: Yun.Radius.pill)
                    .strokeBorder(Yun.Palette.borderHairline, lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: Yun.Radius.pill))
        }
        // `.borderlessButton` draws chrome of its own — measured: it put a
        // disclosure arrow to the *left* of the label and dropped the pill
        // behind it entirely, so the control read as two unrelated words. The
        // button style renders the label as written.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(loc("Which channels of this input are mixed in."))
    }

    private func addButton(_ devices: [AudioDevice]) -> some View {
        Menu {
            ForEach(devices, id: \.uid) { device in
                Button {
                    if isInput {
                        model.addSource(device.uid)
                    } else {
                        model.addDestination(device.uid)
                    }
                } label: {
                    Text(
                        "\(device.name)  ·  \(isInput ? device.inputChannels : device.outputChannels)ch"
                    )
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                Text(isInput ? loc("Add an input") : loc("Add an output"))
            }
            .font(Yun.Text.caption)
            .foregroundStyle(Yun.Palette.textTertiary)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(
            isInput
                ? loc(
                    "Mix a second microphone or line input into the same route. It gets its own fader, mute and level."
                )
                : loc(
                    "Send the same mix to another output as well. For a separate mix with its own levels, use the monitor below."
                ))
    }
}
