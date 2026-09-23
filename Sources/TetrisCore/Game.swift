import Foundation

public enum GameAction: Sendable {
    case left, right, softDrop, hardDrop, rotateCW, rotateCCW, hold
}

/// What occupies a board cell.
public enum Block: Hashable, Sendable {
    case piece(PieceKind)
    /// Pre-filled rows in Dig mode.
    case garbage
}

public struct ClearedBlock: Sendable, Equatable {
    public var cell: Cell
    public var block: Block
}

/// Things that happened during a step, for presentation (animation, particles, sound).
public enum GameEvent: Sendable, Equatable {
    case moved
    case rotated
    case hardDropped(kind: PieceKind, from: [Cell], to: [Cell])
    case locked(kind: PieceKind, cells: [Cell])
    case linesCleared(rows: [Int], blocks: [ClearedBlock])
    /// Zen mode topped out: these bottom rows are being removed instead of ending the game.
    case stackTrimmed(rows: [Int], blocks: [ClearedBlock])
    /// Cleared (or trimmed) rows were removed; everything above them fell down.
    case rowsCollapsed(rows: [Int])
    case scored(ScoreAction)
    case held
    case levelUp(Int)
    case finished(GameOutcome)
}

/// Guideline Tetris rules: SRS rotation, 7-bag, hold, ghost, lock delay with move reset, DAS/ARR,
/// T-spins, combos, back-to-back and perfect clears, played under a `GameMode`.
public struct Game: Sendable {
    public static let width = 10
    public static let visibleHeight = 20
    public static let height = 40
    public static let clearDuration = 0.42

    static let das = 0.15
    static let arr = 0.033
    static let lockDelay = 0.5
    static let maxLockResets = 15
    /// Zen mode trims the stack down to this height when it tops out.
    static let zenRescueHeight = 10

    public let mode: GameMode
    /// `board[y][x]`, row 0 at the bottom.
    public internal(set) var board: [[Block?]]
    public internal(set) var active: ActivePiece?
    public private(set) var held: PieceKind?
    public private(set) var canHold = true
    public private(set) var nextQueue: [PieceKind] = []
    public private(set) var score = 0
    public internal(set) var lines = 0
    public private(set) var level = 1
    public private(set) var clearingRows: [Int] = []
    public private(set) var clearTimer = 0.0
    /// Seconds of play so far, frozen once the game finishes.
    public private(set) var elapsed = 0.0
    public private(set) var outcome: GameOutcome?
    /// Rows that still contain garbage (Dig mode).
    public internal(set) var garbageRemaining = 0
    /// Length of the current clear chain (-1 when the last lock cleared nothing).
    public private(set) var combo = -1
    /// The last line clear was difficult, so the next difficult one earns the back-to-back bonus.
    public private(set) var backToBackReady = false

    private var bag: PieceBag
    private var events: [GameEvent] = []
    private var fallTimer = 0.0
    private var lockTimer = 0.0
    private var lockResets = 0
    private var lowestRow = Int.max
    private var leftHeld = false
    private var rightHeld = false
    private var shiftDirection = 0
    private var shiftTimer = 0.0
    private var shiftCharged = false
    private var softDropHeld = false
    /// Kick index of the rotation that last moved the active piece, nil once it has moved otherwise.
    private var lastRotationKick: Int?
    /// A piece that could not spawn because Zen mode is trimming the stack; it spawns after the trim.
    private var pendingSpawn: PieceKind?

    public init(mode: GameMode = .marathon, seed: UInt64 = .random(in: .min ... .max)) {
        self.mode = mode
        board = Array(repeating: Array(repeating: nil, count: Game.width), count: Game.height)
        bag = PieceBag(seed: seed)
        nextQueue = (0..<5).map { _ in bag.next() }
        fillGarbage(rows: mode.garbageRows, seed: seed)
        spawn(takeNext())
    }

    // MARK: - Queries

    public var isFinished: Bool { outcome != nil }

    public var clearProgress: Double { min(clearTimer / Game.clearDuration, 1) }

    /// Lines still to clear in modes with a line goal.
    public var linesRemaining: Int? { mode.lineGoal.map { max($0 - lines, 0) } }

    /// Seconds left in timed modes.
    public var timeRemaining: Double? { mode.timeLimit.map { max($0 - elapsed, 0) } }

    public var ghost: ActivePiece? {
        guard var piece = active else { return nil }
        while fits(piece, offset: Cell(0, -1)) { piece.origin.y -= 1 }
        return piece
    }

    /// Seconds per row at the current level (guideline curve).
    public var gravityInterval: Double {
        pow(0.8 - Double(level - 1) * 0.007, Double(level - 1))
    }

    public func isOccupied(_ cell: Cell) -> Bool {
        guard cell.x >= 0, cell.x < Game.width, cell.y >= 0 else { return true }
        guard cell.y < Game.height else { return false }
        return board[cell.y][cell.x] != nil
    }

    public func fits(_ piece: ActivePiece, offset: Cell = Cell(0, 0)) -> Bool {
        piece.cells.allSatisfy { !isOccupied($0 + offset) }
    }

