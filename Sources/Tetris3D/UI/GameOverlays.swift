import MetaGame
import SwiftUI
import TetrisCore

struct PauseScreen: View {
    let controller: GameController
    let unit: CGFloat

    var body: some View {
        let u = unit
        ZStack {
            Color.black.opacity(0.45)
                .onTapGesture { if controller.menu.pauseSettings { controller.closePauseSettings() } }
            if controller.menu.pauseSettings {
                SettingsPage(controller: controller, unit: u)
            } else {
                menu
            }
        }
    }

    private var menu: some View {
        let u = unit
        return MenuPanel(unit: u, title: "PAUSED", hints: [.select, .confirm("CONFIRM"), KeyHint(key: "ESC", action: "RESUME")]) {
            VStack(spacing: u * 0.1) {
                ForEach(Array(PauseItem.allCases.enumerated()), id: \.offset) { index, item in
                    let selected = controller.menu.pause == index
                    SelectableRow(unit: u, isSelected: selected,
                                  onHover: { controller.select { $0.pause = index } },
                                  action: { controller.activate(item) }) {
                        Text(title(item))
                            .font(.rounded(u * 0.5, .heavy))
                            .tracking(u * 0.2)
                            .foregroundStyle(.white.opacity(selected ? 1 : 0.5))
                    }
                }
            }
            .frame(width: u * 7)
        }
    }

    private func title(_ item: PauseItem) -> String {
        switch item {
        case .resume: "RESUME"
        case .settings: "SETTINGS"
        case .restart: "RESTART"
        case .leave: controller.hud.mode == .zen ? "END SESSION" : "MAIN MENU"
        }
    }
}

struct ResultsScreen: View {
    let controller: GameController
    let result: GameController.Result
    let unit: CGFloat

    private var session: SessionRecord { result.session }

