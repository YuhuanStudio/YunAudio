import SwiftUI
import YunAudioEngine
import YunDesign

/// The live readings, as a row of pills.
///
/// It was one thin strip of monospaced fields divided by hairlines, and three
/// things were wrong with the shape rather than with the numbers in it. A field
/// carries no weight, so a clipped output and a sample rate read exactly alike.
/// It printed "YunAudio" in the corner to say the driver was installed, which
/// is the normal state of a working machine and therefore no news. And a strip
/// cannot wrap, so the menu bar panel — 340 points wide, and the surface most
/// of these readings are actually glanced at from — could never have one.
///
/// A pill carries its own tone, is self-contained enough to simply not be
/// there, and wraps. What is on screen is then exactly what there is to say.
/// It is also the shape the system's own status chips take, which is what makes
/// the row sit properly under glass.
struct StatusPills: View {
    let model: RouterModel
    /// The menu bar panel is 340 points wide. The row wraps to fit it and runs
    /// in a single line at the window's width; the same layout does both.
    var isCompact = false

    var body: some View {
        let _ = BodyCount.tick("StatusPills")
        YunWrap(spacing: Yun.Space.sm) {
            ForEach(Self.pills(for: model)) { pill in
                YunStatusPill(
                    pill.label, value: pill.value, tone: pill.tone, showsDot: pill.showsDot
                )
                // A pill is two words where the strip was a sentence. The
                // sentence has to go somewhere, and a tooltip is where it
                // belongs: the clock giving up is worth a paragraph and worth
                // none of the room a paragraph takes.
                .help(pill.help ?? pill.label)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, isCompact ? 0 : Yun.Space.xl)
        .padding(.bottom, isCompact ? 0 : Yun.Space.md)
    }
}

extension StatusPills {

    /// One pill's content, apart from its drawing.
    ///
    /// Which pills are present *is* the behaviour here — the whole design is
    /// that a pill with nothing to say does not appear — and a view cannot be
    /// asked what it is showing. Built as data so the flow check can assert on
    /// it rather than somebody having to look at a screenshot.
    struct Pill: Identifiable, Equatable {
        let id: String
        let label: String
        var value: String?
        var tone: YunStatusTone = .neutral
        var showsDot = false
        /// The sentence behind the two words, where there is one.
        var help: String?
    }

