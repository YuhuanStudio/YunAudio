import SwiftUI
import YunAudioEngine
import YunDesign

/// The spectrum, drawn as bars across the audible range.
///
/// One `Canvas` rather than twenty-four `Shape`s: at twenty frames a second a
/// stack of views would be twenty-four layout passes per frame for something
/// that is one path.
struct SpectrumView: View {
    var bands: [Float]
    var isRunning: Bool

    var body: some View {
        let _ = BodyCount.tick("SpectrumView")
        VStack(spacing: 2) {
            chart
            scale
        }
    }

    private var chart: some View {
        Canvas(opaque: false) { context, size in
            guard !bands.isEmpty else { return }

            // Two faint rules across the empty part of the chart. Without them
            // the space above a quiet signal reads as nothing at all; with them
            // it reads as headroom, and the height of a bar becomes a quantity
            // rather than an impression. The display spans −72 dB to 0, so
            // these land at a third and two thirds.
            for decibels in [-48.0, -24.0] {
                let y = size.height * (1 - (decibels + 72) / 72)
                var rule = Path()
                rule.move(to: CGPoint(x: 0, y: y))
                rule.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(
                    rule, with: .color(Yun.Palette.borderHairline), lineWidth: 1)
            }

            let gap: CGFloat = 2
            let width = (size.width - gap * CGFloat(bands.count - 1)) / CGFloat(bands.count)
            guard width > 0 else { return }

            for (index, value) in bands.enumerated() {
                let x = CGFloat(index) * (width + gap)
                // A floor of one point so the shape of the analyser is legible
                // when nothing is playing, rather than the panel appearing empty
                // and broken.
                let height = max(1, CGFloat(value) * size.height)
                let rect = CGRect(
                    x: x, y: size.height - height, width: width, height: height)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: min(2, width / 2)),
                    with: .color(colour(for: index, level: value)))
            }
        }
        .frame(height: 72)
        .opacity(isRunning ? 1 : 0.35)
        .animation(.linear(duration: 0.05), value: bands)
    }

    /// A frequency axis.
    ///
    /// Without one the display says "there is energy over there", which is not
    /// something anybody can act on. With one it says the hum is at 60 Hz and
    /// the sibilance is at 7 kHz, and those are fixable. Three decade marks
    /// rather than a label per band: twenty-four labels at this width would be
    /// unreadable, and the eye interpolates between decades perfectly well.
    private var scale: some View {
        GeometryReader { proxy in
            ForEach(Self.marks, id: \.hertz) { mark in
                Text(mark.title)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Yun.Palette.textMuted)
                    .position(x: position(of: mark.hertz, in: proxy.size.width), y: 6)
            }
        }
        .frame(height: 12)
    }

    private static let marks: [(hertz: Double, title: String)] = [
        (100, "100"), (1000, "1k"), (10000, "10k"),
    ]

    /// Bands are laid out on a log scale, so a label's position is the log of
    /// its frequency within the same range — not a fraction of the band count.
    private func position(of hertz: Double, in width: CGFloat) -> CGFloat {
        let low = SpectrumAnalyser.lowestFrequency
        let high = SpectrumAnalyser.highestFrequency
        let fraction = log(hertz / low) / log(high / low)
        return width * CGFloat(fraction)
    }

    /// Colour carries frequency, not level: the point of the display is to say
    /// *where* the energy is, and a bar that changes hue as it grows would make
    /// two bars of different heights unreadable against each other.
    private func colour(for index: Int, level: Float) -> Color {
        let position = Double(index) / Double(max(1, bands.count - 1))
        let base = Color(
            hue: 0.58 - position * 0.16, saturation: 0.55, brightness: 0.95)
        return base.opacity(0.35 + Double(level) * 0.65)
    }
}

/// The spectrum, reading the analyser rather than being handed it.
///
/// One line, and it is the reason it exists. The bands used to be read in the
/// window's own body — `SpectrumView(bands: model.analysis.bands, …)` — which
/// made a reading twenty times a second a dependency of the *whole window*:
/// measured at 19.8 body evaluations a second for `MainWindow`, one per poll,
/// each of them re-deriving the header, the device pickers, the patchbay and
/// the inspector for a picture that had changed by one frame. `@Observable`
/// tracks per property, but per property reached *anywhere* in a body, and the
/// window's columns are computed properties of the window rather than views of
/// their own. Reading it here puts the invalidation where the moving picture
/// is.
struct LiveSpectrum: View {
    let model: RouterModel

