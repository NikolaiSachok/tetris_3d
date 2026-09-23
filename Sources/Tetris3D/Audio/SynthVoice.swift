import Darwin

/// A subtractive synth preset: two oscillators + sub + noise → filter → amp envelope.
/// Used both for sound effects and for music instruments (drums included).
struct SynthPatch: Sendable {
    var wave1 = SynthWave.saw
    var wave2 = SynthWave.saw
    /// Level of oscillator 1 (0 for pure-noise sounds like hats).
    var osc1Mix: Float = 1
    /// Level of oscillator 2 (0 disables it).
    var osc2Mix: Float = 0
    /// Frequency of oscillator 2 relative to the note (2 = octave up, 2.76 = bell-like partial).
    var osc2Ratio: Float = 1
    /// Detune of oscillator 2 in cents.
    var osc2Detune: Float = 0
    /// Sine one octave below the note.
    var subMix: Float = 0
    var noiseMix: Float = 0
    /// Moves oscillator 1 left and oscillator 2 right (0 = mono).
    var stereoSpread: Float = 0

    var attack: Float = 0.002
    var decay: Float = 0.2
    var sustain: Float = 0
    var release: Float = 0.05

    /// Semitones added at note start, decaying to 0 (positive = falling zap, negative = rising).
    var pitchSweep: Float = 0
    var pitchSweepTime: Float = 0.05
    var vibratoDepth: Float = 0
    var vibratoRate: Float = 5.5

    var filter = DSP.SVFilter.Mode.off
    var cutoff: Float = 20000
    /// Octaves added to the cutoff at note start, decaying to 0.
    var filterSweep: Float = 0
    var filterSweepTime: Float = 0.1
    var resonance: Float = 0.3

    var gain: Float = 1
    var reverbSend: Float = 0
    var delaySend: Float = 0
    /// Ducked by the music track's kick (sidechain pumping).
    var pumped = false
}

/// A request to play one voice.
struct SynthNote: Sendable {
    var patch: SynthPatch
    var frequency: Float
    /// Seconds until release starts.
    var duration: Float
    var velocity: Float = 1
    /// -1 (left) ... 1 (right).
    var pan: Float = 0
    /// Seconds before the note starts (lets one effect be a little sequence).
    var delay: Float = 0
    /// Voices sharing a non-zero group are limited to `groupLimit` held voices (oldest are faded).
    var group: UInt8 = 0
    var groupLimit: UInt8 = 0
}

/// Four mono buffers a set of voices mixes into.
struct AudioBus {
    static let blockSize = 256

    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    let reverb: UnsafeMutablePointer<Float>
    let delay: UnsafeMutablePointer<Float>

    init() {
        func buffer() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: AudioBus.blockSize)
            p.initialize(repeating: 0, count: AudioBus.blockSize)
            return p
        }
        left = buffer()
        right = buffer()
        reverb = buffer()
        delay = buffer()
    }

    func clear(_ count: Int) {
        left.update(repeating: 0, count: count)
        right.update(repeating: 0, count: count)
        reverb.update(repeating: 0, count: count)
        delay.update(repeating: 0, count: count)
    }

    func deallocate() {
        left.deallocate()
        right.deallocate()
        reverb.deallocate()
        delay.deallocate()
    }
}

/// Render-thread state of one playing note.
struct SynthVoice {
    /// Control-rate interval: pitch and filter coefficients are recomputed every this many samples.
    private static let controlInterval = 16

    private(set) var patch: SynthPatch
    private(set) var group: UInt8
    let age: UInt64
    private(set) var envelope: DSP.Envelope

    private var phase1: Float = 0
    private var phase2: Float = 0
    private var phaseSub: Float = 0
    private var vibratoPhase: Float = 0
    private let baseInc: Float
    private let osc2Factor: Float
    private var pitchEnv: Float = 1
    private let pitchCoef: Float
    private var filterEnv: Float = 1
    private let filterCoef: Float
    private var filterL = DSP.SVFilter()
    private var filterR = DSP.SVFilter()
    private var noise: DSP.NoiseSource
    private var gateSamples: Int
    private var delaySamples: Int
    private let gainL: Float
    private let gainR: Float

