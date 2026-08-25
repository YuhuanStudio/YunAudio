import Foundation
import Testing

@testable import YunAudioApp
@testable import YunAudioEngine

/// What a person actually hears with their scene applied.
///
/// The integrity check proves the path is sample-accurate when nothing is
/// processing, and `SignalFidelity` measures one effect at a time. Neither
/// measures the thing somebody is really using: a shipped scene, which is
/// several effects at once and is what every complaint about quality is
/// actually about.
@Suite("What each shipped scene costs")
struct SceneFidelityTests {

    /// The four as they ship, so a change to one is a change to this table.
    private var scenes: [(name: String, effects: [EffectKind])] {
        // Stored as strings in the preset, because a scene file outlives the
        // enum it was written against.
        RoutePreset.builtIn.map { preset in
            (preset.name, (preset.effects ?? []).compactMap(EffectKind.init(rawValue:)))
        }
    }

    @Test("every shipped scene is measured on speech")
    func sceneTable() throws {
        let audio = try DeterministicSpeechFixture.load()
        print("\nscene            effects  delay    gain     residual      r")
        print(String(repeating: "-", count: 74))
        for scene in scenes {
            guard
                let measured = SignalFidelity.cost(
                    of: scene.effects, on: audio.samples, sampleRate: audio.rate)
            else {
                print("\(scene.name): would not build at \(Int(audio.rate)) Hz")
                continue
            }
            let residual =
                measured.residualDecibels.isFinite
                ? String(format: "%+8.2f dB", measured.residualDecibels) : "  exact   "
            print(
                String(
                    format: "%-16@ %6d  %5d  %+7.2f  %@  %.5f",
                    scene.name as NSString, scene.effects.count,
                    measured.delayFrames, measured.gainDecibels, residual as NSString,
                    measured.correlation))
        }
        print("")
        #expect(!scenes.isEmpty)
    }

    /// The compressor's makeup spends headroom, and the limiter is what owns
    /// it. This is the check that the trade was safe.
    ///
    /// Every shipped scene carries the limiter last, so nothing that leaves one
    /// may reach full scale on material that did not. A scene that clips is
    /// worse than a scene that is quiet, and adding four decibels without
    /// checking would have been exactly the change that trades one complaint
    /// for a louder one.
    @Test("no shipped scene clips, and none of them is quiet any more")
    func scenesAreLevelNeutralWithoutClipping() throws {
        let audio = try DeterministicSpeechFixture.load()
        for scene in scenes {
            guard
                let measured = SignalFidelity.cost(
                    of: scene.effects, on: audio.samples, sampleRate: audio.rate)
            else { continue }
            #expect(!measured.clipped, "\(scene.name) clipped: \(measured.summary)")
            // Within a decibel of what went in. Before the makeup these read
            // −4.76, −4.37 and −4.76, which is what "the volume is wrong" was.
            #expect(
                abs(measured.gainDecibels) < 1,
                "\(scene.name) changes level by \(measured.gainDecibels) dB")
        }
    }

    /// The claim the issue asks to be ruled out first: voice isolation is on in
    /// two of the four, and it treats music as noise.
    ///
    /// Measured rather than argued: the same scene with and without it, on
    /// speech and then on music-like material, so the cost is attributed to the
    /// effect rather than to the scene it sits in.
    @Test("what voice isolation adds to the scene it is in")
    func isolationInsideAScene() throws {
        let audio = try DeterministicSpeechFixture.load()
        for scene in scenes where scene.effects.contains(.voiceIsolation) {
            let without = scene.effects.filter { $0 != .voiceIsolation }
            guard
                let withIt = SignalFidelity.cost(
                    of: scene.effects, on: audio.samples, sampleRate: audio.rate),
                let withoutIt = SignalFidelity.cost(
                    of: without, on: audio.samples, sampleRate: audio.rate)
            else { continue }
            print(
                "\n\(scene.name) on speech"
                    + "\n  with isolation:    \(withIt.summary)"
                    + "\n  without isolation: \(withoutIt.summary)")

            // Music, which is what the shipped note warns it will treat as
            // noise. The same scene, the same chain, a different signal.
            let music = SignalFidelity.bandLimitedFixture(
                seconds: 2, sampleRate: audio.rate)
            if let musicWith = SignalFidelity.cost(
                of: scene.effects, on: music, sampleRate: audio.rate),
                let musicWithout = SignalFidelity.cost(
                    of: without, on: music, sampleRate: audio.rate)
            {
                print(
                    "\(scene.name) on music"
                        + "\n  with isolation:    \(musicWith.summary)"
                        + "\n  without isolation: \(musicWithout.summary)")
                // The claim the shipped warning rests on, asserted here so it
                // cannot quietly stop being true: isolation costs music far
                // more than it costs speech.
                #expect(
                    musicWith.correlation < withIt.correlation,
                    "\(scene.name): music \(musicWith.correlation), speech \(withIt.correlation)")
            }
        }
        print("")
    }

    /// The scene that exists to change nothing must change nothing.
    ///
    /// "Recording" ships with a limiter alone, and a limiter below its
    /// threshold is bit-transparent — so a recording made through this scene is
    /// the microphone and nothing else. That is the whole promise of the scene
    /// and it had never been checked.
    @Test("the recording scene is transparent")
    func recordingSceneIsTransparent() throws {
        let audio = try DeterministicSpeechFixture.load()
        let recording = try #require(
            scenes.first { $0.name == RoutePreset.recording.name })
        let measured = try #require(
            SignalFidelity.cost(
                of: recording.effects, on: audio.samples, sampleRate: audio.rate))
        #expect(measured.correlation > 0.999999, "\(measured.summary)")
        #expect(measured.residualDecibels < -100, "\(measured.summary)")
        #expect(abs(measured.gainDecibels) < 0.01, "\(measured.summary)")
    }
}