    static func pills(for model: RouterModel) -> [Pill] {
        var pills: [Pill] = [
            Pill(
                id: "state", label: stateWord(model),
                tone: model.isRunning ? .success : .neutral, showsDot: true)
        ]

        // Everything measured comes from a running path, so it all appears and
        // disappears together rather than leaving a row of zeroes behind.
        if let quality = model.pathQuality {
            pills.append(
                Pill(
                    id: "integrity", label: loc(quality.integrityKey),
                    tone: quality.isBitExact ? .success : .warning, showsDot: true))
            pills.append(
                Pill(id: "rate", label: loc("Rate"), value: Format.sampleRate(quality.sampleRate)))
            pills.append(
                Pill(id: "buffer", label: loc("Buffer"), value: "\(quality.bufferFrames) f"))
            pills.append(
                Pill(
                    id: "latency", label: loc("Latency"),
                    value: String(format: "%.1f ms", model.pathLatencyMilliseconds),
                    // A stage in the path is worth saying out loud: the number
                    // stops being about the buffer and starts being about the
                    // chain, and the two are an order of magnitude apart.
                    tone: model.addedLatencyMilliseconds >= 1 ? .warning : .neutral))
        }

        if model.isClockLocked {
            pills.append(
                Pill(
                    id: "clock", label: loc("Clock"),
                    value: String(
                        format: "%+.1f ppm", (model.measuredRateRatio - 1) * 1_000_000),
                    tone: .success))
        } else if model.clockLockFailed {
            pills.append(
                Pill(
                    id: "clock", label: loc("Drift corrected"), tone: .warning, showsDot: true,
                    help: loc(
                        "The clock lock dropped, so drift correction was switched back on. Audio is safe but no longer bit-exact."
                    )))
        }

        if model.isRecording {
            pills.append(
                Pill(
                    id: "recording", label: loc("REC"), value: recordingReading(model),
                    tone: model.isRecordingPaused ? .warning : .danger, showsDot: true))
        }

        // Truncation the far end can hear. Not folded into the level readout
        // above, because it is the one reading somebody has to act on.
        if model.isRunning, model.outputVerdict == .clipping {
            pills.append(
                Pill(
                    id: "clipping", label: loc("Clipping"), tone: .danger, showsDot: true,
                    help: String(
                        format: loc(
                            "Clipped %@ times. Lower the input level or the master — this is already distortion the far end can hear."
                        ), "\(model.outputClippedSamples)")))
        }

        if model.watchesIOAllocations, model.allocationViolations > 0 {
            pills.append(
                Pill(
                    id: "allocations",
                    label: String(
                        format: loc("%d IO allocations"),
                        Int(clamping: model.allocationViolations)),
                    tone: .warning, showsDot: true))
        }
        if let dropped = model.echoStatus?.dropped, dropped > 0 {
            pills.append(
                Pill(
                    id: "dropped",
                    label: String(format: loc("%llu dropped"), dropped),
                    tone: .danger, showsDot: true))
        }

        // The one pill anybody will ever be glad to see. It appears only in the
        // moment it is true — muted, and talking — and goes away by itself,
        // which is why it is worth the attention a red dot buys: a warning that
        // is on half the time is not a warning.
        if model.isSpeakingWhileMuted {
            pills.append(
                Pill(
                    id: "muted-talking",
                    label: loc("muted, but talking"),
                    tone: .danger, showsDot: true,
                    help: loc(
                        "The microphone is muted and the system's own voice detector "
                            + "can hear you. It has echo cancellation, so this is you "
                            + "rather than the speakers.")))
        }

        // A Bluetooth headset that has quietly become a telephone, and what
        // did it. The cause is never where the effect is — the music turns to
        // mush and the reason is in some other application entirely, which
        // macOS marks with an orange dot and never names.
        if let headset = model.headsetInCallQuality {
            let culprits = model.applicationsHoldingTheMicrophone
            let who =
                culprits.isEmpty
                ? loc("something has its microphone open")
                : culprits.map(\.name).joined(separator: ", ")
            pills.append(
                Pill(
                    id: "call-quality",
                    label: loc("headset in call quality"),
                    value: headset.shortName,
                    tone: .warning, showsDot: true,
                    help: String(
                        format: loc(
                            "%@ is on Bluetooth and has dropped to telephone quality "
                                + "because %@. Bluetooth carries good sound one way or "
                                + "poor sound both ways, and nothing on macOS can change "
                                + "that. Keep the headset for listening and take the "
                                + "microphone from another device."),
                        headset.name, who)))
        }

        // Only the absence is worth a pill. The bar used to print the driver's
        // name when it was installed, which is the normal state of a working
        // machine and therefore says nothing.
        if !model.isDriverInstalled {
            pills.append(
                Pill(id: "driver", label: loc("no driver"), tone: .warning, showsDot: true))
        }
        return pills
    }

    private static func stateWord(_ model: RouterModel) -> String {
        if model.isBusy { return loc("Working") }
        return loc(model.isRunning ? "Routing" : "Idle")
    }


    /// How long, and how loud. The duration on its own says a file is growing;
    /// it does not say whether anything is in it.
    private static func recordingReading(_ model: RouterModel) -> String {
        let whole = Int(model.recordingSeconds)
        let clock = String(format: "%02d:%02d", whole / 60, whole % 60)
        guard model.outputPeakDecibels.isFinite else { return "\(clock) · −∞" }
        return clock + String(format: " · %.0f dBFS", model.outputPeakDecibels)
    }
}
