import Darwin

/// Sound design: turns a `SoundEffect` into the voices that play it. Everything sits in A minor
/// (A major for rewards) so effects agree with the music.
enum SoundEffects {
    /// Voice groups: frequent sounds cap their own polyphony so rapid repeats never smear.
    private enum Group: UInt8 { case none, move, rotate, softDrop, menu }

    static func notes(for effect: AudioEngine.SoundEffect, using rng: inout some RandomNumberGenerator) -> [SynthNote] {
        /// Slight random detune (in semitones) so repeated sounds don't feel mechanical.
        func wobble(_ semis: Float) -> Float { exp2f(Float.random(in: -semis...semis, using: &rng) / 12) }
        func pan(_ width: Float) -> Float { Float.random(in: -width...width, using: &rng) }

        switch effect {
        case .move:
            return [
                SynthNote(
                    patch: tick, frequency: hz("E6") * wobble(0.6), duration: 0.01, velocity: 1, pan: pan(0.2),
                    group: Group.move.rawValue, groupLimit: 2
                ),
            ]

        case .rotate:
            return [
                SynthNote(
                    patch: flick, frequency: hz("A5") * wobble(0.5), duration: 0.02, pan: pan(0.2),
                    group: Group.rotate.rawValue, groupLimit: 2
                ),
            ]

        case .softDrop:
            return [
                SynthNote(
                    patch: thump, frequency: hz("F#3") * wobble(0.4), duration: 0.01, velocity: 0.5,
                    group: Group.softDrop.rawValue, groupLimit: 2
                ),
            ]

        case .hardDrop:
            let w = wobble(0.5)
            return [
                SynthNote(patch: boom, frequency: 52 * w, duration: 0.05),
                SynthNote(patch: impactNoise, frequency: 100, duration: 0.02, velocity: 1, pan: pan(0.1)),
                SynthNote(patch: swish, frequency: hz("A4") * w, duration: 0.03, velocity: 0.8),
            ]

        case .lock:
            return [
                SynthNote(patch: thump, frequency: hz("G3") * wobble(0.3), duration: 0.02, velocity: 0.9),
                SynthNote(patch: clickNoise, frequency: 100, duration: 0.005, velocity: 0.8, pan: pan(0.15)),
            ]

        case .hold:
            return [
                SynthNote(patch: pluck, frequency: hz("E5"), duration: 0.04, velocity: 0.8, pan: -0.25),
                SynthNote(patch: pluck, frequency: hz("B5"), duration: 0.06, velocity: 0.8, pan: 0.25, delay: 0.05),
                SynthNote(patch: whoosh, frequency: 100, duration: 0.08, velocity: 0.7),
            ]

        case let .lineClear(count):
            return lineClear(count: min(max(count, 1), 4))

        case .tSpin:
            return [
                SynthNote(patch: zap, frequency: hz("E5"), duration: 0.1, pan: -0.3),
                SynthNote(patch: zap, frequency: hz("B5"), duration: 0.1, velocity: 0.7, pan: 0.3, delay: 0.02),
                SynthNote(patch: bell, frequency: hz("A6"), duration: 0.1, velocity: 0.6, delay: 0.09),
            ]

        case let .combo(count):
            // Climb the A minor pentatonic one step per combo, from A5.
            let scale = [0, 3, 5, 7, 10]
            let index = min(max(count, 1), 12) - 1
            let note = MusicNote.midi("A5")! + 12 * (index / 5) + scale[index % 5]
            let velocity = 0.75 + 0.25 * Float(index) / 11
            return [
                SynthNote(patch: comboPluck, frequency: DSP.midiToHz(Float(note)), duration: 0.05, velocity: velocity),
                SynthNote(
                    patch: comboPluck, frequency: DSP.midiToHz(Float(note + 12)), duration: 0.05, velocity: velocity * 0.45,
                    pan: 0.3, delay: 0.045
                ),
            ]

        case .backToBack:
            // "da-DAA": a short G power chord pushing into a long A one.
            let pickup = ["G3", "D4", "G4"].map { SynthNote(patch: brass, frequency: hz($0), duration: 0.06, velocity: 0.7) }
            let hit = ["A3", "E4", "A4", "A5"].enumerated().map { i, name in
                SynthNote(patch: brass, frequency: hz(name), duration: 0.3, velocity: i == 3 ? 0.5 : 1, delay: 0.12)
            }
            return pickup + hit

        case .perfectClear:
            // Glissando up an A major arpeggio, landing on a wide A major chord.
            let arpeggio = [0, 4, 7]
            var notes = (0..<15).map { i in
                let midi = MusicNote.midi("A4")! + 12 * (i / 3) + arpeggio[i % 3]
                return SynthNote(
                    patch: bell, frequency: DSP.midiToHz(Float(midi)), duration: 0.08, velocity: 0.8,
                    pan: Float(i) / 7 - 1, delay: Float(i) * 0.04
                )
            }
            notes += ["A3", "C#4", "E4", "A4", "C#5", "E5"].enumerated().map { i, name in
                SynthNote(patch: sweepPad, frequency: hz(name), duration: 1.3, velocity: 0.9, pan: i % 2 == 0 ? -0.5 : 0.5, delay: 0.55)
            }
            notes.append(SynthNote(patch: boom, frequency: 55, duration: 0.2, delay: 0.55))
            notes.append(SynthNote(patch: shimmer, frequency: 100, duration: 0.8, velocity: 1, delay: 0.55))
            return notes

        case .levelUp:
            var notes = ["E5", "A5", "C#6", "E6"].enumerated().map { i, name in
                SynthNote(patch: fanfare, frequency: hz(name), duration: i == 3 ? 0.4 : 0.05, delay: Float(i) * 0.075)
            }
            notes += ["A4", "C#5", "E5"].map {
                SynthNote(patch: sweepPad, frequency: hz($0), duration: 0.4, velocity: 0.6, pan: 0, delay: 0.225)
            }
            return notes

        case .gameOver:
            var notes = ["E5", "C5", "A4", "F4"].enumerated().map { i, name in
                SynthNote(patch: mournLead, frequency: hz(name), duration: 0.24, velocity: 1 - Float(i) * 0.1, delay: Float(i) * 0.28)
            }
            notes.append(SynthNote(patch: mournLead, frequency: hz("E4"), duration: 0.9, velocity: 0.7, delay: 1.12))
            // Power-down: a saw diving two octaves, plus a low boom.
            notes.append(SynthNote(patch: powerDown, frequency: hz("A2"), duration: 1.2, velocity: 0.8, delay: 1.12))
            notes.append(SynthNote(patch: boom, frequency: 45, duration: 0.3, delay: 1.12))
            return notes

        case .menuMove:
            return [
                SynthNote(
                    patch: blip, frequency: hz("A6"), duration: 0.01, velocity: 0.8,
                    group: Group.menu.rawValue, groupLimit: 2
                ),
            ]

        case .menuSelect:
            return [
                SynthNote(patch: pluck, frequency: hz("E6"), duration: 0.03, velocity: 0.8),
                SynthNote(patch: pluck, frequency: hz("A6"), duration: 0.08, velocity: 0.9, delay: 0.06),
            ]

        case .menuBack:
            return [
                SynthNote(patch: softPluck, frequency: hz("A5"), duration: 0.03, velocity: 0.8),
                SynthNote(patch: softPluck, frequency: hz("E5"), duration: 0.06, velocity: 0.8, delay: 0.06),
            ]

        case .achievement:
            var notes = ["C#6", "E6", "A6", "C#7"].enumerated().map { i, name in
                SynthNote(patch: bell, frequency: hz(name), duration: 0.1, velocity: 0.9, pan: Float(i) * 0.2 - 0.3, delay: Float(i) * 0.08)
            }
            notes += ["A4", "C#5", "E5"].map {
                SynthNote(patch: sweepPad, frequency: hz($0), duration: 0.6, velocity: 0.5, delay: 0.24)
            }
            notes.append(SynthNote(patch: shimmer, frequency: 100, duration: 0.5, velocity: 0.8, delay: 0.24))
            return notes

        case .countdown:
            return [SynthNote(patch: beep, frequency: hz("A5"), duration: 0.12)]

        case .go:
            return ["A5", "E6", "A6"].map { SynthNote(patch: beep, frequency: hz($0), duration: 0.35, velocity: 0.8) }
                + [SynthNote(patch: whoosh, frequency: 100, duration: 0.2, velocity: 1)]

        case .pause:
            return [SynthNote(patch: dip, frequency: hz("A4"), duration: 0.08, velocity: 1)]
        }
    }

