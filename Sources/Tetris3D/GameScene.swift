import MetaGame
import simd
import TetrisCore

/// Presentation layer: turns game state and events into animated instances, particles and camera effects.
struct GameScene {
    private(set) var time: Float = 0
    private(set) var shake: Float = 0
    private(set) var flash: Float = 0
    private(set) var accent = SIMD3<Float>(0.15, 0.6, 1.0)
    private(set) var danger: Float = 0
    private(set) var particles = ParticleSystem()

    private var activeVisual: [SIMD3<Float>] = []
    private var snapActive = true
    private var lockGlow: [Cell: Float] = [:]
    private var rowDrop = [Float](repeating: 0, count: Game.height)
    private var rowDropVelocity = [Float](repeating: 0, count: Game.height)

    static func color(_ block: Block) -> SIMD3<Float> {
        switch block {
        case let .piece(kind): color(kind)
        case .garbage: [0.13, 0.14, 0.17]
        }
    }

    static func color(_ kind: PieceKind) -> SIMD3<Float> {
        switch kind {
        case .i: [0.02, 0.72, 0.95]
        case .o: [1.0, 0.72, 0.04]
        case .t: [0.58, 0.14, 0.95]
        case .s: [0.12, 0.85, 0.22]
        case .z: [0.95, 0.08, 0.16]
        case .j: [0.10, 0.26, 1.0]
        case .l: [1.0, 0.38, 0.02]
        }
    }

    /// Neutral landing hint for players who find the colored one distracting.
    static let ghostGray: SIMD3<Float> = [0.26, 0.28, 0.32]

    static func accent(level: Int) -> SIMD3<Float> {
        let palette: [SIMD3<Float>] = [
            [0.15, 0.60, 1.00], [0.95, 0.20, 0.75], [0.20, 0.95, 0.55], [1.00, 0.55, 0.10],
            [0.60, 0.30, 1.00], [1.00, 0.20, 0.25], [0.10, 0.90, 0.95], [0.95, 0.90, 0.20],
        ]
        return palette[(level - 1) % palette.count]
    }

    mutating func reset() {
        self = GameScene()
    }

    var shakeOffset: SIMD3<Float> {
        let s = shake * shake
        return SIMD3(sin(time * 31) + sin(time * 19) * 0.5, cos(time * 27) + sin(time * 13) * 0.5, 0) * s * 0.12
    }

    // MARK: - Update

    mutating func update(dt: Float, game: Game, events: [GameEvent]) {
        time += dt
        for event in events { handle(event, game: game) }

        shake *= exp(-dt * 5.5)
        flash *= exp(-dt * 3.0)
        accent = .mix(accent, GameScene.accent(level: game.level), 1 - exp(-dt * 2))

        let stackHeight = (0..<Game.visibleHeight).last { y in game.board[y].contains { $0 != nil } }.map { $0 + 1 } ?? 0
        let targetDanger = max(0, Float(stackHeight) - 13) / 7
        danger += (targetDanger - danger) * (1 - exp(-dt * 3))

        for (cell, glow) in lockGlow {
            let next = glow - dt * 3.5
            lockGlow[cell] = next > 0 ? next : nil
        }

        for y in 0..<Game.height where rowDrop[y] > 0 {
            rowDropVelocity[y] += 55 * dt
            rowDrop[y] -= rowDropVelocity[y] * dt
            if rowDrop[y] <= 0 {
                rowDrop[y] = 0
                rowDropVelocity[y] = 0
            }
        }

        updateActiveVisual(dt: dt, game: game)
        particles.update(dt: dt)
    }

    private mutating func updateActiveVisual(dt: Float, game: Game) {
        guard let piece = game.active else {
            activeVisual = []
            snapActive = true
            return
        }
        let targets = piece.cells.map { Layout.position(x: Float($0.x), y: Float($0.y)) }
        if snapActive || activeVisual.count != targets.count {
            activeVisual = targets
            snapActive = false
            return
        }
        let k = 1 - exp(-dt * 30)
        for i in activeVisual.indices {
            activeVisual[i] += (targets[i] - activeVisual[i]) * k
        }
    }

    private mutating func handle(_ event: GameEvent, game: Game) {
        switch event {
        case .moved, .rotated:
            break
        case let .hardDropped(kind, from, to):
            let color = GameScene.color(kind)
            let distance = Float((from.first?.y ?? 0) - (to.first?.y ?? 0))
            for (start, end) in zip(from, to) {
                particles.emitTrail(from: Layout.position(x: Float(start.x), y: Float(start.y)),
                                    to: Layout.position(x: Float(end.x), y: Float(end.y)), color: color)
            }
            let bottom = to.map(\.y).min() ?? 0
            for cell in to where cell.y == bottom {
                particles.emitDust(at: Layout.position(x: Float(cell.x), y: Float(cell.y) - 0.5), color: color)
            }
            shake = max(shake, min(0.15 + distance * 0.01, 0.3))
            snapActive = true
        case let .locked(_, cells):
            for cell in cells { lockGlow[cell] = 1 }
            snapActive = true
        case let .linesCleared(rows, blocks):
            burst(blocks, strength: Float(rows.count))
            shake = max(shake, rows.count >= 4 ? 1.0 : 0.35 + Float(rows.count) * 0.1)
            if rows.count >= 4 { flash = 1 }
        case let .stackTrimmed(_, blocks):
            burst(blocks, strength: 1)
            shake = max(shake, 0.5)
        case let .rowsCollapsed(rows):
            let removed = Set(rows)
            var newRow = 0
            var removedBelow = 0
            for oldRow in 0..<Game.height {
                if removed.contains(oldRow) {
                    removedBelow += 1
                } else {
                    rowDrop[newRow] = Float(removedBelow)
                    rowDropVelocity[newRow] = 0
                    newRow += 1
                }
            }
        case .held:
            snapActive = true
        case let .scored(action):
            if action.perfectClear {
                flash = 1.4
                shake = 1
            } else if action.tSpin != .none, action.lines > 0 {
                flash = max(flash, 0.6)
            }
        case .levelUp:
            flash = max(flash, 0.7)
        case .finished(.toppedOut):
            shake = 1
        case .finished(.completed):
            flash = max(flash, 0.9)
        }
    }

