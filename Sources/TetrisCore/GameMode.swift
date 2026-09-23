/// The rule set a game is played under: its goal, its clock and how it ends.
public enum GameMode: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    /// Level up every 10 lines; clear 150 lines to finish.
    case marathon
    /// Clear 40 lines as fast as possible.
    case sprint
    /// Score as much as possible in two minutes.
    case ultra
    /// Dig through 10 rows of garbage as fast as possible.
    case dig
    /// No speed-up and no game over: topping out clears the bottom of the stack instead.
    case zen

    /// How a finished game is ranked on the leaderboard.
    public enum Ranking: Sendable {
        case highestScore, fastestTime, unranked
    }

    public var lineGoal: Int? {
        switch self {
        case .marathon: 150
        case .sprint: 40
        default: nil
        }
    }

    /// Seconds until the game ends by itself.
    public var timeLimit: Double? { self == .ultra ? 120 : nil }

    public var garbageRows: Int { self == .dig ? 10 : 0 }

    public var levelsUp: Bool { self == .marathon }

    /// Whether topping out trims the stack instead of ending the game.
    public var forgivesTopOut: Bool { self == .zen }

    public var ranking: Ranking {
        switch self {
        case .marathon, .ultra: .highestScore
        case .sprint, .dig: .fastestTime
        case .zen: .unranked
        }
    }
}

public enum GameOutcome: Sendable, Equatable {
    /// The stack reached the top.
    case toppedOut
    /// The mode's goal was reached (lines cleared, garbage dug out, or the clock ran out in Ultra).
    case completed
}
