import AVFoundation
import os

/// Game audio: synthesized sound effects and music rendered by one `AVAudioSourceNode`.
/// If audio can't start (no output device, engine failure) the game simply runs silent and
/// retries when the audio configuration changes.
@MainActor
final class AudioEngine {
    enum SoundEffect: Sendable, Equatable {
        case move, rotate, softDrop, hardDrop, lock, hold
        case lineClear(Int)
        case tSpin
        case combo(Int)
        case backToBack, perfectClear, levelUp, gameOver
        case menuMove, menuSelect, menuBack
        case achievement, countdown, go, pause
    }

    enum Track: Sendable {
        case menu, game

        fileprivate var songIndex: Int {
            switch self {
            case .menu: 0
            case .game: 1
            }
        }
    }

    /// 0...1, perceptual (squared) curve.
    var musicVolume: Float = 0.8 {
        didSet {
            musicVolume = min(max(musicVolume, 0), 1)
            core.send(.setMusicVolume(musicVolume))
        }
    }

    /// 0...1, perceptual (squared) curve.
    var effectsVolume: Float = 0.9 {
        didSet {
            effectsVolume = min(max(effectsVolume, 0), 1)
            core.send(.setEffectsVolume(effectsVolume))
        }
    }

    private(set) var isRunning = false

    private static let logger = Logger(subsystem: "Tetris3D", category: "Audio")
    private let engine = AVAudioEngine()
    private let core: SynthCore
    private let source: AVAudioSourceNode
    private let manualRendering: Bool
    private var track: Track?
    private var isPaused = false
    private var level = 1
    private var danger: Float = 0
    private var rng = SystemRandomNumberGenerator()
    private var configurationObserver: NSObjectProtocol?

    /// `manualRendering` renders offline through `renderOffline(seconds:)` instead of to the device (tests).
    init(manualRendering: Bool = false) {
        self.manualRendering = manualRendering
        core = SynthCore(songs: [MusicTracks.menu, MusicTracks.game])
        let format = AVAudioFormat(standardFormatWithSampleRate: SynthCore.sampleRate, channels: 2)!
        source = AudioEngine.makeSourceNode(core: core, format: format)

        do {
            if manualRendering {
                try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            }
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: format)
        } catch {
            AudioEngine.logger.error("Audio disabled: \(error.localizedDescription)")
            return
        }

        if !manualRendering {
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.restart() }
            }
        }
        start()
    }

    // MARK: - Playback

    func play(_ effect: SoundEffect) {
        guard isRunning else { return }
        for note in SoundEffects.notes(for: effect, using: &rng) { core.send(.note(note)) }
    }

    /// Crossfades to `track`, starting it from the top. No-op if `track` is already playing.
    func playMusic(_ track: Track) {
        self.track = track
        core.send(.playMusic(track.songIndex))
    }

    func stopMusic() {
        track = nil
        core.send(.playMusic(nil))
    }

    /// Ducks and muffles the music while paused.
    func setPaused(_ paused: Bool) {
        isPaused = paused
        core.send(.setPaused(paused))
    }

    /// Game track tempo (+3% per level, capped at +45%) and energy layers follow the level.
    func setIntensity(level: Int) {
        self.level = level
        core.send(.setLevel(level))
    }

    /// 0...1: fades in an urgent pulse layer when the stack nears the top.
    func setDanger(_ amount: Float) {
        let amount = min(max(amount, 0), 1)
        guard abs(amount - danger) > 0.02 || (amount == 0) != (danger == 0) else { return }
        danger = amount
        core.send(.setDanger(amount))
    }

    // MARK: - Engine

    /// Built outside the main actor: the render block runs on the real-time audio thread.
    private nonisolated static func makeSourceNode(core: SynthCore, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            core.render(frameCount: Int(frameCount), left: left, right: right)
            return noErr
        }
    }

    private func start() {
        do {
            engine.prepare()
            try engine.start()
            isRunning = true
            syncState()
        } catch {
            isRunning = false
            AudioEngine.logger.error("Audio engine failed to start: \(error.localizedDescription)")
        }
    }

    /// The output device or its format changed; the engine has stopped. Reconnect and restart.
    private func restart() {
        engine.stop()
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        start()
    }

    /// Re-sends every setting so the synth matches this object even if commands were dropped while stopped.
    private func syncState() {
        core.send(.setMusicVolume(musicVolume))
        core.send(.setEffectsVolume(effectsVolume))
        core.send(.setPaused(isPaused))
        core.send(.setLevel(level))
        core.send(.setDanger(danger))
        core.send(.playMusic(track?.songIndex))
    }

    // MARK: - Offline rendering

    /// Renders `seconds` of output. Only for engines created with `manualRendering: true`.
    func renderOffline(seconds: Double) -> AVAudioPCMBuffer? {
        guard manualRendering, isRunning else { return nil }
        let total = AVAudioFrameCount(seconds * SynthCore.sampleRate)
        guard let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: total),
              let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)
        else { return nil }

        while output.frameLength < total {
            let frames = min(chunk.frameCapacity, total - output.frameLength)
            guard (try? engine.renderOffline(frames, to: chunk)) == .success else { return nil }
            for channel in 0..<Int(output.format.channelCount) {
                (output.floatChannelData![channel] + Int(output.frameLength))
                    .update(from: chunk.floatChannelData![channel], count: Int(chunk.frameLength))
            }
            output.frameLength += chunk.frameLength
        }
        return output
    }
}
