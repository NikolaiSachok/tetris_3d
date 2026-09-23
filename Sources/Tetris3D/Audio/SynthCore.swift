import Darwin
import os

/// The whole synthesizer: effect voices, the music sequencers, the effect sends and the master bus.
///
/// Threading: `send` may be called from any thread; it appends to a small locked queue. `render`
/// runs on the audio render thread, drains that queue with a try-lock (never blocks the audio
/// thread; contended commands simply wait one buffer) and owns all other state exclusively.
final class SynthCore: @unchecked Sendable {
    enum Command: Sendable {
        case note(SynthNote)
        /// Index into the songs passed to `init`; nil stops the music.
        case playMusic(Int?)
        case setPaused(Bool)
        case setLevel(Int)
        case setDanger(Float)
        case setMusicVolume(Float)
        case setEffectsVolume(Float)
    }

    static let sampleRate = 48000.0
    private static let maxPendingCommands = 256

    private let pending = OSAllocatedUnfairLock(initialState: [Command]())
    /// Render-thread only.
    private var inbox: [Command] = []
    private var state: SynthState

    init(songs: [MusicSong]) {
        state = SynthState(sampleRate: Float(SynthCore.sampleRate), songs: songs)
        inbox.reserveCapacity(SynthCore.maxPendingCommands)
        pending.withLock { $0.reserveCapacity(SynthCore.maxPendingCommands) }
    }

    deinit {
        state.deallocate()
    }

    func send(_ command: Command) {
        pending.withLock { commands in
            if commands.count < SynthCore.maxPendingCommands { commands.append(command) }
        }
    }

    /// Fills two non-interleaved channels. Render thread only.
    func render(frameCount: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        // Swap buffers instead of copying so the audio thread never allocates.
        pending.withLockIfAvailableUnchecked { commands in swap(&commands, &inbox) }
        if !inbox.isEmpty {
            for command in inbox { state.apply(command) }
            inbox.removeAll(keepingCapacity: true)
        }
        state.render(frameCount: frameCount, left: left, right: right)
    }
}

/// Render-thread state behind `SynthCore`.
private struct SynthState {
    private static let crossfadeTime: Float = 1.0
    private static let reverbReturn: Float = 0.55
    private static let delayReturn: Float = 0.45
    private static let masterGain: Float = 0.9
    /// Music sits under the effects.
    private static let musicMix: Float = 0.8

    let sampleRate: Float
    private var effects = VoicePool(capacity: 64, maxHeld: 40)
    private let players: UnsafeMutableBufferPointer<MusicPlayer>
    private let effectsBus = AudioBus()
    private let musicBus = AudioBus()
    private let noPump: UnsafeMutablePointer<Float>
    private var reverb: DSP.Reverb
    private var delay: DSP.PingPongDelay
    private var limiter: DSP.Limiter

    private var musicGain: DSP.Smoothed
    private var effectsGain: DSP.Smoothed
    private var musicVolume: Float = 1
    private var isPaused = false
    /// Pause muffles the music with a lowpass sweeping down.
    private var pauseCutoff: DSP.Smoothed
    private var pauseFilterL = DSP.SVFilter()
    private var pauseFilterR = DSP.SVFilter()

    init(sampleRate: Float, songs: [MusicSong]) {
        self.sampleRate = sampleRate
        players = .allocate(capacity: songs.count)
        _ = players.initialize(from: songs.map { MusicPlayer(song: $0, sampleRate: sampleRate) })
        noPump = .allocate(capacity: AudioBus.blockSize)
        noPump.initialize(repeating: 1, count: AudioBus.blockSize)
        reverb = DSP.Reverb(sampleRate: sampleRate)
        delay = DSP.PingPongDelay(time: 0.375, sampleRate: sampleRate)
        limiter = DSP.Limiter(sampleRate: sampleRate)
        musicGain = DSP.Smoothed(1, time: 0.12, sampleRate: sampleRate)
        effectsGain = DSP.Smoothed(1, time: 0.05, sampleRate: sampleRate)
        pauseCutoff = DSP.Smoothed(20000, time: 0.12, sampleRate: sampleRate)
    }

    func deallocate() {
        effects.deallocate()
        for player in players { player.deallocate() }
        players.deinitialize().deallocate()
        effectsBus.deallocate()
        musicBus.deallocate()
        noPump.deallocate()
        reverb.deallocate()
        delay.deallocate()
    }

    mutating func apply(_ command: SynthCore.Command) {
        switch command {
        case let .note(note):
            effects.start(note, sampleRate: sampleRate)
        case let .playMusic(index):
            for i in players.indices {
                if i == index {
                    players[i].play(fadeTime: SynthState.crossfadeTime)
                } else {
                    players[i].stop(fadeTime: SynthState.crossfadeTime)
                }
            }
        case let .setPaused(paused):
            isPaused = paused
            updateMusicGain()
            pauseCutoff.target = paused ? 700 : 20000
        case let .setLevel(level):
            for i in players.indices { players[i].setLevel(level) }
        case let .setDanger(danger):
            for i in players.indices { players[i].setDanger(danger) }
        case let .setMusicVolume(volume):
            musicVolume = volume
            updateMusicGain()
        case let .setEffectsVolume(volume):
            effectsGain.target = volume * volume
        }
    }

    private mutating func updateMusicGain() {
        // Perceptual volume curve; pause ducks to about -10 dB.
        musicGain.target = SynthState.musicMix * musicVolume * musicVolume * (isPaused ? 0.3 : 1)
    }

    mutating func render(frameCount: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        var done = 0
        while done < frameCount {
            // Cut blocks at sequencer steps so notes start sample-accurately.
            var count = min(frameCount - done, AudioBus.blockSize)
            for i in players.indices where players[i].isSequencing {
                players[i].advanceIfDue()
                count = min(count, Int(players[i].samplesUntilStep.rounded(.up)))
            }
            renderBlock(count: count, left: left + done, right: right + done)
            for i in players.indices { players[i].consume(count) }
            done += count
        }
    }

    private mutating func renderBlock(count: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        effectsBus.clear(count)
        musicBus.clear(count)
        effects.render(count: count, sampleRate: sampleRate, into: effectsBus, pump: noPump)
        for i in players.indices { players[i].render(count: count, into: musicBus) }

        // Filter coefficients follow the (slow) pause sweep once per block.
        let coefficients = DSP.SVFilter.Coefficients(cutoff: pauseCutoff.value, resonance: 0.2, sampleRate: sampleRate)

        for i in 0..<count {
            let mg = musicGain.next()
            let eg = effectsGain.next()
            _ = pauseCutoff.next()
            let musicL = pauseFilterL.process(musicBus.left[i], coefficients, .lowpass)
            let musicR = pauseFilterR.process(musicBus.right[i], coefficients, .lowpass)
            let (reverbL, reverbR) = reverb.process(musicBus.reverb[i] * mg + effectsBus.reverb[i] * eg)
            let (delayL, delayR) = delay.process(musicBus.delay[i] * mg + effectsBus.delay[i] * eg)
            var l = musicL * mg + effectsBus.left[i] * eg + reverbL * SynthState.reverbReturn + delayL * SynthState.delayReturn
            var r = musicR * mg + effectsBus.right[i] * eg + reverbR * SynthState.reverbReturn + delayR * SynthState.delayReturn
            l *= SynthState.masterGain
            r *= SynthState.masterGain
            limiter.process(&l, &r)
            left[i] = l
            right[i] = r
        }
    }
}
