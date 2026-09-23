import Foundation
import Testing
@testable import MetaGame
import TetrisCore

private let day = Date(timeIntervalSince1970: 1_800_000_000)

private func session(_ mode: GameMode, _ configure: (inout SessionRecord) -> Void = { _ in }) -> SessionRecord {
    var record = SessionRecord(mode: mode)
    configure(&record)
    return record
}

@Suite struct SessionRecordTests {
    @Test func talliesScoringEvents() {
        var record = SessionRecord(mode: .marathon)
        let game = Game(mode: .marathon, seed: 1)
        record.record([
            .locked(kind: .i, cells: []),
            .held,
            .linesCleared(rows: [0, 1, 2, 3], blocks: []),
            .scored(ScoreAction(lines: 4, combo: 0, points: 800)),
            .linesCleared(rows: [17], blocks: []),
            .scored(ScoreAction(lines: 2, tSpin: .full, combo: 1, backToBack: true, points: 1850)),
            .scored(ScoreAction(lines: 1, tSpin: .mini, combo: 2, perfectClear: true, points: 1100)),
            .scored(ScoreAction(lines: 0, tSpin: .full, points: 400)),
        ], from: game)

        #expect(record.piecesPlaced == 1)
        #expect(record.holds == 1)
        #expect(record.tetrises == 1)
        #expect(record.tSpins == 2)
        #expect(record.bestTSpinLines == 2)
        #expect(record.backToBacks == 1)
        #expect(record.perfectClears == 1)
        #expect(record.maxCombo == 2)
        #expect(record.highestClearedRow == 17)
    }
}

@Suite struct LeaderboardTests {
    private func entry(score: Int = 0, time: Double = 0, day offset: Double = 0) -> LeaderboardEntry {
        LeaderboardEntry(score: score, lines: 0, level: 1, time: time, date: day + offset * 86_400)
    }

    @Test func ranksScoresHighestFirstAndKeepsTopTen() {
        var board = Leaderboard()
        for score in stride(from: 1000, through: 10_000, by: 1000) {
            _ = board.submit(entry(score: score), ranking: .highestScore)
        }
        #expect(board.entries.count == 10)
        #expect(board.submit(entry(score: 500), ranking: .highestScore) == nil)
        #expect(board.submit(entry(score: 5500), ranking: .highestScore) == 6)
        #expect(board.entries.count == 10)
        #expect(board.entries.last?.score == 2000)
        #expect(board.best?.score == 10_000)
    }

    @Test func ranksTimesFastestFirst() {
        var board = Leaderboard()
        _ = board.submit(entry(time: 70), ranking: .fastestTime)
        #expect(board.submit(entry(time: 55), ranking: .fastestTime) == 1)
        #expect(board.submit(entry(time: 90), ranking: .fastestTime) == 3)
    }

    @Test func tiesGoToTheOlderEntry() {
        var board = Leaderboard()
        _ = board.submit(entry(score: 100, day: 0), ranking: .highestScore)
        #expect(board.submit(entry(score: 100, day: 1), ranking: .highestScore) == 2)
    }

    @Test func onlyEligibleGamesQualify() {
        #expect(Leaderboard.accepts(session(.marathon) { $0.score = 10; $0.outcome = .toppedOut }))
        #expect(!Leaderboard.accepts(session(.marathon) { $0.score = 10 }), "abandoned games do not count")
        #expect(!Leaderboard.accepts(session(.sprint) { $0.outcome = .toppedOut }))
        #expect(Leaderboard.accepts(session(.sprint) { $0.outcome = .completed }))
        #expect(!Leaderboard.accepts(session(.zen) { $0.score = 10; $0.outcome = .completed }))
    }
}

@Suite struct AchievementTests {
    @Test func catalogIsComplete() {
        #expect(Achievement.allCases.count >= 20)
        #expect(Set(Achievement.allCases.map(\.title)).count == Achievement.allCases.count)
        #expect(Achievement.allCases.contains { $0.isSecret })
    }

    @Test func sprintUnderAMinuteNeedsAFinishedRun() {
        var stats = LifetimeStats()
        let fast = session(.sprint) { $0.elapsed = 58; $0.outcome = .completed }
        let unfinished = session(.sprint) { $0.elapsed = 58 }
        let slow = session(.sprint) { $0.elapsed = 61; $0.outcome = .completed }
        stats.add(fast)
        #expect(Achievement.sprintUnder60.progress(stats: stats, session: fast).isComplete)
        #expect(!Achievement.sprintUnder60.progress(stats: stats, session: unfinished).isComplete)
        #expect(!Achievement.sprintUnder60.progress(stats: stats, session: slow).isComplete)
    }

