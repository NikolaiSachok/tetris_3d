import Testing
@testable import TetrisCore

@Suite struct GameModeTests {
    private func game(_ mode: GameMode) -> Game {
        var game = Game(mode: mode, seed: 11)
        game.board = Array(repeating: Array(repeating: nil, count: Game.width), count: Game.height)
        _ = game.drainEvents()
        return game
    }

    /// Fills `rows` except column 0, then drops a vertical I into that column.
    private func clear(_ rows: Int, in game: inout Game) {
        for y in 0..<rows {
            for x in 1..<Game.width { game.board[y][x] = .piece(.l) }
        }
        game.board[6][5] = .piece(.l)
        game.active = ActivePiece(kind: .i, rotation: 1, origin: Cell(-2, 12))
        game.press(.hardDrop)
    }

    @Test func marathonLevelsUpEveryTenLines() {
        var game = game(.marathon)
        game.lines = 9
        clear(1, in: &game)
        #expect(game.level == 2)
        #expect(game.drainEvents().contains(.levelUp(2)))
    }

    @Test func onlyMarathonSpeedsUp() {
        for mode in [GameMode.sprint, .ultra, .dig, .zen] {
            var game = game(mode)
            game.lines = 9
            clear(1, in: &game)
            #expect(game.level == 1)
        }
    }

    @Test func marathonFinishesAtOneHundredFiftyLines() {
        var game = game(.marathon)
        game.lines = 148
        clear(2, in: &game)
        #expect(game.outcome == .completed)
    }

    @Test func sprintFinishesAtFortyLinesAndStopsTheClock() {
        var game = game(.sprint)
        game.update(dt: 1.5)
        game.lines = 38
        #expect(game.linesRemaining == 2)
        clear(2, in: &game)
        #expect(game.outcome == .completed)
        #expect(game.linesRemaining == 0)
        #expect(game.drainEvents().contains(.finished(.completed)))

        game.update(dt: Game.clearDuration)
        #expect(game.clearingRows.isEmpty, "the clear animation still plays out")
        #expect(game.active == nil, "no new piece after the goal")
        #expect(game.elapsed == 1.5)
    }

    @Test func ultraEndsWhenTheClockRunsOut() {
        var game = game(.ultra)
        game.update(dt: 100)
        #expect(game.timeRemaining == 20)
        #expect(!game.isFinished)
        game.update(dt: 30)
        #expect(game.outcome == .completed)
        #expect(game.elapsed == 120)
        #expect(game.timeRemaining == 0)
        game.press(.hardDrop)
        #expect(game.drainEvents().filter { if case .hardDropped = $0 { true } else { false } }.isEmpty)
    }

    @Test(arguments: [1, 2, 3, 99] as [UInt64])
    func digStartsWithTenGarbageRowsWithStaggeredHoles(seed: UInt64) {
        let game = Game(mode: .dig, seed: seed)
        #expect(game.garbageRemaining == 10)
        var previousHole: Int?
        for y in 0..<10 {
            let holes = (0..<Game.width).filter { game.board[y][$0] == nil }
            #expect(holes.count == 1)
            #expect(game.board[y].allSatisfy { $0 == nil || $0 == .garbage })
            #expect(holes.first != previousHole)
            previousHole = holes.first
        }
        #expect(game.board[10].allSatisfy { $0 == nil })
    }

    @Test func digFinishesWhenTheLastGarbageRowClears() {
        var game = game(.dig)
        for x in 1..<Game.width { game.board[0][x] = .garbage }
        game.garbageRemaining = 1
        game.active = ActivePiece(kind: .i, rotation: 1, origin: Cell(-2, 12))
        game.press(.hardDrop)
        #expect(game.garbageRemaining == 0)
        #expect(game.outcome == .completed)
    }

    @Test func zenTrimsTheStackInsteadOfToppingOut() throws {
        var game = game(.zen)
        for y in 0..<18 {
            for x in 1..<Game.width { game.board[y][x] = .piece(.z) }
        }
        for y in 18..<22 {
            for x in 3...6 { game.board[y][x] = .piece(.z) }
        }
        game.active = ActivePiece(kind: .o, rotation: 0, origin: Cell(0, 30))
        let blocked = game.nextQueue[0]
        game.press(.hardDrop)

        let events = game.drainEvents()
        #expect(!game.isFinished)
        #expect(events.contains { if case .stackTrimmed(rows: Array(0..<12), _) = $0 { true } else { false } })

        game.update(dt: Game.clearDuration)
        #expect(game.active?.kind == blocked, "the piece that could not spawn comes back")
        let stackHeight = (game.board.lastIndex { $0.contains { $0 != nil } } ?? -1) + 1
        #expect(stackHeight == 10)
        #expect(!events.contains { if case .scored = $0 { true } else { false } }, "trimming is not scored")
    }

    @Test func elapsedTimeAccumulatesWhilePlaying() {
        var game = game(.sprint)
        for _ in 0..<60 { game.update(dt: 1.0 / 60) }
        #expect(abs(game.elapsed - 1) < 1e-9)
    }
}
