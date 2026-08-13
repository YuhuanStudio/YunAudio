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

/// Four quantities that keep each number attached to its unit.
///
/// A type of its own so the constrained 316-point state can be rendered and
/// measured without constructing a router or opening any audio device.
struct LoudnessFigures: View {
    let shortTerm: Double
    let integrated: Double
    let peak: Double
    let pitchHertz: Float

    var body: some View {
        // A compact presentation has 316 points inside this card. These four
        // figures need about 340 points in Traditional Chinese, so an HStack
        // did not fit: SwiftUI split −18.6 and 147 over two lines to preserve
        // the row. A balanced wrap makes that constrained state an intentional
        // two-by-two readout while retaining one row in the main window.
        YunWrap(
            spacing: Self.horizontalSpacing, lineSpacing: Yun.Space.md,
            balanced: true, fills: true
        ) {
            LoudnessFigure(
                title: loc("Short-term"), value: shortTerm, unit: loc("LUFS"),
                isPrimary: true)
            LoudnessFigure(
                title: loc("Integrated"), value: integrated, unit: loc("LUFS"))
            LoudnessFigure(title: loc("Peak"), value: peak, unit: loc("dBFS"))
            LoudnessPitchFigure(hertz: pitchHertz)
        }
    }

    /// The measured content width of the compact presentation.
    static let compactContentWidth: CGFloat = 316
    static let horizontalSpacing = Yun.Space.lg
}

/// One readout token; wrapping is a decision between tokens, never within one.
struct LoudnessFigure: View {
    let title: String
    let value: Double
    let unit: String
    var isPrimary = false

    /// Below this there is no reading, only arithmetic.
    ///
    /// A silent room measured −150.3 LUFS and −128.5 dBFS, and both were
    /// printed in full. Nothing is wrong with the numbers — that is what the
    /// integrator returns for a signal that is all dither — but they are not
    /// measurements of anything, and broadcast meters have floored around here
    /// for the same reason for forty years.
    ///
    /// It was also a layout fault, which is how it was noticed. The row is
    /// sized from the width of the readings it expects; −150.3 is a glyph wider
    /// than −18.6 at 22 points and −128.5 is one wider than −6.2, and the two
    /// together pushed each figure into the label of the next one. Widening
    /// every column to fit a number that means nothing would be paying for the
    /// meaningless case twice.
    static let noReadingBelow: Double = -70

    /// What to print, which is a dash when the value is not a reading.
    ///
    /// The same dash the panel already uses for "no value yet", because to
    /// somebody looking at it those are the same fact: there is nothing to
    /// measure here.
    static func text(for value: Double) -> String {
        guard value.isFinite, value > noReadingBelow else { return "—" }
        return String(format: "%.1f", value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(Self.text(for: value))
                    .font(
                        .system(
                            size: isPrimary ? 22 : 15,
                            weight: isPrimary ? .semibold : .medium,
                            design: .monospaced)
                    )
                    .foregroundStyle(
                        Self.text(for: value) == "—"
                            ? Yun.Palette.textMuted : Yun.Palette.textPrimary
                    )
                    // A number that changes width as it crosses −10 makes the
                    // whole row jitter twenty times a second.
                    .monospacedDigit()
                Text(unit)
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textMuted)
            }
            // The enclosing YunWrap decides where a metric goes. If this row
            // compresses first, the minus sign and decimal can still be split
            // before the layout gets a chance to move the whole figure.
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// The fundamental and its note name, kept together as one readout token.
struct LoudnessPitchFigure: View {
    let hertz: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(loc("Pitch"))
                .font(Yun.Text.caption)
                .foregroundStyle(Yun.Palette.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(hertz > 0 ? String(format: "%.0f", hertz) : "—")
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(
                        hertz > 0 ? Yun.Palette.textPrimary : Yun.Palette.textMuted
                    )
                    .monospacedDigit()
                Text(loc("Hz"))
                    .font(Yun.Text.caption)
                    .foregroundStyle(Yun.Palette.textMuted)
                if let note = PitchTracker.noteName(hertz) {
                    YunBadge(note)
                }
            }
            // A metric is one token. Let the collection move it to another row
            // rather than breaking 147 Hz D3 into three unrelated fragments.
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// Loudness to the broadcast standard, and how far it is from the platform the
/// user is aiming at.
struct LoudnessReadout: View {
    let model: RouterModel

    var body: some View {
        let _ = BodyCount.tick("LoudnessReadout")
        VStack(alignment: .leading, spacing: Yun.Space.md) {
            LiveOutgoingReadout(model: model)
            YunDivider()
            LiveLoudnessFigures(model: model)
            YunDivider()
            LoudnessTargetControls(model: model)
            LiveLoudnessVerdict(model: model)
            SoundIdentificationControls(model: model)
            YunDivider()
            AutoLevelControls(model: model)
        }
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
        AutoLevelControls.state(
            offset: offset, isWaiting: isWaiting, isAtLimit: isAtLimit,
            isHeldByHeadroom: isHeldByHeadroom)
    }
}

/// The changing analyser figures and no other part of their card.
///
/// `Reading.duration` advances even in silence, so reading any member of
/// `analysis` invalidates this view at the twenty-hertz poll. Keeping that
/// dependency here stops four moving numbers from laying out every switch,
/// sentence and menu in `LoudnessReadout` on the same cadence.
struct LiveLoudnessFigures: View {
    let model: RouterModel

    var body: some View {
        let _ = BodyCount.tick("LiveLoudnessFigures")
        LoudnessFigures(
            shortTerm: model.analysis.shortTerm,
            // Held back until the gate has enough material to mean anything.
            integrated: model.loudnessOffset == nil ? -.infinity : model.analysis.integrated,
            peak: model.analysis.peak,
            pitchHertz: model.analysis.pitchHertz)
    }
}

/// The target control is intentionally isolated from the live reading.
struct LoudnessTargetControls: View {
    @Bindable var model: RouterModel

