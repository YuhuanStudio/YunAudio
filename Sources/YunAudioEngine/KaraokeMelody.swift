import Foundation

/// A moment and the note at it, in MIDI numbers.
///
/// The unit is a MIDI note number rather than hertz, and it is fractional
/// rather than whole. Hertz is the wrong unit for comparing a singer to a tune:
/// the distance between two notes is a fixed number of semitones either way and
/// a ratio in hertz, so every threshold expressed in hertz would have to be a
/// percentage and every average would be wrong. Fractional because a voice sits
/// between notes — rounding to the nearest semitone before scoring would throw
/// away exactly the error being measured.
public struct PitchSample: Sendable, Hashable {
    /// Seconds on whatever clock the caller is scoring against.
    public let time: Double
    /// MIDI note number. 69 is A4 = 440 Hz.
    public let midi: Double

    public init(time: Double, midi: Double) {
        self.time = time
        self.midi = midi
    }

    /// Equal temperament from A4 = 440, the same anchor the pitch tracker's
    /// note names use.
    public static func midi(fromHertz hertz: Double) -> Double {
        69 + 12 * log2(hertz / 440)
    }
}

/// The tune a singer is supposed to be singing, read from a Standard MIDI File.
///
/// ## Why a file beside the `.lrc`, and not the original vocal
///
/// Scoring needs a melody and an `.lrc` has none — it carries words and times
/// and nothing about pitch. There were two ways to get one, and this is the
/// place to say why the other was not taken.
///
/// **What was chosen: a `.mid` beside the `.lrc`.** A MIDI melody is exact. It
/// says which note, from when to when, with no estimator between the file and
/// the answer, so a score computed from it is a statement about the singer
/// rather than about how well two pitch trackers happened to agree. It is
/// testable offline, byte for byte, with no audio device and no subscription.
/// It is the same argument as the `.lrc` itself, the device profiles and the
/// AutoEq curves: a file describes something, it does not execute, and the one
/// for your exact recording beats a database of approximations. And people
/// already have these — the karaoke MIDI is older than the `.lrc`.
///
/// **What was rejected: measuring the original singer through voice
/// isolation.** Three reasons, in order of how fatal they are.
///
/// 1. *The vocal is usually not there.* Somebody singing karaoke is singing
///    over a backing track, and a backing track is the recording with the vocal
///    taken out. Isolating a voice from an instrumental gets you nothing, and
///    that is the ordinary case rather than an edge one.
/// 2. *The stage in this application is the wrong stage.* Voice isolation here
///    is a speech enhancer on the microphone path, running on the singer's own
///    input. It is not a source separator and it never sees the player's
///    output. Pulling a sung melody out of a finished mix is Demucs-class
///    source separation — hundreds of milliseconds a chunk and a trained model
///    to ship, which is the category this project has already written down as
///    not belonging anywhere near the realtime path.
/// 3. *A measurement of the original arrives too late to be a target.* A score
///    wants to know what note is coming; a tracker following the playback can
///    only say what note has just gone. Even done perfectly it would be a
///    comparison of two estimates, and the honest name for that is not a score.
///
/// So: a melody file. Where there is none, the panel says so rather than
/// inventing a number.
public struct MidiMelody: Sendable, Hashable {
    /// Semantic limits for an inert reference file.
    ///
    /// A four-byte MIDI delta can describe centuries. File byte bounds alone
    /// therefore do not bound the timeline or the evenly sampled reference it
    /// can ask this process to materialise.
    /// Largest inert MIDI reference accepted by any application entry point.
    ///
    /// Public so a file owner can reject the byte after the parser's own limit
    /// before materialising an otherwise unbounded sidecar.
    public static let maximumFileBytes = 8 * 1024 * 1024
    static let maximumTrackCount = 256
    static let maximumEventCount = 500_000
    static let maximumNoteCount = 100_000
    static let maximumDurationSeconds = 6.0 * 60 * 60
    static let maximumReferenceSamples = 1_000_000

    /// One sounding note.
    public struct Note: Sendable, Hashable {
        /// Seconds from the start of the file.
        public let start: Double
        public let end: Double
        /// MIDI note number, 0...127.
        public let midi: Int
        /// Which chunk it came from, so a named vocal track can be preferred.
        public let track: Int

        public init(start: Double, end: Double, midi: Int, track: Int) {
            self.start = start
            self.end = end
            self.midi = midi
            self.track = track
        }

        public var duration: Double { end - start }
    }

