import Foundation
import Testing

@testable import YunAudioApp

/// Choosing where a song's words come from, when the ranking is wrong.
@Suite("Lyric source choice")
struct LyricSourceChoiceTests {
    private func store() -> UserDefaults {
        UserDefaults(suiteName: "yunaudio.tests.\(UUID().uuidString)")!
    }

    @Test("a song with no choice made has none")
    func absentIsNil() {
        #expect(LyricSourceChoice.preferred(for: "慢冷", in: store()) == nil)
        #expect(LyricSourceChoice.preferred(for: "", in: store()) == nil)
    }

    @Test("a choice comes back, and belongs to its own song")
    func choicesAreRemembered() {
        let defaults = store()
        LyricSourceChoice.remember(.qqMusic, for: "慢冷", in: defaults)
        #expect(LyricSourceChoice.preferred(for: "慢冷", in: defaults) == .qqMusic)
        #expect(LyricSourceChoice.preferred(for: "來不及愛妳", in: defaults) == nil)

        LyricSourceChoice.forget("慢冷", in: defaults)
        #expect(LyricSourceChoice.preferred(for: "慢冷", in: defaults) == nil)
    }

    @Test("cycling goes round and comes back")
    func cyclingWraps() {
        let all: [OnlineLyrics.Source] = [.netEase, .qqMusic, .lrclib]
        let first = LyricSourceChoice.next(after: nil, among: all)
        var seen: [OnlineLyrics.Source] = []
        var current = first
        for _ in 0..<3 {
            seen.append(current!)
            current = LyricSourceChoice.next(after: current, among: all)
        }
        // Every source once, then back to where it started.
        #expect(Set(seen).count == 3)
        #expect(current == first)
    }

    @Test("the order is the same every time")
    func orderIsStable() {
        let all: [OnlineLyrics.Source] = [.qqMusic, .netEase, .lrclib]
        let shuffled: [OnlineLyrics.Source] = [.lrclib, .qqMusic, .netEase]
        // Pressing the button twice must not shuffle the deck underneath it.
        #expect(
            LyricSourceChoice.next(after: nil, among: all)
                == LyricSourceChoice.next(after: nil, among: shuffled))
    }

    @Test("nothing to choose from chooses nothing")
    func emptyIsNil() {
        #expect(LyricSourceChoice.next(after: nil, among: []) == nil)
        #expect(LyricSourceChoice.next(after: .netEase, among: []) == nil)
        // A current source that is not among the answers restarts the cycle
        // rather than falling off the end of it.
        #expect(LyricSourceChoice.next(after: .musixmatch, among: [.netEase]) == .netEase)
    }
}