    init(_ note: SynthNote, sampleRate: Float, age: UInt64) {
        patch = note.patch
        group = note.group
        self.age = age
        envelope = DSP.Envelope(
            attack: patch.attack, decay: patch.decay, sustain: patch.sustain, release: patch.release, sampleRate: sampleRate
        )
        baseInc = note.frequency / sampleRate
        osc2Factor = patch.osc2Ratio * exp2f(patch.osc2Detune / 1200)
        let block = Float(SynthVoice.controlInterval)
        pitchCoef = powf(DSP.decayCoefficient(patch.pitchSweepTime, sampleRate: sampleRate), block)
        filterCoef = powf(DSP.decayCoefficient(patch.filterSweepTime, sampleRate: sampleRate), block)
        noise = DSP.NoiseSource(seed: UInt32(truncatingIfNeeded: age &* 0x9E37_79B9 &+ 1))
        // Oscillators start at a zero crossing, except detuned stacks, whose random phase makes them wide.
        if patch.wave1 == .triangle { phase1 = 0.25 }
        if patch.wave2 == .triangle { phase2 = 0.25 }
        if patch.osc2Mix > 0, patch.stereoSpread > 0 {
            phase2 = noise.next() * 0.5 + 0.5
        }
        gateSamples = max(Int(note.duration * sampleRate), 1)
        delaySamples = Int(note.delay * sampleRate)
        // Constant-power pan.
        let angle = (fminf(fmaxf(note.pan, -1), 1) + 1) * Float.pi / 4
        let level = patch.gain * note.velocity
        gainL = cosf(angle) * level * Float(2).squareRoot()
        gainR = sinf(angle) * level * Float(2).squareRoot()
    }

    var isFinished: Bool { envelope.stage == .done }
    /// Held voices count toward polyphony limits; releasing ones are on their way out.
    var isHeld: Bool { !envelope.isReleasing }

    mutating func noteOff() { envelope.noteOff() }
    mutating func kill(sampleRate: Float) { envelope.kill(sampleRate: sampleRate) }

    /// Adds `count` samples into `bus`. `pump` scales pumped patches per sample.
    mutating func render(count: Int, sampleRate: Float, into bus: AudioBus, pump: UnsafePointer<Float>) {
        var i = 0
        if delaySamples > 0 {
            let skip = min(delaySamples, count)
            delaySamples -= skip
            i = skip
        }
        let stereo = patch.stereoSpread > 0 && patch.osc2Mix > 0
        let spread = patch.stereoSpread
        let reverbSend = patch.reverbSend
        let delaySend = patch.delaySend
        let pumped = patch.pumped
        let hasOsc1 = patch.osc1Mix > 0
        let hasOsc2 = patch.osc2Mix > 0
        let hasSub = patch.subMix > 0
        let hasNoise = patch.noiseMix > 0

        while i < count {
            // Control rate: pitch sweep, vibrato and filter sweep.
            var semis = patch.pitchSweep * pitchEnv
            pitchEnv *= pitchCoef
            if patch.vibratoDepth > 0 {
                semis += patch.vibratoDepth * sinf(vibratoPhase * DSP.twoPi)
                vibratoPhase += patch.vibratoRate * Float(SynthVoice.controlInterval) / sampleRate
                if vibratoPhase >= 1 { vibratoPhase -= 1 }
            }
            let inc1 = fminf(baseInc * exp2f(semis / 12), 0.45)
            let inc2 = fminf(inc1 * osc2Factor, 0.45)
            let incSub = inc1 * 0.5
            var coefficients = DSP.SVFilter.Coefficients()
            if patch.filter != .off {
                coefficients = DSP.SVFilter.Coefficients(
                    cutoff: patch.cutoff * exp2f(patch.filterSweep * filterEnv),
                    resonance: patch.resonance,
                    sampleRate: sampleRate
                )
                filterEnv *= filterCoef
            }

            let end = min(i + SynthVoice.controlInterval, count)
            while i < end {
                if gateSamples > 0 {
                    gateSamples -= 1
                    if gateSamples == 0 { envelope.noteOff() }
                }
                var amp = envelope.next()
                if pumped { amp *= pump[i] }

                var s1: Float = 0
                if hasOsc1 {
                    s1 = patch.wave1.sample(phase1, inc1) * patch.osc1Mix
                    phase1 += inc1
                    if phase1 >= 1 { phase1 -= 1 }
                }
                var s2: Float = 0
                if hasOsc2 {
                    s2 = patch.wave2.sample(phase2, inc2) * patch.osc2Mix
                    phase2 += inc2
                    if phase2 >= 1 { phase2 -= 1 }
                }
                var common: Float = 0
                if hasSub {
                    common += sinf(phaseSub * DSP.twoPi) * patch.subMix
                    phaseSub += incSub
                    if phaseSub >= 1 { phaseSub -= 1 }
                }
                if hasNoise { common += noise.next() * patch.noiseMix }

                var l: Float
                var r: Float
                if stereo {
                    l = filterL.process(s1 + s2 * (1 - spread) + common, coefficients, patch.filter)
                    r = filterR.process(s1 * (1 - spread) + s2 + common, coefficients, patch.filter)
                } else {
                    l = filterL.process(s1 + s2 + common, coefficients, patch.filter)
                    r = l
                }
                l *= amp * gainL
                r *= amp * gainR
                bus.left[i] += l
                bus.right[i] += r
                let mono = (l + r) * 0.5
                bus.reverb[i] += mono * reverbSend
                bus.delay[i] += mono * delaySend
                i += 1

                if envelope.stage == .done { return }
            }
        }
    }
}

