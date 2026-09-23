import Foundation
import TetrisCore

public struct LifetimeStats: Codable, Equatable, Sendable {
    public var gamesPlayed: [GameMode: Int] = [:]
    public var lines = 0
    public var piecesPlaced = 0
    public var tetrises = 0
    public var tSpins = 0
    public var bestTSpinLines = 0
    public var perfectClears = 0
    public var bestCombo = 0
    /// Seconds.
    public var playTime = 0.0

    public init() {}

    public var totalGames: Int { gamesPlayed.values.reduce(0, +) }

    public mutating func add(_ session: SessionRecord) {
        gamesPlayed[session.mode, default: 0] += 1
        lines += session.lines
        piecesPlaced += session.piecesPlaced
        tetrises += session.tetrises
        tSpins += session.tSpins
        bestTSpinLines = max(bestTSpinLines, session.bestTSpinLines)
        perfectClears += session.perfectClears
        bestCombo = max(bestCombo, session.maxCombo)
        playTime += session.elapsed
    }
}

/// How the landing-position hint for the falling piece is drawn.
public enum GhostStyle: String, Codable, CaseIterable, Sendable {
    case colored, gray, off
}

public struct Settings: Codable, Equatable, Sendable {
    public var ghost = GhostStyle.colored
    public var showControls = true
    /// 0...1
    public var musicVolume = 0.7
    /// 0...1
    public var effectsVolume = 0.8

    public init() {}

    /// Missing keys keep their defaults, so adding or renaming a setting never discards a profile.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        ghost = try container.decodeIfPresent(GhostStyle.self, forKey: .ghost) ?? defaults.ghost
        showControls = try container.decodeIfPresent(Bool.self, forKey: .showControls) ?? defaults.showControls
        musicVolume = try container.decodeIfPresent(Double.self, forKey: .musicVolume) ?? defaults.musicVolume
        effectsVolume = try container.decodeIfPresent(Double.self, forKey: .effectsVolume) ?? defaults.effectsVolume
    }
}

/// How a finished game changed the profile, for the result screen.
public struct GameReport: Sendable, Equatable {
    /// 1-based leaderboard position, nil when the game did not place.
    public var rank: Int?
    public var entryID: UUID?
    public var newAchievements: [Achievement] = []
}

/// Everything the player keeps between launches.
public struct Profile: Codable, Equatable, Sendable {
    public var stats = LifetimeStats()
    public var leaderboards: [GameMode: Leaderboard] = [:]
    /// Unlock dates.
    public var achievements: [Achievement: Date] = [:]
    public var settings = Settings()

    public init() {}

    public func leaderboard(_ mode: GameMode) -> Leaderboard { leaderboards[mode] ?? Leaderboard() }

    public func progress(of achievement: Achievement) -> Achievement.Progress {
        achievements[achievement] != nil
            ? Achievement.Progress(current: 1, target: 1)
            : achievement.progress(stats: stats, session: nil)
    }

    /// Unlocks what a game in progress has already earned. Returns the new unlocks.
    public mutating func unlockAchievements(during session: SessionRecord, on date: Date) -> [Achievement] {
        var preview = stats
        preview.add(session)
        return unlock(stats: preview, session: session, on: date)
    }

    /// Folds a game that ended (finished or abandoned) into stats, leaderboard and achievements.
    public mutating func record(_ session: SessionRecord, on date: Date) -> GameReport {
        stats.add(session)
        var report = GameReport()
        if Leaderboard.accepts(session) {
            let entry = LeaderboardEntry(session, date: date)
            var board = leaderboard(session.mode)
            report.rank = board.submit(entry, ranking: session.mode.ranking)
            report.entryID = report.rank.map { _ in entry.id }
            leaderboards[session.mode] = board
        }
        report.newAchievements = unlock(stats: stats, session: session, on: date)
        return report
    }

    private mutating func unlock(stats: LifetimeStats, session: SessionRecord, on date: Date) -> [Achievement] {
        let earned = Achievement.allCases.filter {
            achievements[$0] == nil && $0.progress(stats: stats, session: session).isComplete
        }
        for achievement in earned { achievements[achievement] = date }
        return earned
    }
}
