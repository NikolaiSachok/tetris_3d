import Darwin

/// Which intensity tier a music event belongs to.
enum MusicLayer: UInt8, Sendable {
    case base
    /// Joins from `MusicSong.energyLevels.0` upward.
    case energy1
    /// Joins from `MusicSong.energyLevels.1` upward.
    case energy2
    /// Scaled by the danger amount (stack close to the top).
    case danger
}

/// One note on the 16th-note grid.
struct MusicEvent: Sendable, Equatable {
    var step: Int
    var length: Int
    var note: Int
    var instrument: Int
    var velocity: Float
    var layer: MusicLayer
}

/// A looping arrangement: events on a 16th-note grid plus the instruments that play them.
struct MusicSong: Sendable {
    var bpm: Float
    var lengthSteps: Int
    /// Sorted by step.
    var events: [MusicEvent]
    var instruments: [SynthPatch]
    /// Instrument whose notes duck `pumped` instruments (the kick), and by how much.
    var pumpInstrument: Int?
    var pumpDepth: Float = 0.5
    /// Intensity levels at which the energy layers join.
    var energyLevels = (3, 6)
    /// Tempo gain per intensity level above 1, and its cap.
    var tempoPerLevel: Float = 0
    var maxTempoScale: Float = 1

    func tempo(level: Int) -> Float {
        bpm * fminf(1 + tempoPerLevel * Float(max(level - 1, 0)), maxTempoScale)
    }
}

/// Note names like "A4", "G#3", "Bb2" → MIDI numbers (A4 = 69, C4 = 60).
enum MusicNote {
    static func midi(_ name: some StringProtocol) -> Int? {
        var rest = Substring(name)
        guard let letter = rest.popFirst() else { return nil }
        let base: Int
        switch letter {
        case "C": base = 0
        case "D": base = 2
        case "E": base = 4
        case "F": base = 5
        case "G": base = 7
        case "A": base = 9
        case "B": base = 11
        default: return nil
        }
        var accidental = 0
        while let c = rest.first, c == "#" || c == "b" {
            accidental += c == "#" ? 1 : -1
            rest.removeFirst()
        }
        guard let octave = Int(rest) else { return nil }
        return (octave + 1) * 12 + base + accidental
    }
}

/// Builds a song's event list with a tiny text notation: `"E5/4 B4/2 -/2"` = E5 for four 16ths,
/// B4 for two, then a two-step rest.
struct MusicComposer {
    private(set) var events: [MusicEvent] = []

    /// Adds a phrase starting at `step`; returns the step after its last note or rest.
    @discardableResult
    mutating func phrase(
        _ score: String, at step: Int, instrument: Int, velocity: Float = 1, layer: MusicLayer = .base, transpose: Int = 0
    ) -> Int {
        var position = step
        for token in score.split(whereSeparator: { $0 == " " || $0 == "|" || $0 == "\n" }) {
            let parts = token.split(separator: "/")
            precondition(parts.count == 2, "Bad token \(token)")
            guard let length = Int(parts[1]) else { preconditionFailure("Bad length in \(token)") }
            if parts[0] != "-" {
                guard let midi = MusicNote.midi(parts[0]) else { preconditionFailure("Bad note in \(token)") }
                add(step: position, length: length, note: midi + transpose, instrument: instrument, velocity: velocity, layer: layer)
            }
            position += length
        }
        return position
    }

    mutating func add(step: Int, length: Int, note: Int, instrument: Int, velocity: Float = 1, layer: MusicLayer = .base) {
        events.append(MusicEvent(step: step, length: length, note: note, instrument: instrument, velocity: velocity, layer: layer))
    }

    /// Adds a hit on every step of a 16-step bar where `pattern` has a non-space character.
    /// `x` = full velocity, `o` = accent-less (60%), `.` = ghost (30%).
    mutating func drums(_ pattern: String, bar: Int, instrument: Int, note: Int = 60, layer: MusicLayer = .base) {
        for (i, c) in pattern.enumerated() where c != " " && c != "-" {
            let velocity: Float = c == "x" ? 1 : c == "o" ? 0.6 : 0.3
            add(step: bar * 16 + i, length: 1, note: note, instrument: instrument, velocity: velocity, layer: layer)
        }
    }

    var sortedEvents: [MusicEvent] {
        events.enumerated().sorted { ($0.element.step, $0.offset) < ($1.element.step, $1.offset) }.map(\.element)
    }
}

/// A chord as MIDI notes (voiced for a pad) plus a bass root.
struct MusicChord: Sendable {
    var bass: Int
    var tones: [Int]

    init(_ bass: String, _ tones: String) {
        self.bass = MusicNote.midi(bass)!
        self.tones = tones.split(separator: " ").map { MusicNote.midi($0)! }
    }
}

/// Render-thread sequencer for one song: steps through events, owns the song's voices and its
/// fade gain, and mixes into the music bus.
struct MusicPlayer {
    private let events: UnsafeMutableBufferPointer<MusicEvent>
    private let instruments: UnsafeMutableBufferPointer<SynthPatch>
    private let lengthSteps: Int
    private let pumpInstrument: Int
    private let pumpDepth: Float
    private let energyLevels: (Int, Int)
    private let song: MusicSong