/// Fixed-capacity voice allocator with a held-voice cap. Over the cap the oldest held voice is
/// faded out quickly (never cut), so a burst of sounds cannot click or pile up.
struct VoicePool {
    private let voices: UnsafeMutablePointer<SynthVoice?>
    let capacity: Int
    private let maxHeld: Int
    private var nextAge: UInt64 = 0

    init(capacity: Int, maxHeld: Int) {
        self.capacity = capacity
        self.maxHeld = maxHeld
        voices = .allocate(capacity: capacity)
        voices.initialize(repeating: nil, count: capacity)
    }

    func deallocate() {
        voices.deinitialize(count: capacity)
        voices.deallocate()
    }

    var activeCount: Int {
        var n = 0
        for i in 0..<capacity where voices[i] != nil { n += 1 }
        return n
    }

    mutating func start(_ note: SynthNote, sampleRate: Float) {
        if note.group != 0, note.groupLimit > 0 {
            enforceLimit(Int(note.groupLimit), group: note.group, sampleRate: sampleRate)
        }
        enforceLimit(maxHeld, group: nil, sampleRate: sampleRate)

        var slot = -1
        for i in 0..<capacity where voices[i] == nil {
            slot = i
            break
        }
        if slot < 0 {
            // Every slot is busy: take the quietest releasing voice, or drop the note.
            var quietest = Float.greatestFiniteMagnitude
            for i in 0..<capacity {
                guard let voice = voices[i], !voice.isHeld, voice.envelope.level < quietest else { continue }
                quietest = voice.envelope.level
                slot = i
            }
            guard slot >= 0, quietest < 0.05 else { return }
        }
        voices[slot] = SynthVoice(note, sampleRate: sampleRate, age: nextAge)
        nextAge &+= 1
    }

    /// Fades the oldest held voices (optionally of one group) until fewer than `limit` remain.
    private mutating func enforceLimit(_ limit: Int, group: UInt8?, sampleRate: Float) {
        while heldCount(group: group) >= limit, let oldest = oldestHeld(group: group) {
            voices[oldest]!.kill(sampleRate: sampleRate)
        }
    }

    func heldCount(group: UInt8?) -> Int {
        var count = 0
        for i in 0..<capacity {
            guard let voice = voices[i], voice.isHeld, group == nil || voice.group == group else { continue }
            count += 1
        }
        return count
    }

    private func oldestHeld(group: UInt8?) -> Int? {
        var oldest: Int?
        var oldestAge = UInt64.max
        for i in 0..<capacity {
            guard let voice = voices[i], voice.isHeld, group == nil || voice.group == group, voice.age < oldestAge else { continue }
            oldestAge = voice.age
            oldest = i
        }
        return oldest
    }

    mutating func releaseAll() {
        for i in 0..<capacity where voices[i] != nil { voices[i]!.noteOff() }
    }

    mutating func reset() {
        for i in 0..<capacity { voices[i] = nil }
    }

    mutating func render(count: Int, sampleRate: Float, into bus: AudioBus, pump: UnsafePointer<Float>) {
        for i in 0..<capacity where voices[i] != nil {
            voices[i]!.render(count: count, sampleRate: sampleRate, into: bus, pump: pump)
            if voices[i]!.isFinished { voices[i] = nil }
        }
    }
}