    var body: some View {
        let _ = BodyCount.tick("LiveSpectrum")
        SpectrumView(bands: model.analysis.bands, isRunning: model.isRunning)
    }
}

/// Loudness to the broadcast standard, and how far it is from the platform the
/// user is aiming at.
struct LoudnessReadout: View {
    @Bindable var model: RouterModel

    var body: some View {
        let _ = BodyCount.tick("LoudnessReadout")
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            outgoing
            YunDivider()
            HStack(alignment: .firstTextBaseline, spacing: Yun.Space.lg) {
                figure(
                    loc("Short-term"), model.analysis.shortTerm, unit: loc("LUFS"),
                    isPrimary: true)
                // Held back until the gate has enough material to mean
                // anything. Showing −54.6 with "not meaningful yet" written
                // directly underneath asks the reader to believe two things at
                // once, and the number is the one they will believe.
                figure(
                    loc("Integrated"),
                    model.loudnessOffset == nil ? -.infinity : model.analysis.integrated,
                    unit: loc("LUFS"))
                figure(loc("Peak"), model.analysis.peak, unit: loc("dBFS"))
                // The note being sung or spoken, which nothing else in this
                // category shows and which anybody using the voice presets
                // wants: it is the number the shift is relative to.
                pitchFigure
                Spacer(minLength: 0)
            }

            YunDivider()

            HStack(spacing: Yun.Space.sm) {
                Text(loc("Target"))
                    .font(Yun.Text.label)
                    .foregroundStyle(Yun.Palette.textSecondary)
                YunSelect(
                    selection: $model.loudnessTarget,
                    options: LoudnessTarget.allCases.map {
                        .init(
                            value: $0, title: $0.title,
                            detail: String(format: loc("%d LUFS"), Int($0.lufs)))
                    })
                Spacer(minLength: 0)
                Button(loc("Reset")) { model.resetLoudness() }
                    .buttonStyle(YunButtonStyle(.ghost, small: true))
            }

            verdict
            YunDivider()
            autoLevel
        }
    }

    /// The levelling loop, and what the model is hearing.
    ///
    /// The two belong together: the classifier's verdict is the reason the
    /// levelling can be trusted, and showing it is what stops the feature being
    /// a black box. When it says it is waiting, the readout says why.
    @ViewBuilder
    private var autoLevel: some View {
        HStack(spacing: Yun.Space.sm) {
            YunSwitch(isOn: $model.isAutoLevelling)
            VStack(alignment: .leading, spacing: 1) {
                Text(loc("Hold this level automatically"))
                    .font(Yun.Text.label)
                    .foregroundStyle(Yun.Palette.textPrimary)
                Text(
                    loc(
                        "Moves the trim only while Apple's on-device model hears speech, so pauses and keyboards do not wind the gain up."
                    )
                )
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }

        HStack(spacing: Yun.Space.sm) {
            heardBadge
            Spacer(minLength: 0)
            if model.isAutoLevelling {
                Text(autoLevelState)
                    .font(Yun.Text.mono)
                    .foregroundStyle(
                        model.autoLevelIsAtLimit || model.autoLevelIsHeldByHeadroom
                            ? Yun.Palette.warning : Yun.Palette.textTertiary
                    )
                    .monospacedDigit()
            }
        }
    }

    private var autoLevelState: String {
        Self.autoLevelState(
            offset: model.autoLevelOffset, isWaiting: model.autoLevelIsWaiting,
            isAtLimit: model.autoLevelIsAtLimit,
            isHeldByHeadroom: model.autoLevelIsHeldByHeadroom)
    }

    /// What the loop's state reads as, as a pure function of the loop's state.
    ///
    /// Static and taking its inputs rather than reading the model, so the flow
    /// check can put it in every state and read back what a person would see.
    /// A state the loop publishes and the interface never renders is the defect
    /// this is guarding: `isHeldByHeadroom` was computed on every tick and had
    /// no reader anywhere in the repository, while its two siblings were drawn
    /// side by side in this very line.
    static func autoLevelState(
        offset: Double, isWaiting: Bool, isAtLimit: Bool, isHeldByHeadroom: Bool
    ) -> String {
        if isAtLimit { return loc("out of range") }
        if isWaiting { return loc("waiting for speech") }
        // Without this the loop looks stuck: it is hearing speech, it is under
        // target, it is not at its limit, and it is deliberately refusing to go
        // up because the peak would clip. "Nothing is happening" and "the peaks
        // are what is stopping it" look identical otherwise, and only one of
        // them is something a person can act on.
        if isHeldByHeadroom {
            return String(format: loc("%+.1f dB · held by peaks"), offset)
        }
        return String(format: "%+.1f dB", offset)
    }

    /// What the classifier hears, as a small badge.
    private var heardBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol(for: model.heardVerdict))
                .font(.system(size: 10))
            Text(title(for: model.heardVerdict))
                .font(Yun.Text.caption)
            // The number behind the word. It was computed and shown nowhere,
            // which leaves the badge saying "Typing" with the same authority
            // whether the classifier is certain or guessing between two things
            // — and it is the guessing case that explains why the automatic
            // trim just stopped moving.
            Text(String(format: "%.0f%%", model.heardConfidence * 100))
                .font(Yun.Text.mono)
                .monospacedDigit()
                .opacity(0.65)
        }
        .foregroundStyle(tint(for: model.heardVerdict))
        .padding(.horizontal, Yun.Space.sm)
        .padding(.vertical, 3)
        .background(
            tint(for: model.heardVerdict).opacity(0.12),
            in: .rect(cornerRadius: Yun.Radius.pill)
        )
        // The model's own label is finer than the badge, and is what somebody
        // debugging their room actually wants.
        .help(model.analysis.verdictLabel)
    }

    private func symbol(for verdict: SoundClassifier.Verdict) -> String {
        switch verdict {
        case .speech: "waveform"
        case .typing: "keyboard"
        case .music: "music.note"
        case .noise: "wind"
        case .quiet: "moon.zzz"
        }
    }

    private func title(for verdict: SoundClassifier.Verdict) -> String {
        switch verdict {
        case .speech: loc("Speech")
        case .typing: loc("Typing")
        case .music: loc("Music")
        case .noise: loc("Room noise")
        case .quiet: loc("Quiet")
        }
    }

    private func tint(for verdict: SoundClassifier.Verdict) -> Color {
        switch verdict {
        case .speech: Yun.Palette.success
        case .typing: Yun.Palette.warning
        case .music: Yun.Palette.info
        case .noise: Yun.Palette.textTertiary
        case .quiet: Yun.Palette.textMuted
        }
    }

    /// The fundamental, with the note it corresponds to.
    ///
    /// Hertz alone means something to about one person in fifty; the note name
    /// beside it means something to anybody who has ever touched an
    /// instrument, and it is the same number.
    private var pitchFigure: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(loc("Pitch"))
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(
                    model.analysis.pitchHertz > 0
                        ? String(format: "%.0f", model.analysis.pitchHertz) : "—"
                )
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(
                    model.analysis.pitchHertz > 0
                        ? Yun.Palette.textPrimary : Yun.Palette.textMuted
                )
                .monospacedDigit()
                Text(loc("Hz"))
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textMuted)
                if let note = PitchTracker.noteName(model.analysis.pitchHertz) {
                    YunBadge(note)
                }
            }
        }
    }

    /// The level actually leaving, and a sentence about it.
    ///
    /// This is the first thing in the card because it is the first thing to
    /// check when a call sounds wrong, and until now the application could not
    /// answer it at all: every meter here was taken before the gain stages, so
    /// a signal being truncated on the way out looked perfectly healthy. Both
    /// failure modes are silent otherwise — too loud is distortion nothing was
    /// watching for, and too quiet means the far end's own automatic gain
    /// amplifies the room noise along with the voice.
    @ViewBuilder
    private var outgoing: some View {
        HStack(alignment: .firstTextBaseline, spacing: Yun.Space.sm) {
            Text(loc("Leaving"))
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
            Text(
                model.outputPeakDecibels.isFinite
                    ? String(format: "%.1f", model.outputPeakDecibels) : "—"
            )
            .font(.system(size: 15, weight: .medium, design: .monospaced))
            .foregroundStyle(outputTint)
            .monospacedDigit()
            Text(loc("dBFS"))
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textMuted)
            Spacer(minLength: 0)
            if model.outputClippedSamples > 0 {
                Button(loc("Clear")) { model.clearClipping() }
                    .buttonStyle(YunButtonStyle(.ghost, small: true))
            }
        }
        HStack(spacing: Yun.Space.sm) {
            Circle().fill(outputTint).frame(width: 6, height: 6)
            Text(outputAdvice)
                .font(Yun.Text.caption)
                .foregroundStyle(
                    model.outputVerdict == .good
                        ? Yun.Palette.textTertiary : Yun.Palette.textSecondary
                )
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var outputTint: Color {
        switch model.outputVerdict {
        case .clipping: Yun.Palette.danger
        case .hot: Yun.Palette.warning
        case .good: Yun.Palette.success
        case .quiet: Yun.Palette.warning
        case .veryQuiet: Yun.Palette.danger
        case .silent: Yun.Palette.textMuted
        }
    }

    private var outputAdvice: String {
        switch model.outputVerdict {
        case .clipping:
            String(
                format: loc(
                    "Clipped %@ times. Lower the input level or the master — this is already distortion the far end can hear."
                ), "\(model.outputClippedSamples)")
        case .hot: loc("Very close to full scale. A little headroom is worth keeping.")
        case .good: loc("A healthy level to send.")
        // The advice differs by what the hardware actually offers. Telling
        // somebody to raise their microphone's gain is useless when the device
        // publishes none to macOS — the Seiren V3 Pro is exactly that case, and
        // its only pre-converter gain is the knob on the front.
        case .quiet:
            model.hardwareGain?.isSettable == true
                ? loc(
                    "Quiet. The other end will run its own automatic gain over this and amplify the room with it — raise the microphone's own gain first, then the input level."
                )
                : loc(
                    "Quiet. The other end will run its own automatic gain over this and amplify the room with it. This microphone exposes no gain to macOS, so turn the knob on the device itself, then raise the input level."
                )
        case .veryQuiet:
            model.hardwareGain?.isSettable == true
                ? loc(
                    "Far too quiet to send. Raise the microphone's own gain, then the input level."
                )
                : loc(
                    "Far too quiet to send. Turn up the knob on the microphone itself — it exposes no gain to macOS — then raise the input level."
                )
        case .silent: loc("Nothing is reaching the output.")
        }
    }

    /// What the number means, in a sentence.
    ///
    /// A bare "−19.4 LUFS" is only useful to somebody who already knows what
    /// Discord does with it. The whole reason to show loudness rather than just
    /// peaks is to answer "am I too quiet", so it answers that.
    @ViewBuilder
    private var verdict: some View {
        if let offset = model.loudnessOffset {
            let rounded = (offset * 10).rounded() / 10
            HStack(spacing: Yun.Space.sm) {
                Circle()
                    .fill(verdictColour(abs(rounded)))
                    .frame(width: 6, height: 6)
                Text(verdictText(rounded))
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        } else {
            Text(
                loc(
                    "Keep talking for a few seconds — the integrated figure is not meaningful until there is material to gate."
                )
            )
            .font(Yun.Text.caption)
            .foregroundStyle(Yun.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One unit either way is inaudible and not worth chasing; past three, a
    /// platform's normalisation will move the whole thing audibly.
    private func verdictColour(_ magnitude: Double) -> Color {
        if magnitude <= 1 { return Yun.Palette.success }
        if magnitude <= 3 { return Yun.Palette.warning }
        return Yun.Palette.danger
    }

    private func verdictText(_ offset: Double) -> String {
        if abs(offset) <= 1 {
            return String(
                format: loc("On target for %@."), model.loudnessTarget.title)
        }
        let amount = String(format: "%.1f", abs(offset))
        return offset > 0
            ? String(
                format: loc("%@ LU louder than %@ expects — it will be turned down."),
                amount, model.loudnessTarget.title)
            : String(
                format: loc("%@ LU quieter than %@ expects — raise the master or gain."),
                amount, model.loudnessTarget.title)
    }

    private func figure(
        _ title: String, _ value: Double, unit: String, isPrimary: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.isFinite ? String(format: "%.1f", value) : "—")
                    .font(
                        .system(
                            size: isPrimary ? 22 : 15,
                            weight: isPrimary ? .semibold : .medium,
                            design: .monospaced)
                    )
                    .foregroundStyle(
                        value.isFinite ? Yun.Palette.textPrimary : Yun.Palette.textMuted
                    )
                    // A number that changes width as it crosses −10 makes the
                    // whole row jitter twenty times a second.
                    .monospacedDigit()
                Text(unit)
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textMuted)
            }
        }
    }
}
