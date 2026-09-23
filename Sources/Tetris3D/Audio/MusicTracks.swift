/// The two songs, arranged in code. Both are in A minor so sound effects (also A minor) sit on top.
enum MusicTracks {
    static let menu = makeMenu()
    static let game = makeGame()

    // MARK: - Game: Korobeiniki (traditional) as synthwave

    enum GameInstrument: Int, CaseIterable {
        case lead, leadHigh, bass, pad, arp, kick, snare, hat, openHat, crash, pulse
    }

    private static func makeGame() -> MusicSong {
        typealias I = GameInstrument
        var c = MusicComposer()

        let am = MusicChord("A1", "A3 C4 E4")
        let e = MusicChord("E1", "G#3 B3 E4")
        let dm = MusicChord("D2", "A3 D4 F4")
        let cM = MusicChord("C2", "G3 C4 E4")

        // Section A: eight bars, chords per half bar. Section B: one chord per bar.
        let melodyA = """
            E5/4 B4/2 C5/2 D5/4 C5/2 B4/2 | A4/4 A4/2 C5/2 E5/4 D5/2 C5/2 | B4/6 C5/2 D5/4 E5/4 | C5/4 A4/4 A4/4 -/4
            -/2 D5/4 F5/2 A5/4 G5/2 F5/2 | E5/6 C5/2 E5/4 D5/2 C5/2 | B4/4 B4/2 C5/2 D5/4 E5/4 | C5/4 A4/4 A4/4 -/4
            """
        let chordsA = [am, e, am, am, e, e, am, am, dm, dm, cM, cM, e, e, am, am]
        let melodyB = "E5/8 C5/8 | D5/8 B4/8 | C5/8 A4/8 | G#4/8 B4/8 | E5/8 C5/8 | D5/8 B4/8 | C5/4 E5/4 A5/8 | G#5/16"
        let chordsB = [am, am, e, e, am, am, e, e, am, am, e, e, am, am, e, e]

        // Form: A A B A, 32 bars.
        let sections: [(bar: Int, isB: Bool)] = [(0, false), (8, false), (16, true), (24, false)]
        for section in sections {
            let start = section.bar * 16
            let melody = section.isB ? melodyB : melodyA
            c.phrase(melody, at: start, instrument: I.lead.rawValue, velocity: section.isB ? 0.85 : 1)
            c.phrase(melody, at: start, instrument: I.leadHigh.rawValue, velocity: 0.5, layer: .energy2, transpose: 12)

            let chords = section.isB ? chordsB : chordsA
            for (half, chord) in chords.enumerated() {
                let step = start + half * 8
                let halfTime = section.isB && half < 8

                // Pad: one note per chord change, merged across identical halves.
                if half == 0 || chords[half - 1].tones != chord.tones {
                    let span = chords[half...].prefix { $0.tones == chord.tones }.count * 8
                    for tone in chord.tones {
                        c.add(step: step, length: span, note: tone, instrument: I.pad.rawValue, velocity: 0.9)
                    }
                }

                // Bass: driving octave eighths; long quarter notes in the first half of B.
                if halfTime {
                    for i in 0..<2 {
                        c.add(step: step + i * 4, length: 4, note: chord.bass + 12 * i, instrument: I.bass.rawValue, velocity: 0.9)
                    }
                } else {
                    for i in 0..<4 {
                        let velocity: Float = i % 2 == 0 ? 1 : 0.75
                        c.add(step: step + i * 2, length: 2, note: chord.bass + (i % 2) * 12, instrument: I.bass.rawValue, velocity: velocity)
                    }
                }

                // Arpeggio (energy layer): up-down through the chord an octave above the pad.
                let arpTones = chord.tones.map { $0 + 12 } + [chord.tones[0] + 24]
                let order = [0, 1, 2, 3, 2, 1, 2, 3]
                for i in 0..<8 {
                    c.add(
                        step: step + i, length: 1, note: arpTones[order[i] % arpTones.count],
                        instrument: I.arp.rawValue, velocity: i % 2 == 0 ? 1 : 0.7, layer: .energy1
                    )
                }

                // Danger pulse: urgent 16ths on the root, faded in by the danger amount.
                for i in 0..<8 {
                    c.add(
                        step: step + i, length: 1, note: chord.bass + 36, instrument: I.pulse.rawValue,
                        velocity: i % 4 == 0 ? 1 : 0.55, layer: .danger
                    )
                }
            }

            for bar in section.bar..<(section.bar + 8) {
                let last = bar == section.bar + 7
                let breakdown = section.isB && bar < section.bar + 4
                if breakdown {
                    c.drums("x-------x-------", bar: bar, instrument: I.kick.rawValue, note: 31)
                    c.drums("--------x-------", bar: bar, instrument: I.snare.rawValue, note: 54)
                    c.drums("o-.-o-.-o-.-o-.-", bar: bar, instrument: I.hat.rawValue)
                } else {
                    c.drums("x---x---x---x---", bar: bar, instrument: I.kick.rawValue, note: 31)
                    let snare = !last ? "----x-------x---" : bar == 31 ? "----x---x.x.xoxx" : "----x-------x.ox"
                    c.drums(snare, bar: bar, instrument: I.snare.rawValue, note: 54)
                    c.drums("--x---x---x---x-", bar: bar, instrument: I.hat.rawValue)
                    c.drums("-.-.-.-.-.-.-.-.", bar: bar, instrument: I.hat.rawValue, layer: .energy1)
                    c.drums("--------------o-", bar: bar, instrument: I.openHat.rawValue, layer: .energy2)
                }
            }
            c.drums("x", bar: section.bar, instrument: I.crash.rawValue)
        }

        return MusicSong(
            bpm: 118,
            lengthSteps: 32 * 16,
            events: c.sortedEvents,
            instruments: I.allCases.map(gamePatch),
            pumpInstrument: I.kick.rawValue,
            pumpDepth: 0.55,
            energyLevels: (3, 6),
            tempoPerLevel: 0.03,
            maxTempoScale: 1.45
        )
    }