    private static func lineClear(count: Int) -> [SynthNote] {
        // Bigger clears: more chord tones, longer strum, brighter shimmer.
        let chords = [
            ["A5", "C6", "E6"],
            ["A5", "C6", "E6", "A6"],
            ["E5", "A5", "C6", "E6", "G6", "A6"],
            ["A4", "E5", "A5", "B5", "C6", "E6", "G6", "A6", "B6", "E7"],
        ]
        let tones = chords[count - 1]
        let strum: Float = count == 4 ? 0.028 : 0.04
        var notes = tones.enumerated().map { i, name in
            SynthNote(
                patch: sparkle, frequency: hz(name), duration: 0.12 + 0.08 * Float(count), velocity: 0.8,
                pan: (Float(i) / Float(max(tones.count - 1, 1))) * 1.2 - 0.6, delay: Float(i) * strum
            )
        }
        var riser = shimmer
        riser.gain *= 0.4 + 0.2 * Float(count)
        notes.append(SynthNote(patch: riser, frequency: 100, duration: 0.1 * Float(count), velocity: 1))

        if count == 4 {
            // Tetris: a wide Am9 supersaw chord whose filter sweeps open, plus a sub drop.
            let delay = strum * Float(tones.count)
            notes += ["A3", "E4", "G4", "B4", "C5", "E5"].enumerated().map { i, name in
                SynthNote(patch: sweepPad, frequency: hz(name), duration: 0.9, velocity: 1, pan: i % 2 == 0 ? -0.6 : 0.6, delay: delay)
            }
            notes.append(SynthNote(patch: boom, frequency: 55, duration: 0.25, delay: delay))
            notes.append(SynthNote(patch: shimmer, frequency: 100, duration: 0.9, velocity: 1, delay: delay))
        } else if count >= 2 {
            notes.append(SynthNote(patch: boom, frequency: 55, duration: 0.05, velocity: 0.35 * Float(count)))
        }
        return notes
    }