    var body: some View {
        let _ = BodyCount.tick("LoudnessTargetControls")
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
    }
}

/// The level actually leaving, and a sentence about it.
///
/// Output telemetry changes at the poll rate. It must update the number and
/// advice without making the rest of the loudness card participate.
struct LiveOutgoingReadout: View {
    let model: RouterModel

    var body: some View {
        let _ = BodyCount.tick("LiveOutgoingReadout")
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
        case .quiet:
            model.hardwareGain?.isSettable == true
                ? loc(
                    "Quiet. Adjust the microphone's own gain so loud speech peaks around -12 to -6 dBFS, then use the input level only for a small correction."
                )
                : loc(
                    "Quiet. Adjust the microphone or its physical gain so loud speech peaks around -12 to -6 dBFS, then use the input level only for a small correction."
                )
        case .veryQuiet:
            model.hardwareGain?.isSettable == true
                ? loc(
                    "Far too quiet to send. Check the selected input, then set the microphone's own gain for peaks around -12 to -6 dBFS."
                )
                : loc(
                    "Far too quiet to send. Check the selected input, then set the microphone or its physical gain for peaks around -12 to -6 dBFS."
                )
        case .silent: loc("Nothing is reaching the output.")
        }
    }
}

/// The integrated loudness judgement, isolated from the controls beside it.
struct LiveLoudnessVerdict: View {
    let model: RouterModel

    @ViewBuilder
    var body: some View {
        let _ = BodyCount.tick("LiveLoudnessVerdict")
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

    private func verdictColour(_ magnitude: Double) -> Color {
        if magnitude <= 1 { return Yun.Palette.success }
        if magnitude <= 3 { return Yun.Palette.warning }
        return Yun.Palette.danger
    }

    private func verdictText(_ offset: Double) -> String {
        if abs(offset) <= 1 {
            return String(format: loc("On target for %@."), model.loudnessTarget.title)
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
}

/// Configuration for the classifier, whose live verdict has its own leaf.
struct SoundIdentificationControls: View {
    @Bindable var model: RouterModel

    var body: some View {
        let _ = BodyCount.tick("SoundIdentificationControls")
        let use = SoundModelUse.of(
            identifying: model.isSoundIdentificationEnabled,
            levelling: model.isAutoLevelling,
            ducking: model.isDucking)
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            HStack(spacing: Yun.Space.sm) {
                YunSwitch(isOn: $model.isSoundIdentificationEnabled)
                VStack(alignment: .leading, spacing: 1) {
                    Text(loc("Identify sounds"))
                        .font(Yun.Text.label)
                        .foregroundStyle(Yun.Palette.textPrimary)
                    Text(use.caption)
                        .font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if !YunUIBenchmarkConfiguration.process.isEnabled, use.showsReadout {
                LiveHeardBadge(model: model)
            }
        }
    }
}

/// The classifier result is live; the switch and its explanation are not.
struct LiveHeardBadge: View {
    let model: RouterModel

    var body: some View {
        let _ = BodyCount.tick("LiveHeardBadge")
        HStack(spacing: 5) {
            Image(systemName: symbol(for: model.heardVerdict))
                .font(.system(size: 10))
            Text(title(for: model.heardVerdict))
                .font(Yun.Text.caption)
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
        .help(model.analysis.verdictLabel)
    }

    private func symbol(for verdict: SoundClassifier.Verdict) -> String {
        switch verdict {
        case .speech: "waveform"
        case .singing: "music.microphone"
        case .typing: "keyboard"
        case .music: "music.note"
        case .noise: "wind"
        case .quiet: "moon.zzz"
        }
    }

    private func title(for verdict: SoundClassifier.Verdict) -> String {
        switch verdict {
        case .speech: loc("Speech")
        case .singing: loc("Singing")
        case .typing: loc("Typing")
        case .music: loc("Music")
        case .noise: loc("Room noise")
        case .quiet: loc("Quiet")
        }
    }

    private func tint(for verdict: SoundClassifier.Verdict) -> Color {
        switch verdict {
        case .speech: Yun.Palette.success
        case .singing: Yun.Palette.accent
        case .typing: Yun.Palette.warning
        case .music: Yun.Palette.info
        case .noise: Yun.Palette.textTertiary
        case .quiet: Yun.Palette.textMuted
        }
    }
}

/// The automatic level switch, with its moving state isolated beneath it.
struct AutoLevelControls: View {
    @Bindable var model: RouterModel

    var body: some View {
        let _ = BodyCount.tick("AutoLevelControls")
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

        if model.isAutoLevelling {
            LiveAutoLevelState(model: model)
        }
    }

    static func state(
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
}

struct LiveAutoLevelState: View {
    let model: RouterModel

    var body: some View {
        let _ = BodyCount.tick("LiveAutoLevelState")
        HStack(alignment: .firstTextBaseline, spacing: Yun.Space.sm) {
            Spacer(minLength: 0)
            Text(
                AutoLevelControls.state(
                    offset: model.autoLevelOffset, isWaiting: model.autoLevelIsWaiting,
                    isAtLimit: model.autoLevelIsAtLimit,
                    isHeldByHeadroom: model.autoLevelIsHeldByHeadroom)
            )
            .font(Yun.Text.mono)
            .foregroundStyle(
                model.autoLevelIsAtLimit || model.autoLevelIsHeldByHeadroom
                    ? Yun.Palette.warning : Yun.Palette.textTertiary
            )
            .monospacedDigit()
        }
    }
}
