import Testing
@testable import TetrisCore

@Suite struct TetrominoTests {
    @Test func rotationCycleReturnsToSpawn() {
        for kind in PieceKind.allCases {
            #expect(kind.cells(rotation: 4) == kind.cells(rotation: 0))
        }
    }

    @Test func tRotatesClockwiseToPointRight() {
        let r = Set(PieceKind.t.cells(rotation: 1))
        #expect(r == [Cell(1, 0), Cell(1, 1), Cell(1, 2), Cell(2, 1)])
    }

    @Test func iRotatesIntoThirdColumn() {
        #expect(PieceKind.i.cells(rotation: 1).allSatisfy { $0.x == 2 })
    }

    @Test func bagDealsEverySevenPiecesExactlyOnce() {
        var bag = PieceBag(seed: 42)
        for _ in 0..<10 {
            let run = Set((0..<7).map { _ in bag.next() })
            #expect(run.count == 7)
        }
    }
}

@Suite struct GameTests {
    private func emptyGame(seed: UInt64 = 1) -> Game {
        var game = Game(mode: .marathon, seed: seed)
        _ = game.drainEvents()
        return game
    }

    @Test func spawnsInTopVisibleRow() throws {
        let game = emptyGame()
        let piece = try #require(game.active)
        #expect(piece.cells.map(\.y).min() == Game.visibleHeight - 1)
        #expect(piece.cells.allSatisfy { (3...6).contains($0.x) })
    }

    @Test func hardDropLandsOnFloorAndScores() throws {
        var game = emptyGame()
        let before = try #require(game.active)
        let drop = before.cells.map(\.y).min()!
        game.press(.hardDrop)
        #expect(game.score == drop * 2)
        for cell in before.cells {
            #expect(game.board[cell.y - drop][cell.x] == .piece(before.kind))
        }
        #expect(game.active != nil)
        #expect(game.active?.kind != nil)
    }

    @Test func clearsFullRowsAfterAnimation() {
        var game = emptyGame()
        for x in 0..<Game.width where x != 0 { game.board[0][x] = .piece(.o) }
        game.board[1][5] = .piece(.t)
        game.active = ActivePiece(kind: .i, rotation: 1, origin: Cell(-2, 5))
        game.press(.hardDrop)

        let events = game.drainEvents()
        #expect(events.contains { if case .linesCleared(rows: [0], _) = $0 { true } else { false } })
        #expect(game.lines == 1)
        #expect(game.score > 100)
        #expect(game.active == nil)

        game.update(dt: Game.clearDuration)
        #expect(game.clearingRows.isEmpty)
        #expect(game.board[0][5] == .piece(.t))
        #expect(game.board[0][0] == .piece(.i))
        #expect(game.active != nil)
        #expect(game.drainEvents().contains(.rowsCollapsed(rows: [0])))
    }

    @Test func tetrisScoresEightHundredTimesLevel() {
        var game = emptyGame()
        for y in 0..<4 {
            for x in 1..<Game.width { game.board[y][x] = .piece(.l) }
        }
        game.board[4][5] = .piece(.l) // keeps it from being a perfect clear
        game.active = ActivePiece(kind: .i, rotation: 1, origin: Cell(-2, 10))
        let before = game.score
        game.press(.hardDrop)
        #expect(game.score - before - 2 * 10 == 800)
        #expect(game.clearingRows == [0, 1, 2, 3])
    }

    @Test func wallKickLetsIRotateAgainstWall() {
        var game = emptyGame()
        // Vertical I hugging the left wall: plain rotation would poke out of the board.
        game.active = ActivePiece(kind: .i, rotation: 1, origin: Cell(-2, 5))
        game.press(.rotateCW)
        #expect(game.active?.rotation == 2)
        #expect(game.active!.cells.allSatisfy { $0.x >= 0 })
    }

    @Test func holdSwapsOncePerPiece() throws {
        var game = emptyGame()
        let first = try #require(game.active?.kind)
        let upcoming = game.nextQueue[0]
        game.press(.hold)
        #expect(game.held == first)
        #expect(game.active?.kind == upcoming)
        game.press(.hold)
        #expect(game.held == first, "second hold before locking must be ignored")
        game.press(.hardDrop)
        game.press(.hold)
        #expect(game.held != first)
    }

    @Test func groundedPieceLocksAfterDelay() {
        var game = emptyGame()
        game.active = ActivePiece(kind: .o, rotation: 0, origin: Cell(4, 0))
        game.update(dt: 0.3)
        #expect(game.board[0][4] == nil)
        game.update(dt: 0.3)
        #expect(game.board[0][4] == .piece(.o))
    }

    @Test func autoShiftSlidesToWall() {
        var game = emptyGame()
        game.active = ActivePiece(kind: .o, rotation: 0, origin: Cell(4, 10))
        game.press(.left)
        #expect(game.active?.origin.x == 3)
        for _ in 0..<30 { game.update(dt: 1.0 / 60) }
        #expect(game.active?.origin.x == 0)
        game.release(.left)
    }

    @Test func blockedSpawnEndsGame() {
        var game = emptyGame()
        for y in 0..<18 {
            for x in 1..<Game.width { game.board[y][x] = .piece(.z) }
        }
        for y in 18..<22 {
            for x in 3...6 { game.board[y][x] = .piece(.z) }
        }
        game.active = ActivePiece(kind: .o, rotation: 0, origin: Cell(0, 30))
        game.press(.hardDrop)
        #expect(game.outcome == .toppedOut)
        #expect(game.drainEvents().contains(.finished(.toppedOut)))
    }

    @Test func autoPilotCompletesRows() throws {
        var game = Game(seed: 7)
        for _ in 0..<60 {
            let target = try #require(AutoPilot.bestTarget(for: game))
            var active = try #require(game.active)
            active.rotation = target.rotation
            active.origin.x = target.x
            game.active = active
            game.press(.hardDrop)
            game.update(dt: Game.clearDuration)
        }
        #expect(!game.isFinished)
        #expect(game.lines >= 15)
    }
}