    private static func hz(_ name: String) -> Float { DSP.midiToHz(Float(MusicNote.midi(name)!)) }

    // MARK: - Patches

    /// Piece shift: a tiny pitched tick.
    private static let tick = SynthPatch(
        wave1: .triangle, wave2: .sine, osc2Mix: 0.3, osc2Ratio: 2,
        attack: 0.001, decay: 0.014, release: 0.01, pitchSweep: 5, pitchSweepTime: 0.008,
        filter: .highpass, cutoff: 500, gain: 0.1, reverbSend: 0.03
    )

    /// Rotation: a short rising square flick.
    private static let flick = SynthPatch(
        wave1: .square, wave2: .triangle, osc2Mix: 0.4, osc2Ratio: 1.5,
        attack: 0.0015, decay: 0.035, release: 0.02, pitchSweep: -5, pitchSweepTime: 0.015,
        filter: .lowpass, cutoff: 2600, filterSweep: 1, filterSweepTime: 0.03, gain: 0.075, reverbSend: 0.06, delaySend: 0.04
    )

    private static let thump = SynthPatch(
        wave1: .triangle, attack: 0.001, decay: 0.05, release: 0.02, pitchSweep: 9, pitchSweepTime: 0.012,
        filter: .lowpass, cutoff: 1800, gain: 0.26
    )

