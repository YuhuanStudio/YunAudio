import Foundation
import Testing

@testable import YunAudioEngine

@Suite("Karaoke melody capacity")
struct KaraokeMelodyCapacityTests {
    private func note(start: Double = 0, end: Double, midi: Int = 60) -> MidiMelody.Note {
        MidiMelody.Note(start: start, end: end, midi: midi, track: 0)
    }

    @Test("a finite ordinary note produces the exact half-open sample grid")
    func exactGrid() {
        let samples = MidiMelody(notes: [note(end: 1)]).samples(every: 0.25)
        #expect(samples.map(\.time) == [0, 0.25, 0.5, 0.75])
        #expect(samples.map(\.midi) == [60, 60, 60, 60])
    }

    @Test("invalid intervals cannot reach a floating-point to integer conversion")
    func invalidIntervals() {
        let melody = MidiMelody(notes: [note(end: 1)])
        for interval in [0, -1, Double.nan, Double.infinity, -Double.infinity] {
            #expect(melody.samples(every: interval).isEmpty)
        }
    }

    @Test("a dense but finite request is refused before reserving its array")
    func boundedReference() {
        let duration = MidiMelody.maximumDurationSeconds
        let interval = duration / Double(MidiMelody.maximumReferenceSamples + 1)
        let melody = MidiMelody(notes: [note(end: duration)])
        #expect(melody.samples(every: interval).isEmpty)
    }

    @Test("non-finite and multi-hour notes never enter the melody")
    func boundedTimeline() {
        let melody = MidiMelody(notes: [
            note(end: .greatestFiniteMagnitude),
            note(end: .infinity),
            note(start: .nan, end: 1),
            note(end: MidiMelody.maximumDurationSeconds + 1),
            note(end: 1, midi: 128),
        ])
        #expect(melody.notes.isEmpty)
        #expect(melody.samples(every: 0.001).isEmpty)
    }

    @Test("an oversized MIDI file is rejected before it is copied")
    func boundedFile() {
        let data = Data(repeating: 0, count: MidiMelody.maximumFileBytes + 1)
        #expect(MidiMelody.parse(data) == nil)
    }
}
