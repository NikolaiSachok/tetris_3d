import Testing
@testable import TetrisCore

@Suite struct ScoringTableTests {
    @Test func lineClearsAndTSpinsFollowTheGuidelineTable() {
        func points(_ lines: Int, _ tSpin: TSpin, level: Int = 1) -> Int {
            Scoring.points(lines: lines, tSpin: tSpin, level: level, backToBack: false, combo: 0, perfectClear: false)
        }
        #expect([1, 2, 3, 4].map { points($0, .none) } == [100, 300, 500, 800])
        #expect([0, 1, 2].map { points($0, .mini) } == [100, 200, 400])
        #expect([0, 1, 2, 3].map { points($0, .full) } == [400, 800, 1200, 1600])
        #expect(points(2, .full, level: 3) == 3600)
    }

    @Test func backToBackAddsHalf() {
        #expect(Scoring.points(lines: 4, tSpin: .none, level: 2, backToBack: true, combo: 0, perfectClear: false) == 2400)
    }

    @Test func comboAddsFiftyPerChainLinkPerLevel() {
        #expect(Scoring.points(lines: 1, tSpin: .none, level: 2, backToBack: false, combo: 3, perfectClear: false) == 500)
        #expect(Scoring.points(lines: 0, tSpin: .full, level: 1, backToBack: false, combo: 3, perfectClear: false) == 400)
    }

    @Test func perfectClearBonusDependsOnLinesAndBackToBack() {
        #expect(Scoring.points(lines: 1, tSpin: .none, level: 1, backToBack: false, combo: 0, perfectClear: true) == 900)
        #expect(Scoring.points(lines: 4, tSpin: .none, level: 1, backToBack: false, combo: 0, perfectClear: true) == 2800)
        #expect(Scoring.points(lines: 4, tSpin: .none, level: 1, backToBack: true, combo: 0, perfectClear: true) == 4400)
    }

    @Test func onlyTetrisesAndLineClearingTSpinsAreDifficult() {
        #expect(Scoring.isDifficult(lines: 4, tSpin: .none))
        #expect(Scoring.isDifficult(lines: 1, tSpin: .mini))
        #expect(!Scoring.isDifficult(lines: 3, tSpin: .none))
        #expect(!Scoring.isDifficult(lines: 0, tSpin: .full))
    }
}

@Suite struct ScoringGameTests {
    private func game() -> Game {
        var game = Game(mode: .marathon, seed: 3)
        game.board = Array(repeating: Array(repeating: nil, count: Game.width), count: Game.height)
        _ = game.drainEvents()
        return game
    }

    private func fill(_ game: inout Game, rows: Range<Int>, except holes: Set<Int>) {
        for y in rows {
            for x in 0..<Game.width where !holes.contains(x) { game.board[y][x] = .piece(.l) }
        }
    }

    private func scored(_ events: [GameEvent]) -> [ScoreAction] {
        events.compactMap { if case let .scored(action) = $0 { action } else { nil } }
    }

    /// Drops a vertical I into column 0 and lets the clear animation finish.
    private func dropIIntoLeftWell(_ game: inout Game) -> ScoreAction? {
        game.active = ActivePiece(kind: .i, rotation: 1, origin: Cell(-2, 10))
        game.press(.hardDrop)
        let action = scored(game.drainEvents()).first
        game.update(dt: Game.clearDuration)
        _ = game.drainEvents()
        return action
    }

    @Test func rotatingIntoAnOverhangIsATSpinDouble() throws {
        var game = game()
        fill(&game, rows: 0..<1, except: [4])
        fill(&game, rows: 1..<2, except: [3, 4, 5])
        game.board[2][3] = .piece(.l)
        game.active = ActivePiece(kind: .t, rotation: 1, origin: Cell(3, 0))
        game.press(.rotateCW)
        game.press(.hardDrop)

        let action = try #require(scored(game.drainEvents()).first)
        #expect(action == ScoreAction(lines: 2, tSpin: .full, points: 1200))
    }

    @Test func kickIntoAShallowSlotIsAMiniTSpin() throws {
        var game = game()
        fill(&game, rows: 0..<1, except: [0, 1, 2])
        game.board[1][0] = .piece(.l)
        game.board[1][3] = .piece(.l)
        game.active = ActivePiece(kind: .t, rotation: 3, origin: Cell(1, 0))
        game.press(.rotateCW)
        #expect(game.active?.origin == Cell(0, -1))
        game.press(.hardDrop)

        let action = try #require(scored(game.drainEvents()).first)
        #expect(action == ScoreAction(lines: 1, tSpin: .mini, points: 200))
    }

    @Test func tDroppedWithoutRotatingIsNoTSpin() throws {
        var game = game()
        fill(&game, rows: 0..<1, except: [4])
        fill(&game, rows: 1..<2, except: [3, 4, 5])
        game.board[2][3] = .piece(.l)
        // Same final spot as the T-spin double, but the piece never rotated there.
        game.active = ActivePiece(kind: .t, rotation: 2, origin: Cell(3, 0))
        game.press(.hardDrop)

        let action = try #require(scored(game.drainEvents()).first)
        #expect(action.tSpin == .none)
        #expect(action.points == 300)
    }

    @Test func consecutiveTetrisesAreBackToBackUntilAnEasierClear() throws {
        var game = game()
        var actions: [ScoreAction] = []
        for lines in [4, 4, 1] {
            game.board = Array(repeating: Array(repeating: nil, count: Game.width), count: Game.height)
            fill(&game, rows: 0..<lines, except: [0])
            game.board[5][5] = .piece(.l)
            actions.append(try #require(dropIIntoLeftWell(&game)))
        }
        #expect(actions.map(\.backToBack) == [false, true, false])
        #expect(actions.map(\.combo) == [0, 1, 2])
        #expect(actions.map(\.points) == [800, 1250, 200])
        #expect(!game.backToBackReady)
    }

    @Test func lockWithoutClearingBreaksTheCombo() throws {
        var game = game()
        fill(&game, rows: 0..<1, except: [0])
        _ = try #require(dropIIntoLeftWell(&game))
        #expect(game.combo == 0)

        game.active = ActivePiece(kind: .o, rotation: 0, origin: Cell(7, 10))
        game.press(.hardDrop)
        #expect(scored(game.drainEvents()).isEmpty)
        #expect(game.combo == -1)
    }

    @Test func emptyingTheBoardIsAPerfectClear() throws {
        var game = game()
        for x in 0..<6 { game.board[0][x] = .piece(.l) }
        game.active = ActivePiece(kind: .i, rotation: 0, origin: Cell(6, 5))
        game.press(.hardDrop)

        let action = try #require(scored(game.drainEvents()).first)
        #expect(action.perfectClear)
        #expect(action.points == 900)
    }
}