    private var pool = VoicePool(capacity: 40, maxHeld: 28)
    private let bus = AudioBus()
    private let pumpBuffer: UnsafeMutablePointer<Float>
    private var pump: Float = 1
    private let pumpRecovery: Float

    private(set) var isSequencing = false
    private var step = 0
    private var eventIndex = 0
    /// Samples left until the next 16th step fires.
    private(set) var samplesUntilStep: Double = 0
    private var bpm: Float
    private var level = 1
    private var danger: Float = 0
    private var fade: Float = 0
    private var fadeTarget: Float = 0
    private var fadeStep: Float = 0
    private let sampleRate: Float

    init(song: MusicSong, sampleRate: Float) {
        self.song = song
        self.sampleRate = sampleRate
        events = .allocate(capacity: song.events.count)
        _ = events.initialize(from: song.events)
        instruments = .allocate(capacity: song.instruments.count)
        _ = instruments.initialize(from: song.instruments)
        lengthSteps = song.lengthSteps
        pumpInstrument = song.pumpInstrument ?? -1
        pumpDepth = song.pumpDepth
        energyLevels = song.energyLevels
        bpm = song.bpm
        pumpBuffer = .allocate(capacity: AudioBus.blockSize)
        pumpBuffer.initialize(repeating: 1, count: AudioBus.blockSize)
        pumpRecovery = DSP.decayCoefficient(0.07, sampleRate: sampleRate)
    }

    func deallocate() {
        events.deallocate()
        instruments.deallocate()
        pool.deallocate()
        bus.deallocate()
        pumpBuffer.deallocate()
    }

    private var isAudible: Bool { fade > 0 || fadeTarget > 0 }

    /// Starts from the top (or keeps going if it was only fading out) and fades in.
    mutating func play(fadeTime: Float) {
        if !isSequencing {
            step = 0
            eventIndex = 0
            samplesUntilStep = 0
            bpm = song.tempo(level: level)
            isSequencing = true
        }
        setFade(1, time: fadeTime)
    }

    mutating func stop(fadeTime: Float) {
        guard isSequencing else { return }
        setFade(0, time: fadeTime)
    }

    mutating func setLevel(_ level: Int) { self.level = max(level, 1) }
    mutating func setDanger(_ danger: Float) { self.danger = fminf(fmaxf(danger, 0), 1) }

    private mutating func setFade(_ target: Float, time: Float) {
        fadeTarget = target
        fadeStep = time > 0 ? 1 / (time * sampleRate) : 1
    }

    private var stepSamples: Double { Double(sampleRate) * 60 / Double(bpm) / 4 }

    /// Fires every step that is due. Called at block boundaries, which are cut to land on steps.
    mutating func advanceIfDue() {
        guard isSequencing else { return }
        while samplesUntilStep <= 0 {
            fireStep()
            samplesUntilStep += stepSamples
        }
    }

    mutating func consume(_ samples: Int) {
        if isSequencing { samplesUntilStep -= Double(samples) }
    }

    private mutating func fireStep() {
        let targetBpm = song.tempo(level: level)
        bpm += (targetBpm - bpm) * 0.15
        let seconds = Float(stepSamples) / sampleRate

        while eventIndex < events.count, events[eventIndex].step == step {
            let event = events[eventIndex]
            eventIndex += 1
            var velocity = event.velocity
            switch event.layer {
            case .base: break
            case .energy1: if level < energyLevels.0 { continue }
            case .energy2: if level < energyLevels.1 { continue }
            case .danger:
                velocity *= danger
                if velocity < 0.02 { continue }
            }
            if event.instrument == pumpInstrument { pump = 1 - pumpDepth }
            pool.start(
                SynthNote(
                    patch: instruments[event.instrument],
                    frequency: DSP.midiToHz(Float(event.note)),
                    duration: Float(event.length) * seconds * 0.92,
                    velocity: velocity
                ),
                sampleRate: sampleRate
            )
        }
        step += 1
        if step >= lengthSteps {
            step = 0
            eventIndex = 0
        }
    }

    /// Renders `count` samples of this song and adds them (scaled by the fade) into `music`.
    mutating func render(count: Int, into music: AudioBus) {
        guard isAudible || pool.activeCount > 0 else { return }
        bus.clear(count)
        for i in 0..<count {
            pumpBuffer[i] = pump
            pump = 1 + (pump - 1) * pumpRecovery
        }
        pool.render(count: count, sampleRate: sampleRate, into: bus, pump: pumpBuffer)
        for i in 0..<count {
            if fade != fadeTarget {
                fade = fade < fadeTarget ? fminf(fade + fadeStep, fadeTarget) : fmaxf(fade - fadeStep, fadeTarget)
            }
            // Equal-power-ish curve keeps crossfades from dipping in the middle.
            let g = fade * (2 - fade)
            music.left[i] += bus.left[i] * g
            music.right[i] += bus.right[i] * g
            music.reverb[i] += bus.reverb[i] * g
            music.delay[i] += bus.delay[i] * g
        }
        if fade == 0, fadeTarget == 0, isSequencing {
            isSequencing = false
            pool.reset()
        }
    }
}
