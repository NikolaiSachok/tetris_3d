import MetaGame
import TetrisCore

/// Keyboard navigation and actions for the menu, pause and result screens. Mouse clicks call the same actions.
extension GameController {
    func handleMenu(_ key: Key) {
        switch screen {
        case let .menu(page): handle(key, on: page)
        case .paused: handlePause(key)
        case .results: handleResults(key)
        case .countdown, .playing: break
        }
    }

    // MARK: - Actions

    /// Changes the keyboard/hover selection, with a tick when it actually moves.
    func select(_ change: (inout MenuState) -> Void) {
        var updated = menu
        change(&updated)
        guard updated != menu else { return }
        menu = updated
        audio.play(.menuMove)
    }

    /// Back to the main menu from one of its pages.
    func back() {
        audio.play(.menuBack)
        showMenu()
    }

    /// Back to the pause menu from its settings page.
    func closePauseSettings() {
        audio.play(.menuBack)
        menu.pauseSettings = false
    }

    /// Starts a game from the mode select screen.
    func choose(_ mode: GameMode) {
        audio.play(.menuSelect)
        play(mode)
    }

    func activate(_ item: MainMenuItem) {
        audio.play(.menuSelect)
        if let page = item.page {
            showMenu(page)
        } else {
            quit()
        }
    }

    func activate(_ item: PauseItem) {
        if item != .resume { audio.play(.menuSelect) }
        switch item {
        case .resume: resume()
        case .settings: menu.pauseSettings = true
        case .restart: restart()
        case .leave: leaveGame()
        }
    }

    func activate(_ item: ResultsItem) {
        guard let result else { return }
        audio.play(.menuSelect)
        switch item {
        case .retry: play(result.session.mode)
        case .menu: showMenu()
        }
    }

    /// Cycles a choice, toggles a switch, or nudges a volume by `step` tenths.
    func adjust(_ item: SettingsItem, by step: Int) {
        var settings = profile.settings
        switch item {
        case .ghost:
            let styles = GhostStyle.allCases
            settings.ghost = styles[wrap(styles.firstIndex(of: settings.ghost) ?? 0, step, count: styles.count)]
        case .rotation: settings.rotation = settings.rotation.opposite
        case .controls: settings.showControls.toggle()
        case .music: settings.musicVolume = GameController.volume(settings.musicVolume, nudgedBy: step)
        case .effects: settings.effectsVolume = GameController.volume(settings.effectsVolume, nudgedBy: step)
        }
        guard settings != profile.settings else { return }
        profile.settings = settings
        applyVolumes()
        audio.play(item.isDiscrete ? .menuSelect : .menuMove)
    }

    /// Sets a volume from a click or drag, snapped to 5 % steps.
    func setVolume(_ item: SettingsItem, to value: Double) {
        let snapped = (min(max(value, 0), 1) * 20).rounded() / 20
        var settings = profile.settings
        switch item {
        case .music: settings.musicVolume = snapped
        case .effects: settings.effectsVolume = snapped
        case .ghost, .rotation, .controls: return
        }
        guard settings != profile.settings else { return }
        profile.settings = settings
        applyVolumes()
        audio.play(.menuMove)
    }

    private static func volume(_ value: Double, nudgedBy step: Int) -> Double {
        min(max(((value * 10).rounded() + Double(step)) / 10, 0), 1)
    }

    // MARK: - Keys

    private func handle(_ key: Key, on page: MenuPage) {
        switch (page, key) {
        case (.main, .up), (.main, .down):
            select { $0.main = wrap($0.main, key == .up ? -1 : 1, count: MainMenuItem.allCases.count) }
        case (.main, .returnKey), (.main, .space):
            activate(MainMenuItem.allCases[menu.main])

        case (.play, .up), (.play, .down):
            select { $0.mode = wrap($0.mode, key == .up ? -1 : 1, count: GameMode.allCases.count) }
        case (.play, .returnKey), (.play, .space):
            choose(GameMode.allCases[menu.mode])

        case (.leaderboards, .left), (.leaderboards, .right):
            let modes = GameMode.ranked
            let index = modes.firstIndex(of: menu.leaderboard) ?? 0
            select { $0.leaderboard = modes[wrap(index, key == .left ? -1 : 1, count: modes.count)] }

        case (.settings, .escape):
            back()
        case (.settings, _):
            handleSettings(key)

        case (.leaderboards, .returnKey), (.achievements, .returnKey), (.stats, .returnKey):
            back()
        case (.main, _):
            break
        case (_, .escape):
            back()
        default:
            break
        }
    }

    private func handleSettings(_ key: Key) {
        switch key {
        case .up, .down:
            select { $0.setting = wrap($0.setting, key == .up ? -1 : 1, count: SettingsItem.allCases.count) }
        case .left, .right:
            adjust(SettingsItem.allCases[menu.setting], by: key == .left ? -1 : 1)
        case .returnKey, .space:
            let item = SettingsItem.allCases[menu.setting]
            if item.isDiscrete { adjust(item, by: 1) }
        default:
            break
        }
    }

    private func handlePause(_ key: Key) {
        if menu.pauseSettings {
            if key == .escape { closePauseSettings() } else { handleSettings(key) }
            return
        }
        switch key {
        case .up, .down:
            select { $0.pause = wrap($0.pause, key == .up ? -1 : 1, count: PauseItem.allCases.count) }
        case .returnKey, .space:
            activate(PauseItem.allCases[menu.pause])
        case .escape, .p:
            resume()
        case .r:
            restart()
        default:
            break
        }
    }

    private func handleResults(_ key: Key) {
        switch key {
        case .left, .right, .up, .down:
            select { $0.results = wrap($0.results, key == .left || key == .up ? -1 : 1, count: ResultsItem.allCases.count) }
        case .returnKey, .space:
            activate(ResultsItem.allCases[menu.results])
        case .r:
            activate(.retry)
        case .escape:
            activate(.menu)
        default:
            break
        }
    }

    private func wrap(_ index: Int, _ delta: Int, count: Int) -> Int {
        (index + delta + count) % count
    }
}
