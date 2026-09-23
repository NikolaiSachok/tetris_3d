import TetrisCore

/// Maps what happens in a played game onto sound. The attract game behind the menu stays silent.
extension GameController {
    func playSounds(for events: [GameEvent]) {
        for event in events {
            switch event {
            case .moved: audio.play(.move)
            case .rotated: audio.play(.rotate)
            case .hardDropped: audio.play(.hardDrop)
            case .locked: audio.play(.lock)
            case .held: audio.play(.hold)
            case let .scored(action):
                if action.perfectClear {
                    audio.play(.perfectClear)
                } else if action.lines > 0 {
                    audio.play(.lineClear(action.lines))
                }
                if action.tSpin != .none { audio.play(.tSpin) }
                if action.backToBack { audio.play(.backToBack) }
                if action.combo > 0 { audio.play(.combo(action.combo)) }
            case let .levelUp(level):
                audio.play(.levelUp)
                audio.setIntensity(level: level)
            case .finished(.toppedOut):
                audio.play(.gameOver)
                audio.stopMusic()
            case .finished(.completed):
                audio.play(.achievement)
            case .linesCleared, .stackTrimmed, .rowsCollapsed:
                break
            }
        }
    }

    func applyVolumes() {
        audio.musicVolume = Float(profile.settings.musicVolume)
        audio.effectsVolume = Float(profile.settings.effectsVolume)
    }
}
