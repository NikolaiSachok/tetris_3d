public enum TSpin: Sendable, Equatable {
    case none, mini, full
}

/// One scoring lock: what was cleared and what it was worth. Emitted for every line clear and every T-spin.
public struct ScoreAction: Sendable, Equatable {
    public var lines: Int
    public var tSpin: TSpin
    /// Consecutive line-clearing locks before this one (0 for the first clear of a chain).
    public var combo: Int
    /// A difficult clear that directly followed another difficult clear.
    public var backToBack: Bool
    public var perfectClear: Bool
    public var points: Int

    public init(lines: Int, tSpin: TSpin = .none, combo: Int = 0, backToBack: Bool = false,
                perfectClear: Bool = false, points: Int) {
        self.lines = lines
        self.tSpin = tSpin
        self.combo = combo
        self.backToBack = backToBack
        self.perfectClear = perfectClear
        self.points = points
    }

    /// Tetrises and line-clearing T-spins: the clears that build and keep a back-to-back chain.
    public var isDifficult: Bool { Scoring.isDifficult(lines: lines, tSpin: tSpin) }
}

/// Guideline scoring tables.
public enum Scoring {
    static let lineClear = [0, 100, 300, 500, 800]
    static let tSpinMini = [100, 200, 400]
    static let tSpinFull = [400, 800, 1200, 1600]
    static let perfectClearBonus = [0, 800, 1200, 1800, 2000]
    static let backToBackTetrisPerfectClearBonus = 3200

    public static func isDifficult(lines: Int, tSpin: TSpin) -> Bool {
        lines == 4 || (lines > 0 && tSpin != .none)
    }

    /// Points for a lock, with `combo` as the chain length before this clear (ignored when no lines clear).
    public static func points(lines: Int, tSpin: TSpin, level: Int, backToBack: Bool, combo: Int,
                              perfectClear: Bool) -> Int {
        let table = switch tSpin {
        case .none: lineClear
        case .mini: tSpinMini
        case .full: tSpinFull
        }
        var points = table[min(lines, table.count - 1)] * level
        if backToBack { points = points * 3 / 2 }
        if lines > 0 { points += 50 * combo * level }
        if perfectClear {
            let bonus = backToBack && lines == 4 ? backToBackTetrisPerfectClearBonus : perfectClearBonus[min(lines, 4)]
            points += bonus * level
        }
        return points
    }
}