    public mutating func drainEvents() -> [GameEvent] {
        defer { events.removeAll() }
        return events
    }

    // MARK: - Input

    public mutating func press(_ action: GameAction) {
        guard !isFinished else { return }
        switch action {
        case .left:
            leftHeld = true
            beginShift(-1)
        case .right:
            rightHeld = true
            beginShift(1)
        case .softDrop:
            softDropHeld = true
            fallTimer = max(fallTimer, softDropInterval)
        case .hardDrop:
            hardDrop()
        case .rotateCW:
            rotate(by: 1)
        case .rotateCCW:
            rotate(by: -1)
        case .hold:
            hold()
        }
    }

    public mutating func release(_ action: GameAction) {
        switch action {
        case .left:
            leftHeld = false
            shiftDirection = rightHeld ? 1 : 0
            shiftTimer = 0
            shiftCharged = false
        case .right:
            rightHeld = false
            shiftDirection = leftHeld ? -1 : 0
            shiftTimer = 0
            shiftCharged = false
        case .softDrop:
            softDropHeld = false
        default:
            break
        }
    }

    // MARK: - Simulation

    public mutating func update(dt: Double) {
        if !isFinished {
            elapsed += dt
            if let limit = mode.timeLimit, elapsed >= limit {
                elapsed = limit
                finish(.completed)
            }
        }

        // A clear animation still plays out after the game finished on it.
        if !clearingRows.isEmpty {
            clearTimer += dt
            if clearTimer >= Game.clearDuration {
                collapseClearedRows()
                if !isFinished { spawn(pendingSpawn.take() ?? takeNext()) }
            }
            return
        }
        guard !isFinished, active != nil else { return }

        autoShift(dt: dt)

        fallTimer += dt
        let interval = softDropHeld ? softDropInterval : gravityInterval
        while fallTimer >= interval {
            fallTimer -= interval
            guard step(Cell(0, -1)) else {
                fallTimer = 0
                break
            }
            if softDropHeld { score += 1 }
        }

        guard let piece = active else { return }
        if fits(piece, offset: Cell(0, -1)) {
            lockTimer = 0
        } else {
            lockTimer += dt
            if lockTimer >= Game.lockDelay { lock() }
        }
    }

    // MARK: - Private

    private var softDropInterval: Double { min(gravityInterval / 20, 0.05) }

    private mutating func takeNext() -> PieceKind {
        nextQueue.append(bag.next())
        return nextQueue.removeFirst()
    }

    private mutating func spawn(_ kind: PieceKind) {
        let piece = ActivePiece.spawn(kind)
        fallTimer = 0
        lockTimer = 0
        lockResets = 0
        lowestRow = piece.origin.y
        lastRotationKick = nil
        guard fits(piece) else {
            active = nil
            topOut(pending: kind)
            return
        }
        active = piece
    }

    private mutating func finish(_ result: GameOutcome) {
        outcome = result
        events.append(.finished(result))
    }

    /// Ends the game, or in Zen mode clears the bottom of the stack and carries on.
    private mutating func topOut(pending kind: PieceKind?) {
        guard mode.forgivesTopOut else {
            finish(.toppedOut)
            return
        }
        let stackHeight = (board.lastIndex { row in row.contains { $0 != nil } } ?? -1) + 1
        let rows = Array(0..<max(stackHeight - Game.zenRescueHeight, 1))
        pendingSpawn = kind
        clearingRows = rows
        clearTimer = 0
        events.append(.stackTrimmed(rows: rows, blocks: blocks(in: rows)))
    }

    private func blocks(in rows: [Int]) -> [ClearedBlock] {
        rows.flatMap { y in
            (0..<Game.width).compactMap { x in board[y][x].map { ClearedBlock(cell: Cell(x, y), block: $0) } }
        }
    }

    /// Dig mode: garbage rows at the bottom, each with one hole that never lines up with the hole below it.
    private mutating func fillGarbage(rows: Int, seed: UInt64) {
        var generator = SplitMix64(seed: ~seed)
        var previousHole = -1
        for y in 0..<rows {
            var hole: Int
            repeat {
                hole = Int.random(in: 0..<Game.width, using: &generator)
            } while hole == previousHole
            previousHole = hole
            for x in 0..<Game.width where x != hole { board[y][x] = .garbage }
        }
        garbageRemaining = rows
    }

    private mutating func beginShift(_ direction: Int) {
        shiftDirection = direction
        shiftTimer = 0
        shiftCharged = false
        if step(Cell(direction, 0)) { events.append(.moved) }
    }

    private mutating func autoShift(dt: Double) {
        guard shiftDirection != 0 else { return }
        shiftTimer += dt
        if !shiftCharged {
            guard shiftTimer >= Game.das else { return }
            shiftCharged = true
            shiftTimer -= Game.das
            if step(Cell(shiftDirection, 0)) { events.append(.moved) }
        }
        while shiftTimer >= Game.arr {
            shiftTimer -= Game.arr
            guard step(Cell(shiftDirection, 0)) else {
                shiftTimer = 0
                return
            }
            events.append(.moved)
        }
    }

