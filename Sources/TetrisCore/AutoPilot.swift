/// A simple placement AI used for the attract mode behind the title screen.
/// Scores each reachable drop with the well-known El-Tetris style weights.
public enum AutoPilot {
    /// Returns the rotation and box x to aim for with the current piece, or nil if nothing fits.
    public static func bestTarget(for game: Game) -> (rotation: Int, x: Int)? {
        guard let piece = game.active else { return nil }
        var best: (score: Double, rotation: Int, x: Int)?

        for rotation in 0..<(piece.kind == .o ? 1 : 4) {
            for x in -2..<Game.width {
                var candidate = ActivePiece(kind: piece.kind, rotation: rotation, origin: Cell(x, piece.origin.y))
                guard game.fits(candidate) else { continue }
                while game.fits(candidate, offset: Cell(0, -1)) { candidate.origin.y -= 1 }
                let score = evaluate(game.board, placing: candidate.cells)
                if best == nil || score > best!.score {
                    best = (score, rotation, x)
                }
            }
        }
        return best.map { ($0.rotation, $0.x) }
    }

    static func evaluate(_ board: [[Block?]], placing cells: [Cell]) -> Double {
        var filled = board.map { $0.map { $0 != nil } }
        for cell in cells where cell.y < Game.height { filled[cell.y][cell.x] = true }
        let fullRows = filled.indices.filter { filled[$0].allSatisfy { $0 } }
        for y in fullRows.sorted(by: >) {
            filled.remove(at: y)
            filled.append(Array(repeating: false, count: Game.width))
        }

        var heights = [Int](repeating: 0, count: Game.width)
        var holes = 0
        for x in 0..<Game.width {
            var seenBlock = false
            for y in stride(from: Game.height - 1, through: 0, by: -1) {
                if filled[y][x] {
                    if !seenBlock { heights[x] = y + 1 }
                    seenBlock = true
                } else if seenBlock {
                    holes += 1
                }
            }
        }
        let aggregate = heights.reduce(0, +)
        let bumpiness = zip(heights, heights.dropFirst()).reduce(0) { $0 + abs($1.0 - $1.1) }
        return -0.51 * Double(aggregate) + 0.76 * Double(fullRows.count) - 0.36 * Double(holes) - 0.18 * Double(bumpiness)
    }
}