    var body: some View {
        let u = unit
        ZStack {
            Color.black.opacity(0.5)
            VStack(spacing: u * 0.8) {
                VStack(spacing: u * 0.2) {
                    Caption(session.mode.title, size: u * 0.4)
                    Text(title)
                        .font(.rounded(u * 1.5, .black))
                        .tracking(u * 0.3)
                        .foregroundStyle(.white)
                        .shadow(color: .white.opacity(0.4), radius: u * 0.5)
                }

                VStack(spacing: u * 0.12) {
                    Caption(primary.label, size: u * 0.32)
                    Text(primary.value)
                        .font(.rounded(u * 1.7, .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .shadow(color: .cyan.opacity(0.5), radius: u * 0.4)
                    if let standing {
                        Caption(standing.text, size: u * 0.34, opacity: 1)
                            .foregroundStyle(standing.tint)
                            .shadow(color: standing.tint.opacity(0.6), radius: u * 0.3)
                            .padding(.top, u * 0.06)
                    }
                }

                HStack(spacing: u * 0.3) {
                    ForEach(details, id: \.0) { title, value in
                        VStack(spacing: u * 0.1) {
                            Caption(title, size: u * 0.24, opacity: 0.45).fixedSize()
                            Text(value)
                                .font(.rounded(u * 0.5, .bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                        }
                        .frame(width: u * 2.7)
                    }
                }

                if !result.report.newAchievements.isEmpty {
                    VStack(spacing: u * 0.3) {
                        Caption("ACHIEVEMENTS UNLOCKED", size: u * 0.28, opacity: 0.5)
                        let rows = stride(from: 0, to: result.report.newAchievements.count, by: 3).map {
                            Array(result.report.newAchievements[$0..<min($0 + 3, result.report.newAchievements.count)])
                        }
                        ForEach(rows, id: \.self) { row in
                            HStack(spacing: u * 0.3) {
                                ForEach(row, id: \.self) { achievement in chip(achievement) }
                            }
                        }
                    }
                }

                HStack(spacing: u * 0.3) {
                    ForEach(Array(ResultsItem.allCases.enumerated()), id: \.offset) { index, item in
                        let selected = controller.menu.results == index
                        SelectableRow(unit: u, isSelected: selected,
                                      onHover: { controller.select { $0.results = index } },
                                      action: { controller.activate(item) }) {
                            Text(item.title)
                                .font(.rounded(u * 0.5, .heavy))
                                .tracking(u * 0.2)
                                .foregroundStyle(.white.opacity(selected ? 1 : 0.5))
                        }
                        .frame(width: u * 3.6)
                    }
                }

                KeyHintBar(unit: u, hints: [KeyHint(key: "←→", action: "SELECT"), .confirm("CONFIRM"),
                                            KeyHint(key: "R", action: "RETRY"), KeyHint(key: "ESC", action: "MENU")])
            }
            .padding(.horizontal, u * 1.4)
            .padding(.top, u * 1.0)
            .padding(.bottom, u * 0.7)
            .panel(unit: u)
        }
    }

    private var title: String {
        switch (session.mode, session.outcome) {
        case (.zen, _): "SESSION OVER"
        case (.marathon, .completed): "COMPLETE"
        case (.ultra, .completed): "TIME UP"
        case (.sprint, .completed), (.dig, .completed): "FINISHED"
        default: "GAME OVER"
        }
    }

    private var finishedTrial: Bool { session.mode.ranking == .fastestTime && session.outcome == .completed }

    private var primary: (label: String, value: String) {
        if finishedTrial { return ("TIME", Format.time(session.elapsed)) }
        if session.mode.ranking == .fastestTime { return ("LINES", "\(session.lines)") }
        return ("SCORE", session.score.formatted())
    }

    private var standing: (text: String, tint: Color)? {
        if let rank = result.report.rank {
            return rank == 1 ? ("NEW PERSONAL BEST", Palette.gold) : ("#\(rank) ON THE LEADERBOARD", Palette.tetris)
        }
        switch session.mode.ranking {
        case .unranked: return nil
        case .fastestTime where !finishedTrial: return ("DID NOT FINISH", .white.opacity(0.5))
        case .fastestTime: return result.previousBest.map { ("BEST \(Format.time($0.time))", .white.opacity(0.5)) }
        case .highestScore: return result.previousBest.map { ("BEST \($0.score.formatted())", .white.opacity(0.5)) }
        }
    }

    private var details: [(String, String)] {
        let piecesPerSecond = session.elapsed > 0 ? Double(session.piecesPlaced) / session.elapsed : 0
        let pps = piecesPerSecond.formatted(.number.precision(.fractionLength(2)))
        let head: [(String, String)] = switch session.mode {
        case .marathon: [("LEVEL", "\(session.level)"), ("LINES", "\(session.lines)")]
        case .sprint, .dig: [("PIECES", "\(session.piecesPlaced)"), ("PIECES/SEC", pps)]
        case .ultra: [("LINES", "\(session.lines)"), ("PIECES/SEC", pps)]
        case .zen: [("TIME", Format.minutes(session.elapsed)), ("LINES", "\(session.lines)")]
        }
        return head + [("TETRISES", "\(session.tetrises)"), ("T-SPINS", "\(session.tSpins)"),
                       ("MAX COMBO", "\(session.maxCombo)")]
    }

    private func chip(_ achievement: Achievement) -> some View {
        let u = unit
        return HStack(spacing: u * 0.2) {
            BadgeView(achievement: achievement, unlocked: true, size: u * 0.95)
            Text(achievement.title.uppercased())
                .font(.rounded(u * 0.3, .heavy))
                .tracking(u * 0.05)
                .foregroundStyle(.white)
        }
        .padding(.leading, u * 0.12)
        .padding(.trailing, u * 0.35)
        .padding(.vertical, u * 0.1)
        .background(Capsule().fill(Palette.tier(achievement.tier).opacity(0.1)))
        .overlay(Capsule().strokeBorder(Palette.tier(achievement.tier).opacity(0.35)))
    }
}
