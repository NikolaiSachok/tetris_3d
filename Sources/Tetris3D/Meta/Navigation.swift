import Foundation
import MetaGame
import TetrisCore

enum MenuPage: Equatable {
    case main, play, leaderboards, achievements, stats, settings
}

enum MainMenuItem: CaseIterable {
    case play, leaderboards, achievements, stats, settings, quit

    var title: String {
        switch self {
        case .play: "PLAY"
        case .leaderboards: "LEADERBOARDS"
        case .achievements: "ACHIEVEMENTS"
        case .stats: "STATS"
        case .settings: "SETTINGS"
        case .quit: "QUIT"
        }
    }

    var page: MenuPage? {
        switch self {
        case .play: .play
        case .leaderboards: .leaderboards
        case .achievements: .achievements
        case .stats: .stats
        case .settings: .settings
        case .quit: nil
        }
    }
}

enum SettingsItem: CaseIterable {
    case ghost, rotation, controls, music, effects

    var title: String {
        switch self {
        case .ghost: "GHOST PIECE"
        case .rotation: "ROTATION"
        case .controls: "CONTROLS HINT"
        case .music: "MUSIC VOLUME"
        case .effects: "EFFECTS VOLUME"
        }
    }

    /// Switches and choices, which RETURN and clicks step through; volumes are sliders.
    var isDiscrete: Bool { self != .music && self != .effects }
}

extension RotationDirection {
    var title: String {
        switch self {
        case .counterclockwise: "LEFT"
        case .clockwise: "RIGHT"
        }
    }

    var opposite: RotationDirection { self == .clockwise ? .counterclockwise : .clockwise }
}

extension GhostStyle {
    var title: String {
        switch self {
        case .colored: "COLOR"
        case .gray: "GRAY"
        case .off: "OFF"
        }
    }
}

enum PauseItem: CaseIterable {
    case resume, restart, leave
}

enum ResultsItem: CaseIterable {
    case retry, menu

    var title: String {
        switch self {
        case .retry: "RETRY"
        case .menu: "MENU"
        }
    }
}

/// Keyboard selection on every menu-like screen.
struct MenuState: Equatable {
    var main = 0
    var mode = 0
    var leaderboard = GameMode.marathon
    var setting = 0
    var pause = 0
    var results = 0
    /// The leaderboard entry the last game set, highlighted until another game is played.
    var highlightedEntry: UUID?
}

extension GameMode {
    static let ranked = allCases.filter { $0.ranking != .unranked }

    var title: String { rawValue.uppercased() }

    var tagline: String {
        switch self {
        case .marathon: "Clear 150 lines as the speed climbs."
        case .sprint: "Clear 40 lines as fast as you can."
        case .ultra: "Score as much as you can in two minutes."
        case .dig: "Dig through ten rows of garbage."
        case .zen: "No clock, no pressure, no game over."
        }
    }

    var symbol: String {
        switch self {
        case .marathon: "figure.run"
        case .sprint: "hare.fill"
        case .ultra: "timer"
        case .dig: "hammer.fill"
        case .zen: "leaf.fill"
        }
    }

    /// The 3-2-1 countdown only matters when the clock is part of the challenge.
    var hasCountdown: Bool { self == .sprint || self == .ultra || self == .dig }
}

enum Format {
    /// `1:02.34`
    static func time(_ seconds: Double) -> String {
        let centis = Int((max(seconds, 0) * 100).rounded(.down))
        return String(format: "%d:%02d.%02d", centis / 6000, centis / 100 % 60, centis % 100)
    }

    /// `12:05`
    static func minutes(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// `2h 05m`, `12m 30s`
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total >= 3600 { return String(format: "%dh %02dm", total / 3600, total / 60 % 60) }
        return String(format: "%dm %02ds", total / 60, total % 60)
    }
}