    @Test func lifetimeGoalsReportProgress() {
        var stats = LifetimeStats()
        stats.lines = 250
        stats.gamesPlayed = [.sprint: 3, .zen: 1]
        let lines = Achievement.lines1000.progress(stats: stats, session: nil)
        #expect(lines == Achievement.Progress(current: 250, target: 1000))
        #expect(lines.fraction == 0.25)
        #expect(Achievement.explorer.progress(stats: stats, session: nil).current == 2)
    }

    @Test func levelGoalsOnlyCountInMarathon() {
        let marathon = session(.marathon) { $0.level = 10 }
        let zen = session(.zen) { $0.level = 10 }
        #expect(Achievement.level10.progress(stats: LifetimeStats(), session: marathon).isComplete)
        #expect(!Achievement.level10.progress(stats: LifetimeStats(), session: zen).isComplete)
    }
}

@Suite struct ProfileTests {
    @Test func recordingAGameUpdatesStatsLeaderboardAndAchievements() throws {
        var profile = Profile()
        let game = session(.sprint) {
            $0.lines = 40
            $0.tetrises = 10
            $0.elapsed = 75
            $0.outcome = .completed
        }
        let report = profile.record(game, on: day)

        #expect(report.rank == 1)
        #expect(profile.leaderboard(.sprint).best?.id == report.entryID)
        #expect(profile.stats.gamesPlayed[.sprint] == 1)
        #expect(profile.stats.lines == 40)
        #expect(profile.stats.playTime == 75)
        #expect(Set(report.newAchievements) == [.firstLine, .tetris, .sprint, .purist])
        #expect(profile.achievements[.tetris] == day)

        let again = profile.record(game, on: day + 60)
        #expect(again.rank == 2)
        #expect(again.newAchievements.isEmpty, "achievements unlock once")
    }

    @Test func midGameUnlocksDoNotCountTheGameTwice() {
        var profile = Profile()
        let inProgress = session(.marathon) { $0.lines = 4; $0.tetrises = 1 }
        #expect(profile.unlockAchievements(during: inProgress, on: day) == [.firstLine, .tetris])
        #expect(profile.stats == LifetimeStats())

        _ = profile.record(inProgress, on: day)
        #expect(profile.stats.lines == 4)
    }

    @Test func abandonedGamesCountTowardsStatsButNotLeaderboards() {
        var profile = Profile()
        let report = profile.record(session(.marathon) { $0.score = 5000 }, on: day)
        #expect(report.rank == nil)
        #expect(profile.stats.totalGames == 1)
        #expect(profile.leaderboard(.marathon).entries.isEmpty)
    }

    @Test func unlockedAchievementsReportFullProgress() {
        var profile = Profile()
        profile.achievements[.lines1000] = day
        #expect(profile.progress(of: .lines1000).isComplete)
        #expect(!profile.progress(of: .tetrises100).isComplete)
    }
}

@Suite struct ProfileStoreTests {
    private func temporaryStore() -> ProfileStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MetaGameTests-\(UUID().uuidString)")
        return ProfileStore(url: directory.appending(path: "profile.json"))
    }

    @Test func roundTripsAProfile() throws {
        let store = temporaryStore()
        var profile = Profile()
        _ = profile.record(session(.ultra) { $0.score = 12_345; $0.outcome = .completed; $0.lines = 30 }, on: day)
        profile.settings.musicVolume = 0.25
        profile.settings.ghost = .gray
        try store.save(profile)
        #expect(store.load() == profile)
    }

    @Test func settingsMissingFromTheFileKeepTheirDefaults() throws {
        let store = temporaryStore()
        var profile = Profile()
        profile.settings.musicVolume = 0.25
        try store.save(profile)
        let json = try String(contentsOf: store.url, encoding: .utf8)
            .replacingOccurrences(of: "\"ghost\" : \"colored\",", with: "")
        try Data(json.utf8).write(to: store.url)

        let loaded = store.load()
        #expect(loaded.settings.ghost == .colored)
        #expect(loaded.settings.musicVolume == 0.25)
    }

    @Test func missingFileGivesAFreshProfile() {
        #expect(temporaryStore().load() == Profile())
    }

    @Test func corruptFileIsSetAsideForAFreshProfile() throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.url)

        #expect(store.load() == Profile())
        #expect(!FileManager.default.fileExists(atPath: store.url.path()))
        #expect(try Data(contentsOf: store.quarantineURL) == Data("{ not json".utf8))
    }
}