    private static func gamePatch(_ instrument: GameInstrument) -> SynthPatch {
        switch instrument {
        case .lead:
            SynthPatch(
                wave1: .saw, wave2: .saw, osc2Mix: 0.8, osc2Detune: 11, stereoSpread: 0.6, attack: 0.004,
                decay: 0.35, sustain: 0.65, release: 0.12, vibratoDepth: 0.08, vibratoRate: 5.2, filter: .lowpass,
                cutoff: 1900, filterSweep: 1.4, filterSweepTime: 0.12, resonance: 0.35, gain: 0.2, reverbSend: 0.22,
                delaySend: 0.3
            )
        case .leadHigh:
            SynthPatch(
                wave1: .square, wave2: .triangle, osc2Mix: 0.6, osc2Detune: -6, stereoSpread: 0.8, attack: 0.006,
                decay: 0.2, sustain: 0.5, release: 0.1, filter: .lowpass, cutoff: 3200, gain: 0.12, reverbSend: 0.3,
                delaySend: 0.4
            )
        case .bass:
            SynthPatch(
                wave1: .saw, subMix: 0.7, attack: 0.002, decay: 0.16, sustain: 0.45, release: 0.04, filter: .lowpass,
                cutoff: 320, filterSweep: 2.3, filterSweepTime: 0.08, resonance: 0.45, gain: 0.28, pumped: true
            )
        case .pad:
            SynthPatch(
                wave1: .saw, wave2: .saw, osc2Mix: 1, osc2Detune: 15, stereoSpread: 0.9, attack: 0.25, decay: 1.2,
                sustain: 0.75, release: 0.5, filter: .lowpass, cutoff: 1300, resonance: 0.2, gain: 0.07,
                reverbSend: 0.5, delaySend: 0.08, pumped: true
            )
        case .arp:
            SynthPatch(
                wave1: .square, wave2: .saw, osc2Mix: 0.3, osc2Ratio: 2, decay: 0.08, release: 0.04,
                filter: .lowpass, cutoff: 2200, filterSweep: 1.5, filterSweepTime: 0.05, gain: 0.1, reverbSend: 0.2,
                delaySend: 0.4
            )
        case .kick:
            SynthPatch(
                wave1: .sine, attack: 0.001, decay: 0.2, pitchSweep: 38, pitchSweepTime: 0.026, gain: 0.6
            )
        case .snare:
            SynthPatch(
                wave1: .triangle, osc1Mix: 0.6, noiseMix: 1, attack: 0.001, decay: 0.12, release: 0.08,
                pitchSweep: 7, pitchSweepTime: 0.03, filter: .highpass, cutoff: 240, gain: 0.28, reverbSend: 0.45
            )
        case .hat:
            SynthPatch(
                osc1Mix: 0, noiseMix: 1, attack: 0.001, decay: 0.022, filter: .highpass, cutoff: 7500,
                resonance: 0.2, gain: 0.16, reverbSend: 0.05
            )
        case .openHat:
            SynthPatch(
                osc1Mix: 0, noiseMix: 1, attack: 0.002, decay: 0.16, filter: .highpass, cutoff: 6500, gain: 0.12,
                reverbSend: 0.15
            )
        case .crash:
            SynthPatch(
                osc1Mix: 0, noiseMix: 1, attack: 0.002, decay: 0.7, filter: .highpass, cutoff: 4500, filterSweep: 1,
                filterSweepTime: 0.3, gain: 0.12, reverbSend: 0.3
            )
        case .pulse:
            SynthPatch(
                wave1: .square, decay: 0.05, release: 0.03, filter: .lowpass, cutoff: 2600, resonance: 0.5,
                gain: 0.09, delaySend: 0.15
            )
        }
    }

