/// A board coordinate. `y` grows upward; row 0 is the floor.
public struct Cell: Hashable, Sendable {
    public var x: Int
    public var y: Int

    public init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }

    static func + (a: Cell, b: Cell) -> Cell { Cell(a.x + b.x, a.y + b.y) }
}

public enum PieceKind: Int, CaseIterable, Sendable {
    case i, o, t, s, z, j, l

    /// Side of the square box the piece rotates inside (SRS).
    var boxSize: Int {
        switch self {
        case .i: 4
        case .o: 2
        default: 3
        }
    }

    /// Spawn-orientation cells inside the rotation box, y up.
    private var spawnCells: [Cell] {
        switch self {
        case .i: [Cell(0, 2), Cell(1, 2), Cell(2, 2), Cell(3, 2)]
        case .o: [Cell(0, 0), Cell(1, 0), Cell(0, 1), Cell(1, 1)]
        case .t: [Cell(1, 2), Cell(0, 1), Cell(1, 1), Cell(2, 1)]
        case .s: [Cell(1, 2), Cell(2, 2), Cell(0, 1), Cell(1, 1)]
        case .z: [Cell(0, 2), Cell(1, 2), Cell(1, 1), Cell(2, 1)]
        case .j: [Cell(0, 2), Cell(0, 1), Cell(1, 1), Cell(2, 1)]
        case .l: [Cell(2, 2), Cell(0, 1), Cell(1, 1), Cell(2, 1)]
        }
    }

    /// Cells for a rotation state (0 = spawn, 1 = R, 2 = 180, 3 = L), relative to the box origin.
    /// Cell order is stable across rotations, so cell `n` of one state is the rotated cell `n` of another.
    public func cells(rotation: Int) -> [Cell] {
        let n = boxSize
        return spawnCells.map { cell in
            var c = cell
            for _ in 0..<((rotation % 4 + 4) % 4) {
                c = Cell(c.y, n - 1 - c.x)
            }
            return c
        }
    }

    /// SRS wall-kick offsets to try when rotating from `from` to `to` (y up).
    func kicks(from: Int, to: Int) -> [Cell] {
        switch self {
        case .o:
            return [Cell(0, 0)]
        case .i:
            switch (from, to) {
            case (0, 1): return [Cell(0, 0), Cell(-2, 0), Cell(1, 0), Cell(-2, -1), Cell(1, 2)]
            case (1, 0): return [Cell(0, 0), Cell(2, 0), Cell(-1, 0), Cell(2, 1), Cell(-1, -2)]
            case (1, 2): return [Cell(0, 0), Cell(-1, 0), Cell(2, 0), Cell(-1, 2), Cell(2, -1)]
            case (2, 1): return [Cell(0, 0), Cell(1, 0), Cell(-2, 0), Cell(1, -2), Cell(-2, 1)]
            case (2, 3): return [Cell(0, 0), Cell(2, 0), Cell(-1, 0), Cell(2, 1), Cell(-1, -2)]
            case (3, 2): return [Cell(0, 0), Cell(-2, 0), Cell(1, 0), Cell(-2, -1), Cell(1, 2)]
            case (3, 0): return [Cell(0, 0), Cell(1, 0), Cell(-2, 0), Cell(1, -2), Cell(-2, 1)]
            case (0, 3): return [Cell(0, 0), Cell(-1, 0), Cell(2, 0), Cell(-1, 2), Cell(2, -1)]
            default: return [Cell(0, 0)]
            }
        default:
            switch (from, to) {
            case (0, 1), (2, 1): return [Cell(0, 0), Cell(-1, 0), Cell(-1, 1), Cell(0, -2), Cell(-1, -2)]
            case (1, 0), (1, 2): return [Cell(0, 0), Cell(1, 0), Cell(1, -1), Cell(0, 2), Cell(1, 2)]
            case (2, 3), (0, 3): return [Cell(0, 0), Cell(1, 0), Cell(1, 1), Cell(0, -2), Cell(1, -2)]
            case (3, 2), (3, 0): return [Cell(0, 0), Cell(-1, 0), Cell(-1, -1), Cell(0, 2), Cell(-1, 2)]
            default: return [Cell(0, 0)]
            }
        }
    }
}

public struct ActivePiece: Sendable, Equatable {
    public var kind: PieceKind
    public var rotation: Int
    /// Bottom-left corner of the rotation box on the board.
    public var origin: Cell

    public var cells: [Cell] { kind.cells(rotation: rotation).map { $0 + origin } }

    static func spawn(_ kind: PieceKind) -> ActivePiece {
        // Spawn so the piece's lowest row sits on the top visible row (row 19), columns 3...6.
        let originY = switch kind {
        case .i: 17
        case .o: 19
        default: 18
        }
        return ActivePiece(kind: kind, rotation: 0, origin: Cell(kind == .o ? 4 : 3, originY))
    }
}

/// The 7-bag randomizer: every run of seven pieces contains each tetromino once.
public struct PieceBag: Sendable {
    private var generator: SplitMix64
    private var bag: [PieceKind] = []

    public init(seed: UInt64) {
        generator = SplitMix64(seed: seed)
    }

    public mutating func next() -> PieceKind {
        if bag.isEmpty {
            bag = PieceKind.allCases.shuffled(using: &generator)
        }
        return bag.removeLast()
    }
}

struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