    /// Every note in the file, percussion excluded, in time order.
    public let notes: [Note]
    /// The `FF 03` track names, one per chunk, empty where a chunk had none.
    public let trackNames: [String]
    /// The one line somebody is meant to sing: monophonic, in time order.
    public let melody: [Note]

    public init(notes: [Note], trackNames: [String] = []) {
        let admitted = notes.lazy.filter(Self.admits).prefix(Self.maximumNoteCount)
        let ordered = Array(admitted).sorted { $0.start < $1.start }
        self.notes = ordered
        let boundedNames = Array(trackNames.prefix(Self.maximumTrackCount))
        self.trackNames = boundedNames
        self.melody = Self.reduceToOneLine(ordered, trackNames: boundedNames)
    }

    private static func admits(_ note: Note) -> Bool {
        note.start.isFinite && note.end.isFinite
            && note.start >= 0 && note.end > note.start
            && note.end <= maximumDurationSeconds
            && (0...127).contains(note.midi) && note.track >= 0
    }

    /// Where the tune ends, which is the span a score is measured over.
    public var duration: Double { melody.last?.end ?? 0 }

    // MARK: Picking the line to sing

    /// Words that name a sung line in files people actually have.
    ///
    /// Lower case and matched as substrings, because the convention is a
    /// convention rather than a standard: "Vocal", "MELODY", "Lead Vox" and
    /// "Sing" are all in circulation.
    static let vocalTrackWords = ["vocal", "vox", "voice", "melody", "lead", "sing"]

    /// Reduces a whole arrangement to one singable line.
    ///
    /// Two rules, and the first wins where it applies:
    ///
    /// 1. **A track that says it is the voice is the voice.** Karaoke MIDI files
    ///    name the melody track, and a name is a statement of intent from
    ///    whoever made the file. Nothing inferred beats that.
    /// 2. **Otherwise, the top note.** At every instant, take the highest note
    ///    sounding anywhere — the "skyline" reduction. It is crude and it is
    ///    also right far more often than anything else this cheap, because
    ///    western arrangement puts the tune on top and the accompaniment
    ///    underneath it by construction. Where it is wrong it is wrong in a way
    ///    a singer hears immediately, which beats being subtly wrong.
    ///
    /// - Parameters:
    ///   - notes: Every note in the file, in time order.
    ///   - trackNames: One name per chunk, empty where a chunk had none.
    /// - Returns: A monophonic line in time order, empty when there is nothing
    ///   to sing.
    static func reduceToOneLine(_ notes: [Note], trackNames: [String]) -> [Note] {
        let named = trackNames.indices.filter { index in
            let name = trackNames[index].lowercased()
            return vocalTrackWords.contains { name.contains($0) }
        }
        let candidates = named.isEmpty ? notes : notes.filter { named.contains($0.track) }
        guard !candidates.isEmpty else { return [] }

        // A sweep rather than a scan per instant: the obvious "for every
        // boundary, look at every note" is quadratic, and an arrangement is
        // several thousand notes.
        var edges: [(time: Double, isOn: Bool, midi: Int, track: Int)] = []
        edges.reserveCapacity(candidates.count * 2)
        for note in candidates where note.end > note.start {
            edges.append((note.start, true, note.midi, note.track))
            edges.append((note.end, false, note.midi, note.track))
        }
        // Ends before starts at the same instant, so a note that stops exactly
        // where the next begins does not read as a chord of two.
        edges.sort {
            $0.time == $1.time ? (!$0.isOn && $1.isOn) : $0.time < $1.time
        }

        // MIDI notes have a fixed 0...127 domain. A list plus `max()` made a
        // legal but heavily overlapping arrangement quadratic; fixed counts
        // keep every edge at a bounded 128 probes.
        var sounding = [Int](repeating: 0, count: 128)
        var line: [Note] = []
        var currentTop: Int?
        var currentStart: Double = 0
        var currentTrack = 0
        var index = 0
        while index < edges.count {
            let time = edges[index].time
            while index < edges.count, edges[index].time == time {
                let edge = edges[index]
                if edge.isOn {
                    sounding[edge.midi] += 1
                    currentTrack = edge.track
                } else if sounding[edge.midi] > 0 {
                    sounding[edge.midi] -= 1
                }
                index += 1
            }
            let top = sounding.lastIndex { $0 > 0 }
            guard top != currentTop else { continue }
            if let previous = currentTop, time > currentStart {
                line.append(
                    Note(start: currentStart, end: time, midi: previous, track: currentTrack))
            }
            currentTop = top
            currentStart = time
        }
        // Adjacent segments of the same note are one held note, not two.
        var merged: [Note] = []
        for note in line {
            if let last = merged.last, last.midi == note.midi,
                abs(last.end - note.start) < 1e-9
            {
                merged[merged.count - 1] = Note(
                    start: last.start, end: note.end, midi: last.midi, track: last.track)
            } else {
                merged.append(note)
            }
        }
        return merged
    }

