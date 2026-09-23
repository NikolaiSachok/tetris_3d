import AppKit
import MetaGame
import Observation
import simd
import TetrisCore

/// Owns the session: screens, keyboard input, attract-mode autopilot, the running game and the values the HUD shows.
@MainActor
@Observable
final class GameController {
    enum Screen: Equatable {
        case menu(MenuPage)
        /// 3-2-1-GO before a timed game starts.
        case countdown
        case playing
        case paused
        case results
    }

    /// A finished game, as the result screen shows it.
    struct Result {
        let session: SessionRecord
        let report: GameReport
        /// The mode's best before this game.
        let previousBest: LeaderboardEntry?
    }

    static let countdownLength = 3.0
    /// How long "GO" stays up once play has started.
    static let goDuration = 0.7
    /// How long the board stays on screen after the last move before the result screen appears.
    static let resultsDelay = 1.4

    private(set) var screen = Screen.menu(.main)
    var menu = MenuState()
    private(set) var hud = HUDStats()
    private(set) var result: Result?
    private(set) var layout = HUDLayout()
    /// 3, 2, 1, then 0 for "GO"; nil when no countdown is showing.
    private(set) var countdownStep: Int?
    let profile: ProfileModel
    let feedback = Feedback()
    @ObservationIgnored let audio = AudioEngine()

    @ObservationIgnored private(set) var game = Game(mode: .zen)
    @ObservationIgnored private(set) var scene = GameScene()
    @ObservationIgnored private var session: SessionRecord?
    /// Seconds until play starts, running on to `-goDuration` while "GO" shows.
    @ObservationIgnored private var countdownClock = -GameController.goDuration
    @ObservationIgnored private var resultsTimer: Double?
    @ObservationIgnored private var pilotTarget: (rotation: Int, x: Int)?
    @ObservationIgnored private var pilotTimer = 0.0
    @ObservationIgnored private var shiftDown = false
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?

    init(profile: ProfileModel) {
        self.profile = profile
        applyVolumes()
        audio.playMusic(.menu)
    }

    var ghostStyle: GhostStyle { session != nil && !game.isFinished ? profile.settings.ghost : .off }

    // MARK: - Lifecycle