    private static let clickNoise = SynthPatch(
        osc1Mix: 0, noiseMix: 1, attack: 0.0005, decay: 0.008, release: 0.005,
        filter: .highpass, cutoff: 3500, gain: 0.07
    )

    /// Low sine drop: the body of impacts.
    private static let boom = SynthPatch(
        wave1: .sine, attack: 0.001, decay: 0.16, release: 0.08, pitchSweep: 24, pitchSweepTime: 0.035,
        gain: 0.45
    )

    private static let impactNoise = SynthPatch(
        osc1Mix: 0, noiseMix: 1, attack: 0.001, decay: 0.07, release: 0.04,
        filter: .lowpass, cutoff: 700, filterSweep: 2.5, filterSweepTime: 0.03, gain: 0.3, reverbSend: 0.2
    )

    private static let swish = SynthPatch(
        wave1: .saw, attack: 0.001, decay: 0.05, release: 0.03, pitchSweep: 12, pitchSweepTime: 0.025,
        filter: .lowpass, cutoff: 1400, gain: 0.07, reverbSend: 0.1
    )

    private static let pluck = SynthPatch(
        wave1: .triangle, wave2: .sine, osc2Mix: 0.4, osc2Ratio: 2,
        attack: 0.002, decay: 0.09, release: 0.08,
        filter: .lowpass, cutoff: 5000, gain: 0.13, reverbSend: 0.2, delaySend: 0.2
    )

    private static let softPluck = SynthPatch(
        wave1: .triangle, attack: 0.002, decay: 0.08, release: 0.06,
        filter: .lowpass, cutoff: 1800, gain: 0.12, reverbSend: 0.15
    )

    private static let blip = SynthPatch(
        wave1: .sine, wave2: .triangle, osc2Mix: 0.2, osc2Ratio: 2,
        attack: 0.001, decay: 0.02, release: 0.015, pitchSweep: 2, pitchSweepTime: 0.01,
        gain: 0.09, reverbSend: 0.05
    )

    /// Band-passed noise sweeping upward.
    private static let whoosh = SynthPatch(
        osc1Mix: 0, noiseMix: 1, attack: 0.03, decay: 0.08, release: 0.06,
        filter: .bandpass, cutoff: 3500, filterSweep: -1.8, filterSweepTime: 0.08, resonance: 0.5, gain: 0.12, reverbSend: 0.2
    )

    /// High, airy noise that opens up: the tail of clears and rewards.
    private static let shimmer = SynthPatch(
        osc1Mix: 0, noiseMix: 1, attack: 0.02, decay: 0.25, release: 0.3,
        filter: .bandpass, cutoff: 7000, filterSweep: -2, filterSweepTime: 0.2, resonance: 0.4, gain: 0.07, reverbSend: 0.3
    )

    /// Bright detuned pluck for line-clear chords.
    private static let sparkle = SynthPatch(
        wave1: .saw, wave2: .saw, osc2Mix: 0.8, osc2Detune: 12, stereoSpread: 0.7,
        attack: 0.003, decay: 0.25, sustain: 0.2, release: 0.3,
        filter: .lowpass, cutoff: 2800, filterSweep: 1.5, filterSweepTime: 0.15, gain: 0.095, reverbSend: 0.35, delaySend: 0.25
    )

    /// Wide supersaw chord whose filter opens from dark to bright.
    private static let sweepPad = SynthPatch(
        wave1: .saw, wave2: .saw, osc2Mix: 1, osc2Detune: 16, stereoSpread: 1,
        attack: 0.02, decay: 0.6, sustain: 0.55, release: 0.6,
        filter: .lowpass, cutoff: 4500, filterSweep: -3, filterSweepTime: 0.25, resonance: 0.35,
        gain: 0.05, reverbSend: 0.5, delaySend: 0.25
    )