    /// Moves the active piece if the destination is free. Handles lock-delay resets.
    @discardableResult
    private mutating func step(_ offset: Cell) -> Bool {
        guard var piece = active, fits(piece, offset: offset) else { return false }
        piece.origin = piece.origin + offset
        commitMove(piece)
        lastRotationKick = nil
        return true
    }

    private mutating func commitMove(_ piece: ActivePiece) {
        active = piece
        if piece.origin.y < lowestRow {
            lowestRow = piece.origin.y
            lockResets = 0
            lockTimer = 0
        } else if lockTimer > 0, lockResets < Game.maxLockResets {
            lockResets += 1
            lockTimer = 0
        }
    }

    private mutating func rotate(by direction: Int) {
        guard let piece = active else { return }
        let target = (piece.rotation + direction + 4) % 4
        for (index, kick) in piece.kind.kicks(from: piece.rotation, to: target).enumerated() {
            var candidate = piece
            candidate.rotation = target
            candidate.origin = piece.origin + kick
            if fits(candidate) {
                commitMove(candidate)
                lastRotationKick = index
                events.append(.rotated)
                return
            }
        }
    }

    private mutating func hardDrop() {
        guard var piece = active else { return }
        let start = piece.cells
        var distance = 0
        while fits(piece, offset: Cell(0, -1)) {
            piece.origin.y -= 1
            distance += 1
        }
        active = piece
        if distance > 0 { lastRotationKick = nil }
        score += distance * 2
        events.append(.hardDropped(kind: piece.kind, from: start, to: piece.cells))
        lock()
    }

    private mutating func hold() {
        guard canHold, let piece = active else { return }
        let swapped = held
        held = piece.kind
        spawn(swapped ?? takeNext())
        canHold = false
        events.append(.held)
    }

    private mutating func lock() {
        guard let piece = active else { return }
        let tSpin = tSpin(for: piece)
        let cells = piece.cells
        for cell in cells where cell.y < Game.height {
            board[cell.y][cell.x] = .piece(piece.kind)
        }
        active = nil
        canHold = true
        events.append(.locked(kind: piece.kind, cells: cells))

        if cells.allSatisfy({ $0.y >= Game.visibleHeight }) {
            topOut(pending: nil)
            return
        }

        let full = (0..<Game.height).filter { y in board[y].allSatisfy { $0 != nil } }
        award(lines: full, tSpin: tSpin)
        guard !full.isEmpty else {
            spawn(takeNext())
            return
        }

        clearingRows = full
        clearTimer = 0
        events.append(.linesCleared(rows: full, blocks: blocks(in: full)))
        lines += full.count
        garbageRemaining -= full.filter { y in board[y].contains(.garbage) }.count

        if let goal = mode.lineGoal, lines >= goal {
            finish(.completed)
        } else if mode.garbageRows > 0, garbageRemaining == 0 {
            finish(.completed)
        } else if mode.levelsUp, lines / 10 + 1 > level {
            level = lines / 10 + 1
            events.append(.levelUp(level))
        }
    }

    private mutating func award(lines full: [Int], tSpin: TSpin) {
        let count = full.count
        combo = count > 0 ? combo + 1 : -1
        guard count > 0 || tSpin != .none else { return }

        let difficult = Scoring.isDifficult(lines: count, tSpin: tSpin)
        let backToBack = difficult && backToBackReady
        if count > 0 { backToBackReady = difficult }
        let cleared = Set(full)
        let perfectClear = count > 0 && board.indices.allSatisfy { y in
            cleared.contains(y) || board[y].allSatisfy { $0 == nil }
        }
        let points = Scoring.points(lines: count, tSpin: tSpin, level: level, backToBack: backToBack,
                                    combo: max(combo, 0), perfectClear: perfectClear)
        score += points
        events.append(.scored(ScoreAction(lines: count, tSpin: tSpin, combo: max(combo, 0), backToBack: backToBack,
                                          perfectClear: perfectClear, points: points)))
    }

    /// Guideline 3-corner rule: a T that last moved by rotating, with three of the four cells diagonal to its
    /// centre occupied. Both corners on the side it points to make a full T-spin, otherwise a mini, unless the
    /// rotation needed the last (T-spin triple) kick.
    private func tSpin(for piece: ActivePiece) -> TSpin {
        guard piece.kind == .t, let kick = lastRotationKick else { return .none }
        let center = piece.origin + Cell(1, 1)
        // Clockwise from top-left, so the corners a rotation state points at are `rotation` and the one after it.
        let corners = [Cell(-1, 1), Cell(1, 1), Cell(1, -1), Cell(-1, -1)].map { isOccupied(center + $0) }
        guard corners.filter({ $0 }).count >= 3 else { return .none }
        let front = corners[piece.rotation] && corners[(piece.rotation + 1) % 4]
        return front || kick == 4 ? .full : .mini
    }

    private mutating func collapseClearedRows() {
        for y in clearingRows.sorted(by: >) {
            board.remove(at: y)
            board.append(Array(repeating: nil, count: Game.width))
        }
        events.append(.rowsCollapsed(rows: clearingRows))
        clearingRows = []
        clearTimer = 0
    }
}
