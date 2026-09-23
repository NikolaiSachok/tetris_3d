import TetrisCore

/// What the meta-game needs to know about one game, tallied from its events as it is played.
public struct SessionRecord: Sendable, Equatable {
    public let mode: GameMode
    public var score = 0
    public var lines = 0
    public var level = 1
    public var elapsed = 0.0
    /// Nil while the game is in progress, or when it was abandoned.
    public var outcome: GameOutcome?
    public var piecesPlaced = 0
    public var holds = 0
    public var tetrises = 0
    /// Line-clearing T-spins, minis included.
    public var tSpins = 0
    /// Most lines cleared by one full T-spin (2 for a T-spin double, 3 for a triple).
    public var bestTSpinLines = 0
    public var backToBacks = 0
    public var perfectClears = 0
    public var maxCombo = 0
    /// Highest board row a line clear removed; -1 before the first clear.
    public var highestClearedRow = -1

    public init(mode: GameMode) {
        self.mode = mode
    }

    /// Folds in one frame's events and the game's running totals.
    public mutating func record(_ events: [GameEvent], from game: Game) {
        score = game.score
        lines = game.lines
        level = game.level
        elapsed = game.elapsed
        outcome = game.outcome
        for event in events {
            switch event {
            case .locked:
                piecesPlaced += 1
            case .held:
                holds += 1
            case let .linesCleared(rows, _):
                highestClearedRow = max(highestClearedRow, rows.max() ?? -1)
            case let .scored(action):
                record(action)
            default:
                break
            }
        }
    }

    private mutating func record(_ action: ScoreAction) {
        if action.lines == 4 { tetrises += 1 }
        if action.tSpin != .none, action.lines > 0 { tSpins += 1 }
        if action.tSpin == .full { bestTSpinLines = max(bestTSpinLines, action.lines) }
        if action.backToBack { backToBacks += 1 }
        if action.perfectClear { perfectClears += 1 }
        if action.lines > 0 { maxCombo = max(maxCombo, action.combo) }
    }
}