    private mutating func burst(_ blocks: [ClearedBlock], strength: Float) {
        for block in blocks {
            particles.emitBurst(at: Layout.position(x: Float(block.cell.x), y: Float(block.cell.y)),
                                color: GameScene.color(block.block), strength: strength)
        }
    }

    // MARK: - Instances

    /// Opaque, shadow-casting instances followed by the translucent ghost instances.
    func buildInstances(game: Game, ghostStyle: GhostStyle) -> (opaque: [Instance], ghost: [Instance]) {
        var opaque: [Instance] = []
        opaque.reserveCapacity(260)
        appendFrame(to: &opaque)

        let clearing = Set(game.clearingRows)
        let progress = Float(game.clearProgress)
        for y in 0..<Game.height {
            for x in 0..<Game.width {
                guard let block = game.board[y][x] else { continue }
                var center = Layout.position(x: Float(x), y: Float(y) + rowDrop[y])
                let cell = Cell(x, y)
                var scale: Float = 1
                var flash: Float = 0
                var emissive: Float = 0.05
                if clearing.contains(y) {
                    // Sweep outwards from the middle: flash white, then implode.
                    let delay = abs(Float(x) - 4.5) / 4.5 * 0.35
                    let t = max(0, min(1, (progress - delay) / (1 - 0.35)))
                    flash = min(1, t * 3)
                    scale = 1 - smoothstep(0.35, 1, t)
                    center.z += t * 0.6
                }
                if let glow = lockGlow[cell] {
                    emissive += glow * 0.9
                    scale *= 1 + glow * 0.04
                }
                guard scale > 0.01 else { continue }
                opaque.append(Instance(center: center, scale: .init(repeating: scale), color: GameScene.color(block),
                                       emissive: emissive, edgeGlow: block == .garbage ? 0.04 : 0.12, flash: flash))
            }
        }

        var ghost: [Instance] = []
        if let piece = game.active {
            let color = GameScene.color(piece.kind)
            let pulse = 0.55 + 0.04 * sin(time * 2.5)
            for position in activeVisual {
                opaque.append(Instance(center: position, color: color, emissive: pulse, edgeGlow: 0.6))
            }
            if ghostStyle != .off, let shadowPiece = game.ghost, shadowPiece.origin != piece.origin {
                let ghostColor = ghostStyle == .gray ? GameScene.ghostGray : color
                for cell in shadowPiece.cells {
                    ghost.append(Instance(center: Layout.position(x: Float(cell.x), y: Float(cell.y)),
                                          color: ghostColor, opacity: 0.9, style: .ghost))
                }
            }
        }

        appendPreviews(game: game, to: &opaque)
        return (opaque, ghost)
    }

    private func appendFrame(to instances: inout [Instance]) {
        let steel = SIMD3<Float>(0.05, 0.05, 0.06)
        for side: Float in [-1, 1] {
            instances.append(Instance(center: [side * 5.36, -0.05, -0.12], scale: [0.5 / 0.94, 21.7 / 0.94, 1.5 / 0.94],
                                      color: steel, style: .frameVertical))
        }
        instances.append(Instance(center: [0, -10.28, -0.12], scale: [11.22 / 0.94, 0.5 / 0.94, 1.5 / 0.94],
                                  color: steel, style: .frameHorizontal))
    }

    private func appendPreviews(game: Game, to instances: inout [Instance]) {
        let yaw: Float = 0.25
        for (index, kind) in game.nextQueue.enumerated() {
            let scale: Float = index == 0 ? 0.78 : 0.6
            let y = Layout.previewTopY - (index == 0 ? 0 : 1.1 + Float(index) * 2.7)
            appendPreview(kind, at: [Layout.nextX, y, 0], scale: scale, yaw: yaw,
                          dimmed: false, to: &instances)
        }
        if let held = game.held {
            appendPreview(held, at: [Layout.holdX, Layout.previewTopY, 0], scale: 0.78, yaw: -yaw,
                          dimmed: !game.canHold, to: &instances)
        }
    }

    private func appendPreview(_ kind: PieceKind, at center: SIMD3<Float>, scale: Float, yaw: Float, dimmed: Bool,
                               to instances: inout [Instance]) {
        let cells = kind.cells(rotation: 0)
        let cx = Float(cells.map(\.x).min()! + cells.map(\.x).max()!) / 2
        let cy = Float(cells.map(\.y).min()! + cells.map(\.y).max()!) / 2
        let c = cos(yaw), s = sin(yaw)
        let color = dimmed ? GameScene.color(kind) * 0.25 : GameScene.color(kind)
        for cell in cells {
            let local = SIMD3<Float>((Float(cell.x) - cx) * scale, (Float(cell.y) - cy) * scale, 0)
            let rotated = SIMD3<Float>(c * local.x + s * local.z, local.y, -s * local.x + c * local.z)
            instances.append(Instance(center: center + rotated, scale: .init(repeating: scale), yaw: yaw, color: color,
                                      emissive: dimmed ? 0 : 0.25, edgeGlow: 0.3))
        }
    }
}

private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = max(0, min(1, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}