    // MARK: Reading it as a reference

    /// The melody as an evenly spaced series, which is what the scorer compares
    /// against.
    ///
    /// Rests produce no samples rather than samples of silence: there is
    /// nothing to sing there, so there is nothing to be right or wrong about,
    /// and a rest that counted against the singer would make a song with a long
    /// introduction unscoreable.
    ///
    /// - Parameter interval: Seconds between samples.
    /// - Returns: One sample per interval that a note is sounding, in time
    ///   order.
    public func samples(every interval: Double) -> [PitchSample] {
        guard interval.isFinite, interval > 0, !melody.isEmpty else { return [] }
        var admitted: [(note: Note, first: Int, last: Int)] = []
        admitted.reserveCapacity(melody.count)
        var sampleCount = 0
        // Multiplied from an index rather than accumulated: adding a float to
        // itself ten thousand times drifts, and the drift is measured against a
        // pairing window of tens of milliseconds.
        for note in melody {
            let firstValue = (note.start / interval).rounded(.up)
            let endValue = (note.end / interval).rounded(.up)
            guard firstValue.isFinite, endValue.isFinite,
                let first = Int(exactly: firstValue),
                let end = Int(exactly: endValue), end > 0
            else { return [] }
            let last = end - 1
            guard first <= last else { continue }
            let (distance, distanceOverflowed) = last.subtractingReportingOverflow(first)
            let (count, countOverflowed) = distance.addingReportingOverflow(1)
            let (nextCount, totalOverflowed) = sampleCount.addingReportingOverflow(count)
            guard !distanceOverflowed, !countOverflowed, !totalOverflowed,
                nextCount <= Self.maximumReferenceSamples
            else { return [] }
            sampleCount = nextCount
            admitted.append((note, first, last))
        }

        var out: [PitchSample] = []
        out.reserveCapacity(sampleCount)
        for item in admitted {
            let note = item.note
            for step in item.first...item.last {
                out.append(
                    PitchSample(time: Double(step) * interval, midi: Double(note.midi)))
            }
        }
        return out
    }

