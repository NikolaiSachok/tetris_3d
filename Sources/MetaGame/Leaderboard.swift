import Foundation
import TetrisCore

public struct LeaderboardEntry: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var score: Int
    public var lines: Int
    public var level: Int
    /// Seconds the game took.
    public var time: Double
    public var date: Date

    public init(score: Int, lines: Int, level: Int, time: Double, date: Date) {
        self.score = score
        self.lines = lines
        self.level = level
        self.time = time
        self.date = date
    }

    public init(_ session: SessionRecord, date: Date) {
        self.init(score: session.score, lines: session.lines, level: session.level, time: session.elapsed, date: date)
    }
}

/// A mode's top ten, best first.
public struct Leaderboard: Codable, Equatable, Sendable {
    public static let capacity = 10

    public private(set) var entries: [LeaderboardEntry] = []

    public init(entries: [LeaderboardEntry] = []) {
        self.entries = entries
    }

    public var best: LeaderboardEntry? { entries.first }

    /// Whether a session qualifies for a leaderboard at all: time trials only count when the goal was reached.
    public static func accepts(_ session: SessionRecord) -> Bool {
        switch session.mode.ranking {
        case .highestScore: session.outcome != nil && session.score > 0
        case .fastestTime: session.outcome == .completed
        case .unranked: false
        }
    }

    /// Inserts the entry if it makes the top ten and returns its 1-based rank. Ties go to the older entry.
    public mutating func submit(_ entry: LeaderboardEntry, ranking: GameMode.Ranking) -> Int? {
        let index = entries.firstIndex { Leaderboard.ranks(entry, above: $0, by: ranking) } ?? entries.count
        guard index < Leaderboard.capacity else { return nil }
        entries.insert(entry, at: index)
        entries = Array(entries.prefix(Leaderboard.capacity))
        return index + 1
    }

    static func ranks(_ a: LeaderboardEntry, above b: LeaderboardEntry, by ranking: GameMode.Ranking) -> Bool {
        switch ranking {
        case .highestScore: a.score > b.score
        case .fastestTime: a.time < b.time
        case .unranked: false
        }
    }
}
