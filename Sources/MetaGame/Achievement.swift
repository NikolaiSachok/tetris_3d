import TetrisCore

public enum Achievement: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    case firstLine, tetris, tSpin, tSpinDouble, tSpinTriple, backToBack
    case combo5, combo10, perfectClear
    case level10, level15, marathon
    case sprint, sprintUnder60, ultra20k, dig, zen100
    case lines1000, tetrises100, explorer, regular
    case closeCall, purist

    public enum Tier: Sendable {
        case bronze, silver, gold
    }

    public struct Progress: Sendable, Equatable {
        public var current: Int
        public var target: Int

        public var isComplete: Bool { current >= target }
        public var fraction: Double { min(Double(current) / Double(target), 1) }
    }

    public var title: String {
        switch self {
        case .firstLine: "Warming Up"
        case .tetris: "Four Wide"
        case .tSpin: "Twist"
        case .tSpinDouble: "Double Twist"
        case .tSpinTriple: "Triple Threat"
        case .backToBack: "Encore"
        case .combo5: "Chain Reaction"
        case .combo10: "Unbroken"
        case .perfectClear: "Spotless"
        case .level10: "Climber"
        case .level15: "Summit"
        case .marathon: "Marathoner"
        case .sprint: "Off the Blocks"
        case .sprintUnder60: "Blink"
        case .ultra20k: "High Roller"
        case .dig: "Excavator"
        case .zen100: "Inner Peace"
        case .lines1000: "Line Worker"
        case .tetrises100: "Tetris Master"
        case .explorer: "Explorer"
        case .regular: "Regular"
        case .closeCall: "Close Call"
        case .purist: "Purist"
        }
    }

    public var detail: String {
        switch self {
        case .firstLine: "Clear your first line."
        case .tetris: "Clear four lines at once."
        case .tSpin: "Clear lines with a T-spin."
        case .tSpinDouble: "Land a T-spin double."
        case .tSpinTriple: "Land a T-spin triple."
        case .backToBack: "Chain two Tetrises or T-spins back to back."
        case .combo5: "Clear lines with five pieces in a row."
        case .combo10: "Reach a 10 combo."
        case .perfectClear: "Leave the board completely empty."
        case .level10: "Reach level 10 in Marathon."
        case .level15: "Reach level 15 in Marathon."
        case .marathon: "Clear all 150 lines of Marathon."
        case .sprint: "Finish a Sprint."
        case .sprintUnder60: "Finish a Sprint in under 60 seconds."
        case .ultra20k: "Score 20,000 points in Ultra."
        case .dig: "Dig through all the garbage."
        case .zen100: "Clear 100 lines in one Zen session."
        case .lines1000: "Clear 1,000 lines in total."
        case .tetrises100: "Clear 100 Tetrises in total."
        case .explorer: "Play every mode."
        case .regular: "Play 50 games."
        case .closeCall: "Clear a line in the top four rows of the well."
        case .purist: "Finish a Sprint without using hold."
        }
    }

    public var tier: Tier {
        switch self {
        case .firstLine, .tetris, .tSpin, .sprint, .dig, .explorer: .bronze
        case .tSpinDouble, .backToBack, .combo5, .level10, .ultra20k, .zen100, .lines1000, .regular, .closeCall: .silver
        case .tSpinTriple, .combo10, .perfectClear, .level15, .marathon, .sprintUnder60, .tetrises100, .purist: .gold
        }
    }

    /// Hidden achievements show only a placeholder until they are unlocked.
    public var isSecret: Bool { self == .closeCall || self == .purist }

    /// How far along the player is. `stats` must already include `session` when one is given.
    public func progress(stats: LifetimeStats, session: SessionRecord?) -> Progress {
        func flag(_ condition: Bool) -> Progress { Progress(current: condition ? 1 : 0, target: 1) }
        func completed(_ mode: GameMode) -> Bool { session?.mode == mode && session?.outcome == .completed }
        let marathonLevel = session?.mode == .marathon ? session?.level ?? 0 : 0

        switch self {
        case .firstLine: return flag(stats.lines >= 1)
        case .tetris: return flag(stats.tetrises >= 1)
        case .tSpin: return flag(stats.tSpins >= 1)
        case .tSpinDouble: return flag(stats.bestTSpinLines >= 2)
        case .tSpinTriple: return flag(stats.bestTSpinLines >= 3)
        case .backToBack: return flag((session?.backToBacks ?? 0) > 0)
        case .combo5: return flag(stats.bestCombo >= 5)
        case .combo10: return flag(stats.bestCombo >= 10)
        case .perfectClear: return flag(stats.perfectClears >= 1)
        case .level10: return flag(marathonLevel >= 10)
        case .level15: return flag(marathonLevel >= 15)
        case .marathon: return flag(completed(.marathon))
        case .sprint: return flag(completed(.sprint))
        case .sprintUnder60: return flag(completed(.sprint) && (session?.elapsed ?? .infinity) < 60)
        case .ultra20k: return flag(session?.mode == .ultra && (session?.score ?? 0) >= 20_000)
        case .dig: return flag(completed(.dig))
        case .zen100: return flag(session?.mode == .zen && (session?.lines ?? 0) >= 100)
        case .lines1000: return Progress(current: stats.lines, target: 1000)
        case .tetrises100: return Progress(current: stats.tetrises, target: 100)
        case .explorer: return Progress(current: stats.gamesPlayed.values.filter { $0 > 0 }.count,
                                        target: GameMode.allCases.count)
        case .regular: return Progress(current: stats.totalGames, target: 50)
        case .closeCall: return flag((session?.highestClearedRow ?? -1) >= Game.visibleHeight - 4)
        case .purist: return flag(completed(.sprint) && session?.holds == 0)
        }
    }
}