    /// What note the tune is on at a moment, or nil during a rest.
    public func midi(at seconds: Double) -> Double? {
        guard !melody.isEmpty else { return nil }
        var low = 0
        var high = melody.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if melody[middle].start <= seconds { low = middle } else { high = middle - 1 }
        }
        let note = melody[low]
        guard seconds >= note.start, seconds < note.end else { return nil }
        return Double(note.midi)
    }

    // MARK: Reading the file

    /// Parses a Standard MIDI File.
    ///
    /// - Parameter data: The whole file.
    /// - Returns: Nil when the bytes are not an SMF or a chunk is truncated. A
    ///   file that parses but holds no notes comes back as an empty melody
    ///   rather than nil, because "this file has no tune in it" is a different
    ///   answer from "this is not a MIDI file" and the interface says different
    ///   things about them.
    public static func parse(_ data: Data) -> MidiMelody? {
        guard data.count <= maximumFileBytes else { return nil }
        var reader = Reader(bytes: [UInt8](data))
        guard reader.tag() == "MThd", let headerLength = reader.uint32(),
            headerLength >= 6, reader.uint16() != nil,
            let trackCount = reader.uint16(), trackCount <= maximumTrackCount,
            let division = reader.uint16()
        else { return nil }
        // Longer headers are legal and their extra bytes are not ours.
        if headerLength > 6, !reader.skip(headerLength - 6) { return nil }

        var tempos: [(tick: Int, microsecondsPerQuarter: Int)] = []
        var raw: [(startTick: Int, endTick: Int, midi: Int, track: Int)] = []
        var names: [String] = []
        var exceededLimit = false
        var eventCount = 0

        var track = 0
        while track < trackCount, !reader.isAtEnd {
            guard reader.tag() == "MTrk", let length = reader.uint32(),
                var chunk = reader.slice(length)
            else { return nil }
            readTrack(
                &chunk, track: track, tempos: &tempos, notes: &raw, names: &names,
                eventCount: &eventCount, exceededLimit: &exceededLimit)
            guard !exceededLimit else { return nil }
            if names.count == track { names.append("") }
            track += 1
        }

        let clock = Clock(division: division, tempos: tempos)
        var notes: [Note] = []
        notes.reserveCapacity(raw.count)
        for rawNote in raw {
            let note = Note(
                start: clock.seconds(at: rawNote.startTick),
                end: clock.seconds(at: rawNote.endTick),
                midi: rawNote.midi, track: rawNote.track)
            guard admits(note) else { return nil }
            notes.append(note)
        }
        return MidiMelody(notes: notes, trackNames: names)
    }

    /// One `MTrk` chunk, in ticks.
    ///
    /// - Parameters:
    ///   - chunk: A reader bounded to this chunk's bytes.
    ///   - track: Its index in the file.
    ///   - tempos: Tempo changes found here, appended to.
    ///   - notes: Notes found here, appended to.
    ///   - names: One name per chunk seen so far, appended to when this one
    ///     names itself.
    ///   - eventCount: Total decoded events across all chunks in the file.
    ///   - exceededLimit: Set when another event would exceed the semantic cap.
    private static func readTrack(
        _ chunk: inout Reader, track: Int,
        tempos: inout [(tick: Int, microsecondsPerQuarter: Int)],
        notes: inout [(startTick: Int, endTick: Int, midi: Int, track: Int)],
        names: inout [String],
        eventCount: inout Int,
        exceededLimit: inout Bool
    ) {
        var tick = 0
        var status: UInt8 = 0
        // Keyed by channel and note: the same note struck on two channels at
        // once is two notes, not one restarted.
        var open: [Int: [Int]] = [:]

        while !chunk.isAtEnd {
            eventCount += 1
            guard eventCount <= maximumEventCount else {
                exceededLimit = true
                return
            }
            guard let delta = chunk.variableLength() else { return }
            let (nextTick, tickOverflowed) = tick.addingReportingOverflow(delta)
            guard !tickOverflowed else {
                exceededLimit = true
                return
            }
            tick = nextTick
            guard var byte = chunk.byte() else { return }
            if byte < 0x80 {
                // Running status: the sender omitted a status byte that had not
                // changed, so this is already the first data byte.
                guard status != 0 else { return }
                chunk.rewind()
                byte = status
            } else if byte < 0xF0 {
                status = byte
            }

            switch byte {
            case 0xFF:
                guard let kind = chunk.byte(), let length = chunk.variableLength(),
                    let payload = chunk.bytes(length)
                else { return }
                if kind == 0x51, payload.count == 3 {
                    let tempo =
                        Int(payload[0]) << 16 | Int(payload[1]) << 8 | Int(payload[2])
                    guard tempo > 0 else {
                        exceededLimit = true
                        return
                    }
                    tempos.append((tick, tempo))
                } else if kind == 0x03, names.count == track {
                    names.append(
                        String(decoding: payload.prefix(256), as: UTF8.self)
                            .trimmingCharacters(in: .whitespaces))
                } else if kind == 0x2F {
                    return
                }
            case 0xF0, 0xF7:
                guard let length = chunk.variableLength(), chunk.skip(length) else { return }
            default:
                let kind = byte & 0xF0
                let channel = Int(byte & 0x0F)
                // Program change and channel pressure carry one data byte;
                // everything else in this range carries two.
                let dataBytes = (kind == 0xC0 || kind == 0xD0) ? 1 : 2
                guard let data = chunk.bytes(dataBytes) else { return }
                guard kind == 0x90 || kind == 0x80 else { break }
                // Channel 10 — index 9 — is percussion by the General MIDI
                // convention, and a drum kit has no melody however high its
                // note numbers read.
                guard channel != 9 else { break }
                let note = Int(data[0])
                let key = channel << 8 | note
                if kind == 0x90, data[1] > 0 {
                    open[key, default: []].append(tick)
                } else if var starts = open[key], let start = starts.popLast() {
                    open[key] = starts.isEmpty ? nil : starts
                    if tick > start {
                        guard notes.count < maximumNoteCount else {
                            exceededLimit = true
                            return
                        }
                        notes.append((start, tick, note, track))
                    }
                }
            }
        }
    }

    // MARK: Ticks to seconds

    /// Turns a tick into a moment, which is the only part of an SMF that is not
    /// simply reading bytes.
    ///
    /// Tempo is a *map*, not a number: a file may change it at any tick, and a
    /// ritardando is dozens of changes in a row. Converting with a single tempo
    /// puts the last verse of such a file seconds away from where it is sung.
    struct Clock {
        /// Seconds per tick in each stretch, with the moment that stretch began.
        private var stretches: [(tick: Int, start: Double, secondsPerTick: Double)]

        init(division: Int, tempos: [(tick: Int, microsecondsPerQuarter: Int)]) {
            if division & 0x8000 != 0 {
                // SMPTE division: the high byte is a negative frame rate as a
                // signed byte, the low byte is ticks within a frame. That is
                // absolute time, so tempo events do not apply to it at all. The
                // 29-frame code means 29.97 in a video context; a tenth of a
                // percent over one song is under a millisecond and is not worth
                // the branch.
                let framesPerSecond = Double(256 - (division >> 8))
                let ticksPerFrame = Double(division & 0xFF)
                let perTick =
                    framesPerSecond > 0 && ticksPerFrame > 0
                    ? 1 / (framesPerSecond * ticksPerFrame) : 0
                stretches = [(0, 0, perTick)]
                return
            }
            let ticksPerQuarter = Double(max(1, division))
            // 120 bpm until the file says otherwise, which is what the standard
            // says to assume.
            var changes = tempos.sorted { $0.tick < $1.tick }
            if changes.first?.tick != 0 { changes.insert((0, 500_000), at: 0) }

            stretches = []
            var elapsed = 0.0
            var previousTick = 0
            var previousRate =
                Double(changes[0].microsecondsPerQuarter) / 1e6 / ticksPerQuarter
            for change in changes {
                let rate = Double(change.microsecondsPerQuarter) / 1e6 / ticksPerQuarter
                elapsed += Double(change.tick - previousTick) * previousRate
                stretches.append((change.tick, elapsed, rate))
                previousTick = change.tick
                previousRate = rate
            }
        }

        func seconds(at tick: Int) -> Double {
            guard !stretches.isEmpty else { return 0 }
            var low = 0
            var high = stretches.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if stretches[middle].tick <= tick { low = middle } else { high = middle - 1 }
            }
            let stretch = stretches[low]
            return stretch.start + Double(tick - stretch.tick) * stretch.secondsPerTick
        }
    }

    /// A cursor over the bytes that refuses to read past its end.
    ///
    /// Every read returns an optional and every caller checks it. A MIDI file
    /// somebody downloaded is somebody else's output, and truncation is the
    /// ordinary failure — an index that trapped would take the application down
    /// because a download stopped early.
    struct Reader {
        let bytes: [UInt8]
        private(set) var index: Int
        private let end: Int

        init(bytes: [UInt8]) {
            self.bytes = bytes
            self.index = 0
            self.end = bytes.count
        }

        init(bytes: [UInt8], from start: Int, to finish: Int) {
            self.bytes = bytes
            self.index = start
            self.end = finish
        }

        var isAtEnd: Bool { index >= end }

        mutating func byte() -> UInt8? {
            guard index < end else { return nil }
            defer { index += 1 }
            return bytes[index]
        }

        /// Steps back one byte, for running status.
        mutating func rewind() { if index > 0 { index -= 1 } }

        mutating func bytes(_ count: Int) -> [UInt8]? {
            guard count >= 0, index <= end, count <= end - index else { return nil }
            defer { index += count }
            return Array(bytes[index..<(index + count)])
        }

        mutating func skip(_ count: Int) -> Bool {
            guard count >= 0, index <= end, count <= end - index else { return false }
            index += count
            return true
        }

        mutating func tag() -> String? {
            guard let four = bytes(4) else { return nil }
            return String(decoding: four, as: UTF8.self)
        }

        mutating func uint16() -> Int? {
            guard let pair = bytes(2) else { return nil }
            return Int(pair[0]) << 8 | Int(pair[1])
        }

        mutating func uint32() -> Int? {
            guard let quad = bytes(4) else { return nil }
            return Int(quad[0]) << 24 | Int(quad[1]) << 16 | Int(quad[2]) << 8 | Int(quad[3])
        }

        /// The format's variable-length quantity: seven bits a byte, high bit
        /// set on every byte but the last.
        mutating func variableLength() -> Int? {
            var value = 0
            // Four bytes is the format's maximum; more than that is a corrupt
            // file rather than a very long delta, and looping on it would hang.
            for _ in 0..<4 {
                guard let byte = byte() else { return nil }
                value = value << 7 | Int(byte & 0x7F)
                if byte & 0x80 == 0 { return value }
            }
            return nil
        }

        mutating func slice(_ count: Int) -> Reader? {
            guard count >= 0, index <= end, count <= end - index else { return nil }
            defer { index += count }
            return Reader(bytes: bytes, from: index, to: index + count)
        }
    }
}