    private static let zap = SynthPatch(
        wave1: .saw, wave2: .square, osc2Mix: 0.7, osc2Detune: 20, stereoSpread: 0.6,
        attack: 0.002, decay: 0.2, release: 0.1, pitchSweep: 12, pitchSweepTime: 0.05,
        filter: .lowpass, cutoff: 2000, filterSweep: 2, filterSweepTime: 0.1, resonance: 0.7,
        gain: 0.11, reverbSend: 0.2, delaySend: 0.3
    )

    private static let bell = SynthPatch(
        wave1: .sine, wave2: .sine, osc2Mix: 0.25, osc2Ratio: 4.01,
        attack: 0.002, decay: 0.3, release: 0.3,
        gain: 0.1, reverbSend: 0.4, delaySend: 0.3
    )

    private static let comboPluck = SynthPatch(
        wave1: .square, wave2: .saw, osc2Mix: 0.35, osc2Ratio: 2,
        attack: 0.002, decay: 0.12, release: 0.08,
        filter: .lowpass, cutoff: 3000, filterSweep: 1, filterSweepTime: 0.05, gain: 0.1, reverbSend: 0.2, delaySend: 0.35
    )

    /// Punchy detuned brass stab.
    private static let brass = SynthPatch(
        wave1: .saw, wave2: .saw, osc2Mix: 1, osc2Detune: 14, stereoSpread: 0.8,
        attack: 0.005, decay: 0.25, sustain: 0.35, release: 0.2,
        filter: .lowpass, cutoff: 800, filterSweep: 2.2, filterSweepTime: 0.09, resonance: 0.4,
        gain: 0.09, reverbSend: 0.3, delaySend: 0.2
    )

    private static let fanfare = SynthPatch(
        wave1: .square, wave2: .saw, osc2Mix: 0.6, osc2Detune: 8, stereoSpread: 0.5,
        attack: 0.004, decay: 0.2, sustain: 0.6, release: 0.2, vibratoDepth: 0.1, vibratoRate: 6,
        filter: .lowpass, cutoff: 2600, filterSweep: 1, filterSweepTime: 0.08,
        gain: 0.09, reverbSend: 0.3, delaySend: 0.3
    )

    private static let mournLead = SynthPatch(
        wave1: .saw, wave2: .saw, osc2Mix: 0.8, osc2Detune: 10, stereoSpread: 0.6,
        attack: 0.01, decay: 0.4, sustain: 0.5, release: 0.35, pitchSweep: 1, pitchSweepTime: 0.04,
        vibratoDepth: 0.15, vibratoRate: 4.5,
        filter: .lowpass, cutoff: 1400, filterSweep: 0.8, filterSweepTime: 0.2,
        gain: 0.12, reverbSend: 0.45, delaySend: 0.3
    )

    private static let powerDown = SynthPatch(
        wave1: .saw, wave2: .saw, osc2Mix: 0.7, osc2Detune: -12, stereoSpread: 0.5,
        attack: 0.02, decay: 0.8, sustain: 0.3, release: 0.5, pitchSweep: 24, pitchSweepTime: 0.4,
        filter: .lowpass, cutoff: 500, filterSweep: 2, filterSweepTime: 0.4,
        gain: 0.1, reverbSend: 0.4
    )

    private static let beep = SynthPatch(
        wave1: .square, wave2: .sine, osc2Mix: 0.5,
        attack: 0.003, decay: 0.1, sustain: 0.6, release: 0.05,
        filter: .lowpass, cutoff: 3000, gain: 0.08, reverbSend: 0.15, delaySend: 0.1
    )

    /// Soft falling sine for pause.
    private static let dip = SynthPatch(
        wave1: .sine, wave2: .triangle, osc2Mix: 0.3,
        attack: 0.004, decay: 0.12, release: 0.08, pitchSweep: 7, pitchSweepTime: 0.04,
        gain: 0.16, reverbSend: 0.25
    )
}