    // MARK: - Menu: original ambient loop

    enum MenuInstrument: Int, CaseIterable {
        case pad, bell, bass, lead, kick, shaker
    }

    private static func makeMenu() -> MusicSong {
        typealias I = MenuInstrument
        var c = MusicComposer()

        let progression = [
            MusicChord("F1", "F3 A3 C4 E4"),
            MusicChord("G1", "G3 B3 D4 E4"),
            MusicChord("E1", "E3 G3 B3 D4"),
            MusicChord("A1", "A3 C4 E4 G4 B4"),
        ]
        let melody = """
            E5/6 D5/2 C5/8 | A4/12 C5/4 | D5/6 C5/2 B4/8 | G4/12 B4/4
            B4/6 A4/2 G4/8 | E4/8 G4/4 B4/4 | C5/6 B4/2 A4/8 | E5/16
            """

        // Sixteen bars: the progression twice, the second time with melody and a soft pulse.
        for pass in 0..<2 {
            for (i, chord) in progression.enumerated() {
                let bar = pass * 8 + i * 2
                let step = bar * 16
                for tone in chord.tones {
                    c.add(step: step, length: 32, note: tone, instrument: I.pad.rawValue, velocity: 0.8)
                }
                c.add(step: step, length: 20, note: chord.bass + 12, instrument: I.bass.rawValue)
                c.add(step: step + 24, length: 8, note: chord.bass + 19, instrument: I.bass.rawValue, velocity: 0.7)

                let tones = chord.tones.map { $0 + 12 } + [chord.tones[0] + 24, chord.tones[1] + 24]
                let order = [0, 2, 1, 3, 2, 4, 3, 5, 4, 2, 3, 1, 2, 0, 1, 2]
                let accents: [Float] = [0.9, 0.45, 0.65, 0.45]
                for (n, index) in order.enumerated() {
                    c.add(
                        step: step + n * 2, length: 2, note: tones[index % tones.count],
                        instrument: I.bell.rawValue, velocity: accents[n % 4]
                    )
                }

                for b in bar..<(bar + 2) {
                    c.drums("--o-.-o---o-.-o-", bar: b, instrument: I.shaker.rawValue)
                    if pass == 1 { c.drums("o---------o-----", bar: b, instrument: I.kick.rawValue, note: 31) }
                }
            }
        }
        c.phrase(melody, at: 8 * 16, instrument: I.lead.rawValue)

        return MusicSong(
            bpm: 84,
            lengthSteps: 16 * 16,
            events: c.sortedEvents,
            instruments: I.allCases.map(menuPatch),
            pumpInstrument: I.kick.rawValue,
            pumpDepth: 0.3
        )
    }

    private static func menuPatch(_ instrument: MenuInstrument) -> SynthPatch {
        switch instrument {
        case .pad:
            SynthPatch(
                wave1: .saw, wave2: .saw, osc2Mix: 1, osc2Detune: 9, stereoSpread: 1, attack: 1.4, decay: 2,
                sustain: 0.85, release: 1.6, filter: .lowpass, cutoff: 850, resonance: 0.25, gain: 0.075,
                reverbSend: 0.7, delaySend: 0.1, pumped: true
            )
        case .bell:
            SynthPatch(
                wave1: .sine, wave2: .triangle, osc2Mix: 0.18, osc2Ratio: 2, attack: 0.003, decay: 0.35,
                release: 0.3, gain: 0.11, reverbSend: 0.45, delaySend: 0.45
            )
        case .bass:
            SynthPatch(
                wave1: .triangle, subMix: 0.5, attack: 0.04, decay: 1.2, sustain: 0.6, release: 0.5,
                filter: .lowpass, cutoff: 500, gain: 0.3, pumped: true
            )
        case .lead:
            SynthPatch(
                wave1: .triangle, wave2: .sine, osc2Mix: 0.35, osc2Ratio: 2, osc2Detune: 4, stereoSpread: 0.5,
                attack: 0.07, decay: 0.8, sustain: 0.7, release: 0.5, vibratoDepth: 0.12, vibratoRate: 4.8,
                filter: .lowpass, cutoff: 2400, gain: 0.15, reverbSend: 0.5, delaySend: 0.35
            )
        case .kick:
            SynthPatch(
                wave1: .sine, attack: 0.002, decay: 0.22, pitchSweep: 30, pitchSweepTime: 0.03, gain: 0.55
            )
        case .shaker:
            SynthPatch(
                osc1Mix: 0, noiseMix: 1, attack: 0.006, decay: 0.035, filter: .highpass, cutoff: 6000, gain: 0.08,
                reverbSend: 0.2
            )
        }
    }
}