    func start() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let input = KeyInput(event)
            return MainActor.assumeIsolated { self.handle(input) } ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }
    }

    func tick(dt: Float) {
        guard screen != .paused else { return }
        let seconds = Double(dt)
        feedback.update(dt: seconds)
        advanceCountdown(seconds)

        switch screen {
        case .menu:
            runAutopilot(dt: seconds)
            game.update(dt: seconds)
        case .playing, .results:
            #if DEBUG
            if DebugLaunch.autoplay, screen == .playing { runAutopilot(dt: seconds) }
            #endif
            game.update(dt: seconds)
        case .countdown, .paused:
            break
        }

        let events = game.drainEvents()
        scene.update(dt: dt, game: game, events: events)
        if session != nil {
            playSounds(for: events)
            record(events)
        }
        audio.setDanger(session != nil ? scene.danger : 0)
        let stats = HUDStats(game)
        if stats != hud { hud = stats }

        if let timer = resultsTimer {
            resultsTimer = timer - seconds
            if timer - seconds <= 0 { showResults() }
        }
    }

    func updateLayout(project: (SIMD3<Float>) -> CGPoint) {
        let origin = project(.zero)
        let unit = abs(project([1, 0, 0]).x - origin.x)
        layout = HUDLayout(
            hold: project([Layout.holdX, Layout.previewTopY + 2.2, 0]),
            next: project([Layout.nextX, Layout.previewTopY + 2.2, 0]),
            stats: project([Layout.holdX, Layout.previewTopY - 4.2, 0]),
            controls: project([Layout.holdX, -10.2, 0]),
            callout: project([Layout.nextX, -6.6, 0]),
            boardCenter: project([0, 1.5, 0]),
            toast: project([0, -12, 0]),
            unit: unit
        )
    }

    // MARK: - Game flow

    func play(_ mode: GameMode) {
        closeSession()
        game = Game(mode: mode)
        scene.reset()
        feedback.clearCallouts()
        session = SessionRecord(mode: mode)
        result = nil
        resultsTimer = nil
        pilotTarget = nil
        menu.pause = 0
        menu.results = 0
        menu.highlightedEntry = nil
        countdownClock = mode.hasCountdown ? GameController.countdownLength : -GameController.goDuration
        countdownStep = nil
        screen = mode.hasCountdown ? .countdown : .playing
        hud = HUDStats(game)
        audio.setPaused(false)
        audio.setIntensity(level: game.level)
        // Timed modes start their music on "GO".
        if mode.hasCountdown { audio.stopMusic() } else { audio.playMusic(.game) }
    }

    func pause() {
        guard screen == .playing || screen == .countdown, resultsTimer == nil else { return }
        menu.pause = 0
        screen = .paused
        audio.setPaused(true)
        audio.play(.pause)
    }

    func resume() {
        guard screen == .paused else { return }
        screen = countdownClock > 0 ? .countdown : .playing
        audio.setPaused(false)
        audio.play(.pause)
    }

    func restart() {
        play(game.mode)
    }

    /// Leaves the game from the pause menu. Zen has no ending of its own, so leaving it is how a session finishes.
    func leaveGame() {
        if game.mode == .zen {
            showResults()
        } else {
            showMenu()
        }
    }

    func showMenu(_ page: MenuPage = .main) {
        if case .menu = screen {} else {
            closeSession()
            game = Game(mode: .zen)
            scene.reset()
            feedback.clearCallouts()
        }
        result = nil
        resultsTimer = nil
        countdownClock = -GameController.goDuration
        countdownStep = nil
        screen = .menu(page)
        audio.setPaused(false)
        audio.playMusic(.menu)
    }

    func quit() {
        closeSession()
        NSApplication.shared.terminate(nil)
    }

    /// Records a game that is left before its result screen, so its lines, playtime and any finish still count.
    private func closeSession() {
        if let session, session.piecesPlaced > 0 { _ = profile.record(session) }
        session = nil
    }

    private func showResults() {
        resultsTimer = nil
        guard let session else { return }
        let previousBest = profile.profile.leaderboard(session.mode).best
        let report = profile.record(session)
        result = Result(session: session, report: report, previousBest: previousBest)
        self.session = nil
        menu.results = 0
        menu.leaderboard = session.mode.ranking == .unranked ? menu.leaderboard : session.mode
        menu.highlightedEntry = report.entryID
        feedback.clearCallouts()
        screen = .results
        audio.setPaused(false)
        audio.playMusic(.menu)
    }

    private func record(_ events: [GameEvent]) {
        guard var session else { return }
        session.record(events, from: game)
        self.session = session

        for event in events {
            switch event {
            case let .scored(action): feedback.post(action)
            case let .levelUp(level): feedback.postLevel(level)
            case let .finished(outcome):
                feedback.postFinish(game.mode, outcome)
                resultsTimer = GameController.resultsDelay
            default: break
            }
        }
        // Only locks change what has been earned. The result screen lists a finished game's unlocks instead.
        if !game.isFinished, events.contains(where: { if case .locked = $0 { true } else { false } }) {
            for achievement in profile.unlockAchievements(during: session) {
                feedback.post(achievement)
                audio.play(.achievement)
            }
        }
    }

    private func advanceCountdown(_ seconds: Double) {
        guard countdownClock > -GameController.goDuration, screen == .countdown || screen == .playing else { return }
        countdownClock -= seconds
        if screen == .countdown, countdownClock <= 0 { screen = .playing }
        let step: Int? = if countdownClock > 0 {
            Int(countdownClock.rounded(.up))
        } else {
            countdownClock > -GameController.goDuration ? 0 : nil
        }
        guard step != countdownStep else { return }
        countdownStep = step
        switch step {
        case 0:
            audio.play(.go)
            audio.playMusic(.game)
        case .some:
            audio.play(.countdown)
        case nil:
            break
        }
    }

    // MARK: - Attract mode

    private func runAutopilot(dt: Double) {
        guard let piece = game.active else {
            pilotTarget = nil
            return
        }
        if pilotTarget == nil { pilotTarget = AutoPilot.bestTarget(for: game) }
        pilotTimer += dt
        guard pilotTimer >= 0.09, let target = pilotTarget else { return }
        pilotTimer = 0

        if piece.rotation != target.rotation {
            game.press(.rotateCW)
        } else if piece.origin.x < target.x {
            game.press(.right)
            game.release(.right)
        } else if piece.origin.x > target.x {
            game.press(.left)
            game.release(.left)
        } else {
            game.press(.hardDrop)
            pilotTarget = nil
        }
    }

    // MARK: - Keyboard

    enum Key: UInt16 {
        case returnKey = 36, space = 49, escape = 53
        case left = 123, right = 124, down = 125, up = 126
        case z = 6, x = 7, c = 8, p = 35, r = 15
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: KeyInput) -> Bool {
        if event.type == .flagsChanged {
            let down = event.modifierFlags.contains(.shift)
            if down, !shiftDown, screen == .playing { game.press(.hold) }
            shiftDown = down
            return false
        }
        if event.modifierFlags.contains(.command) { return false }
        guard let key = Key(rawValue: event.keyCode) else { return false }
        let isDown = event.type == .keyDown

        switch screen {
        case .playing, .countdown:
            handleGameplay(key, isDown: isDown, isRepeat: event.isARepeat)
        default:
            if isDown { handleMenu(key) }
        }
        return true
    }

    private func handleGameplay(_ key: Key, isDown: Bool, isRepeat: Bool) {
        if isDown, key == .p || key == .escape {
            pause()
            return
        }
        if isDown, key == .r {
            restart()
            return
        }
        guard screen == .playing, let action = action(for: key) else { return }
        if isDown {
            // Movement keys run their own DAS; ignore the OS key repeat.
            guard !isRepeat else { return }
            game.press(action)
            if action == .softDrop, !game.isFinished { audio.play(.softDrop) }
        } else {
            game.release(action)
        }
    }

    private func action(for key: Key) -> GameAction? {
        switch key {
        case .left: .left
        case .right: .right
        case .down: .softDrop
        case .space: .hardDrop
        case .up, .x: .rotateCW
        case .z: .rotateCCW
        case .c: .hold
        default: nil
        }
    }
}

