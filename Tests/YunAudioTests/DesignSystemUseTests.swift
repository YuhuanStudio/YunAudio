import Foundation
import Testing

@testable import YunAudioApp

/// The interface is built out of the design system, including the parts of it
/// that are dark.
///
/// The KTV stage is the one surface that does not adapt — a cover image with a
/// scrim over it in both appearances — so `Yun.Palette.textSecondary`, a grey
/// chosen against a card, is wrong there twice over. Each KTV view therefore
/// worked around it: a raw `.white.opacity(…)` here, SwiftUI's own `.switch`
/// there, a bare `TextField` in the third. Individually reasonable, and by the
/// time anybody counted there were seventeen distinct opacities doing the work
/// of five roles and three toggles that did not match the other nine.
///
/// That is how a design system dies — not by being rejected, but by having
/// nothing to say about a new surface, one view at a time. `Yun.Palette.OnStage`
/// and `YunSwitch(onDark:)` are what it now has to say, and this is what keeps
/// the answer in use.
@Suite("the interface uses the design system, including on the stage")
struct DesignSystemUseTests {

    private var root: String { PreferencesCompletenessTests.sourceRootForTests }

    private func sources(_ glob: String) throws -> [(String, String)] {
        let directory = root + "Sources/YunAudioApp"
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
        return try names.filter { $0.hasPrefix(glob) && $0.hasSuffix(".swift") }
            .sorted()
            .map { ($0, try String(contentsOfFile: directory + "/" + $0, encoding: .utf8)) }
    }

    @Test("no view builds its own switch out of the platform's")
    func switches() throws {
        // `YunToggleStyle` lays out its own label and `YunSwitch` does not, so
        // there is a design-system answer for both shapes of row. Nine views
        // used one of them and three used SwiftUI's — all three on the stage,
        // because the system's switch was invisible on a photograph until it
        // was given `onDark`.
        let directory = root + "Sources/YunAudioApp"
        for name in try FileManager.default.contentsOfDirectory(atPath: directory)
        where name.hasSuffix(".swift") {
            let text = try String(contentsOfFile: directory + "/" + name, encoding: .utf8)
            #expect(!text.contains("toggleStyle(.switch)"), "\(name)")
        }
    }

    @Test("the stage draws its chrome from named roles, not from improvised opacities")
    func stageChrome() throws {
        // Deliberately not "no raw white anywhere": the lyric ramp in
        // `KTVWindow` is a *function* of how far a line is from the one being
        // sung, and a function is not five names. What must not come back is a
        // literal opacity standing in for a role — a label, a well, a hairline.
        for (name, text) in try sources("KTV") {
            let literals = text.ranges(of: ".white.opacity(0.").count
            #expect(literals == 0, "\(name) has \(literals) improvised on-stage opacities")
        }
    }

    @Test("the on-stage ramp is one ordered scale rather than a bag of colours")
    func rampIsOrdered() throws {
        // A design token that is not ordered against its neighbours is a
        // constant with a nice name. These have to stay in this order for
        // "secondary" to mean anything relative to "tertiary".
        let tokens = try String(
            contentsOfFile: root + "Sources/YunDesign/Tokens.swift", encoding: .utf8)
        let ramp = try #require(tokens.range(of: "public enum OnStage {"))
        let end = try #require(
            tokens.range(of: "        }", range: ramp.upperBound..<tokens.endIndex))
        let body = String(tokens[ramp.upperBound..<end.lowerBound])
        for role in [
            "primary", "secondary", "tertiary", "faint", "well", "wellLit", "hairline",
        ] {
            #expect(body.contains("static let \(role)"), "\(role)")
        }
        // The text ramp descends and the surface ramp ascends, which is what
        // makes them two ramps rather than seven numbers.
        #expect(body.contains("secondary = Color.white.opacity(0.72)"))
        #expect(body.contains("tertiary = Color.white.opacity(0.55)"))
        #expect(body.contains("faint = Color.white.opacity(0.35)"))
        #expect(body.contains("well = Color.white.opacity(0.10)"))
        #expect(body.contains("wellLit = Color.white.opacity(0.18)"))
    }
}