/// The parts of an `NSEvent` the controller needs, captured so they can cross into main-actor code.
private struct KeyInput: Sendable {
    let type: NSEvent.EventType
    let keyCode: UInt16
    let modifierFlags: NSEvent.ModifierFlags
    let isARepeat: Bool

    init(_ event: NSEvent) {
        type = event.type
        modifierFlags = event.modifierFlags
        keyCode = event.type == .flagsChanged ? 0 : event.keyCode
        isARepeat = event.type == .keyDown ? event.isARepeat : false
    }
}

/// What the in-game HUD shows, refreshed every frame but only published when it changes.
struct HUDStats: Equatable {
    var mode = GameMode.zen
    var score = 0
    var lines = 0
    var level = 1
    /// Hundredths of a second, so the clock redraws at most 100 times a second.
    var centiseconds = 0
    var linesRemaining: Int?
    var remainingCentiseconds: Int?
    var garbageRemaining = 0

    init() {}

    init(_ game: Game) {
        mode = game.mode
        score = game.score
        lines = game.lines
        level = game.level
        centiseconds = Int(game.elapsed * 100)
        linesRemaining = game.linesRemaining
        remainingCentiseconds = game.timeRemaining.map { Int(($0 * 100).rounded(.up)) }
        garbageRemaining = game.garbageRemaining
    }
}

/// Screen positions (in points) of HUD anchors, projected from the 3D layout.
struct HUDLayout: Equatable {
    var hold = CGPoint.zero
    var next = CGPoint.zero
    var stats = CGPoint.zero
    var controls = CGPoint.zero
    /// Scoring callouts: the free space under the next queue.
    var callout = CGPoint.zero
    /// Banners and the countdown: the middle of the well, slightly above centre.
    var boardCenter = CGPoint.zero
    /// Achievement toasts: under the well.
    var toast = CGPoint.zero
    /// Points per world unit at the board's depth.
    var unit: CGFloat = 20
}
