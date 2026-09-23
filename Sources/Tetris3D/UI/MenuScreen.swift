import MetaGame
import SwiftUI
import TetrisCore

/// The main menu and its pages, drawn over the attract-mode game.
struct MenuScreen: View {
    let controller: GameController
    let page: MenuPage
    let unit: CGFloat

    var body: some View {
        ZStack {
            RadialGradient(colors: [.black.opacity(page == .main ? 0.55 : 0.7), .black.opacity(page == .main ? 0.15 : 0.45)],
                           center: .center, startRadius: 0, endRadius: unit * 22)
                .onTapGesture { if page != .main { controller.back() } }
            switch page {
            case .main: MainMenu(controller: controller, unit: unit)
            case .play: ModeSelect(controller: controller, unit: unit)
            case .leaderboards: LeaderboardPage(controller: controller, unit: unit)
            case .achievements: AchievementsPage(profile: controller.profile.profile, unit: unit)
            case .stats: StatsPage(stats: controller.profile.profile.stats, unit: unit)
            case .settings: SettingsPage(controller: controller, unit: unit)
            }
        }
        .animation(.easeOut(duration: 0.2), value: page)
    }
}

// MARK: - Main

private struct MainMenu: View {
    let controller: GameController
    let unit: CGFloat

    var body: some View {
        let u = unit
        VStack(spacing: 0) {
            Text("TETRIS")
                .font(.rounded(u * 3.2, .black))
                .tracking(u * 0.5)
                .foregroundStyle(LinearGradient(colors: [.white, Color(red: 0.55, green: 0.85, blue: 1)],
                                                startPoint: .top, endPoint: .bottom))
                .shadow(color: Palette.glow.opacity(0.8), radius: u * 0.8)
            Text("3D")
                .font(.rounded(u * 1.1, .heavy))
                .tracking(u * 0.3)
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, u * 0.2)

            VStack(spacing: u * 0.7) {
                VStack(spacing: u * 0.08) {
                    ForEach(Array(MainMenuItem.allCases.enumerated()), id: \.offset) { index, item in
                        let selected = controller.menu.main == index
                        SelectableRow(unit: u, isSelected: selected,
                                      onHover: { controller.select { $0.main = index } },
                                      action: { controller.activate(item) }) {
                            Text(item.title)
                                .font(.rounded(u * 0.48, .heavy))
                                .tracking(u * 0.2)
                                .foregroundStyle(.white.opacity(selected ? 1 : 0.5))
                                .shadow(color: Palette.glow.opacity(selected ? 0.8 : 0), radius: u * 0.3)
                                .fixedSize()
                        }
                    }
                }
                .frame(width: u * 7.4)
                KeyHintBar(unit: u, hints: [.select, .confirm("CONFIRM")])
                Text(AppVersion.display)
                    .font(.rounded(u * 0.26, .semibold))
                    .tracking(u * 0.08)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.28))
                    .padding(.top, -u * 0.35)
            }
            .padding(.horizontal, u * 0.5)
            .padding(.top, u * 0.5)
            .padding(.bottom, u * 0.55)
            .panel(unit: u)
            .padding(.top, u * 1.2)
        }
    }
}

// MARK: - Mode select

private struct ModeSelect: View {
    let controller: GameController
    let unit: CGFloat

    var body: some View {
        let u = unit
        MenuPanel(unit: u, title: "SELECT MODE", hints: [.select, .confirm("START"), .back]) {
            VStack(spacing: u * 0.12) {
                ForEach(Array(GameMode.allCases.enumerated()), id: \.offset) { index, mode in
                    let selected = controller.menu.mode == index
                    SelectableRow(unit: u, isSelected: selected,
                                  onHover: { controller.select { $0.mode = index } },
                                  action: { controller.choose(mode) }) {
                        row(mode, selected: selected)
                    }
                }
            }
            .frame(width: u * 15)
        }
    }

    private func row(_ mode: GameMode, selected: Bool) -> some View {
        let u = unit
        return HStack(spacing: u * 0.5) {
            Image(systemName: mode.symbol)
                .font(.system(size: u * 0.55, weight: .bold))
                .foregroundStyle(selected ? Palette.tetris : .white.opacity(0.45))
                .frame(width: u * 0.9)
            VStack(alignment: .leading, spacing: u * 0.08) {
                Text(mode.title)
                    .font(.rounded(u * 0.5, .heavy))
                    .tracking(u * 0.15)
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.7))
                Text(mode.tagline)
                    .font(.rounded(u * 0.32, .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: u * 0.5)
            VStack(alignment: .trailing, spacing: u * 0.08) {
                Caption("BEST", size: u * 0.26, opacity: 0.4)
                Text(best(for: mode))
                    .font(.rounded(u * 0.42, .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private func best(for mode: GameMode) -> String {
        let profile = controller.profile.profile
        switch mode.ranking {
        case .highestScore: return profile.leaderboard(mode).best.map { $0.score.formatted() } ?? "—"
        case .fastestTime: return profile.leaderboard(mode).best.map { Format.time($0.time) } ?? "—"
        case .unranked:
            let games = profile.stats.gamesPlayed[mode] ?? 0
            return games == 0 ? "—" : "\(games) \(games == 1 ? "SESSION" : "SESSIONS")"
        }
    }
}

// MARK: - Leaderboards

private struct LeaderboardPage: View {
    let controller: GameController
    let unit: CGFloat

    var body: some View {
        let u = unit
        let mode = controller.menu.leaderboard
        let entries = controller.profile.profile.leaderboard(mode).entries
        MenuPanel(unit: u, title: "LEADERBOARDS", hints: [KeyHint(key: "←→", action: "MODE"), .back]) {
            HStack(spacing: u * 0.2) {
                ForEach(GameMode.ranked, id: \.self) { tab in
                    let selected = tab == mode
                    Button { controller.select { $0.leaderboard = tab } } label: {
                        Text(tab.title)
                            .font(.rounded(u * 0.36, .heavy))
                            .tracking(u * 0.12)
                            .foregroundStyle(.white.opacity(selected ? 1 : 0.45))
                            .padding(.horizontal, u * 0.4)
                            .padding(.vertical, u * 0.18)
                            .background(Capsule().fill(.white.opacity(selected ? 0.14 : 0)))
                            .overlay(Capsule().strokeBorder(.white.opacity(selected ? 0.25 : 0)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }

            Grid(horizontalSpacing: u * 0.6, verticalSpacing: 0) {
                GridRow {
                    Caption("#", size: u * 0.28, opacity: 0.4)
                    Caption(mode.ranking == .fastestTime ? "TIME" : "SCORE", size: u * 0.28, opacity: 0.4)
                        .gridColumnAlignment(.trailing)
                    Caption("LINES", size: u * 0.28, opacity: 0.4).gridColumnAlignment(.trailing)
                    Caption("DATE", size: u * 0.28, opacity: 0.4).gridColumnAlignment(.trailing)
                }
                .padding(.bottom, u * 0.2)
                ForEach(0..<Leaderboard.capacity, id: \.self) { index in
                    row(index, entry: entries.indices.contains(index) ? entries[index] : nil, mode: mode)
                }
            }
            .frame(width: u * 13)
            .overlay {
                if entries.isEmpty {
                    Text("No \(mode.title.lowercased()) results yet.\nPlay a round to set the first mark.")
                        .font(.rounded(u * 0.36, .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(u * 0.5)
                        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: u * 0.3))
                }
            }
        }
    }

    private func row(_ index: Int, entry: LeaderboardEntry?, mode: GameMode) -> some View {
        let u = unit
        let highlighted = entry != nil && entry?.id == controller.menu.highlightedEntry
        let color: Color = highlighted ? Palette.gold : .white
        let result = entry.map { mode.ranking == .fastestTime ? Format.time($0.time) : $0.score.formatted() } ?? "—"
        return GridRow {
            Text("\(index + 1)")
                .foregroundStyle(color.opacity(entry == nil ? 0.25 : 0.55))
            Text(result)
                .font(.rounded(u * 0.42, .bold))
                .foregroundStyle(color.opacity(entry == nil ? 0.25 : 1))
            Text(entry.map { "\($0.lines)" } ?? "")
                .foregroundStyle(color.opacity(0.6))
            Text(entry.map { $0.date.formatted(date: .abbreviated, time: .omitted) } ?? "")
                .foregroundStyle(color.opacity(0.6))
        }
        .font(.rounded(u * 0.34, .semibold))
        .monospacedDigit()
        .frame(height: u * 0.62)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: u * 0.2).fill(Palette.gold.opacity(0.12))
                    .padding(.horizontal, -u * 0.3)
            }
        }
    }
}

// MARK: - Achievements

private struct AchievementsPage: View {
    let profile: Profile
    let unit: CGFloat

    var body: some View {
        let u = unit
        let unlocked = profile.achievements.count
        let columns = Array(repeating: GridItem(.fixed(u * 6), spacing: u * 0.3), count: 4)
        MenuPanel(unit: u, title: "ACHIEVEMENTS", hints: [.back]) {
            Caption("\(unlocked) OF \(Achievement.allCases.count) UNLOCKED", size: u * 0.3, opacity: 0.5)
                .padding(.top, -u * 0.5)
            LazyVGrid(columns: columns, spacing: u * 0.3) {
                ForEach(Achievement.allCases, id: \.self) { achievement in
                    AchievementCard(achievement: achievement, unlockedOn: profile.achievements[achievement],
                                    progress: profile.progress(of: achievement), unit: u)
                }
            }
            .frame(width: u * (6 * 4 + 0.3 * 3))
        }
    }
}

private struct AchievementCard: View {
    let achievement: Achievement
    let unlockedOn: Date?
    let progress: Achievement.Progress
    let unit: CGFloat

    var body: some View {
        let u = unit
        let unlocked = unlockedOn != nil
        let hidden = achievement.isSecret && !unlocked
        HStack(spacing: u * 0.2) {
            BadgeView(achievement: achievement, unlocked: unlocked, size: u * 1.8)
            VStack(alignment: .leading, spacing: u * 0.06) {
                Text(hidden ? "SECRET" : achievement.title.uppercased())
                    .font(.rounded(u * 0.3, .heavy))
                    .tracking(u * 0.05)
                    .foregroundStyle(.white.opacity(unlocked ? 1 : 0.6))
                Text(hidden ? "Keep playing to find out." : achievement.detail)
                    .font(.rounded(u * 0.26, .medium))
                    .foregroundStyle(.white.opacity(unlocked ? 0.6 : 0.4))
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
                if !unlocked, progress.target > 1 {
                    ProgressBar(fraction: progress.fraction, tint: Palette.tier(achievement.tier), unit: u)
                        .overlay(alignment: .trailing) {
                            Text("\(min(progress.current, progress.target).formatted()) / \(progress.target.formatted())")
                                .font(.rounded(u * 0.2, .bold))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.5))
                                .offset(y: -u * 0.2)
                        }
                        .padding(.top, u * 0.08)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, u * 0.12)
        .padding(.trailing, u * 0.3)
        .frame(width: u * 6, height: u * 2.1)
        .background(RoundedRectangle(cornerRadius: u * 0.25)
            .fill(unlocked ? Palette.tier(achievement.tier).opacity(0.08) : .white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: u * 0.25)
            .strokeBorder(unlocked ? Palette.tier(achievement.tier).opacity(0.3) : .white.opacity(0.06)))
    }
}

private struct ProgressBar: View {
    let fraction: Double
    let tint: Color
    let unit: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Capsule().fill(.white.opacity(0.1))
                .overlay(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.8)).frame(width: proxy.size.width * fraction)
                }
        }
        .frame(height: unit * 0.1)
    }
}

// MARK: - Stats

private struct StatsPage: View {
    let stats: LifetimeStats
    let unit: CGFloat

    var body: some View {
        let u = unit
        let tiles: [(String, String)] = [
            ("GAMES", stats.totalGames.formatted()), ("PLAY TIME", Format.duration(stats.playTime)),
            ("LINES", stats.lines.formatted()), ("PIECES", stats.piecesPlaced.formatted()),
            ("TETRISES", stats.tetrises.formatted()), ("T-SPINS", stats.tSpins.formatted()),
            ("PERFECT CLEARS", stats.perfectClears.formatted()), ("BEST COMBO", stats.bestCombo.formatted()),
        ]
        MenuPanel(unit: u, title: "STATS", hints: [.back]) {
            Grid(horizontalSpacing: u * 0.3, verticalSpacing: u * 0.3) {
                ForEach(0..<2) { row in
                    GridRow {
                        ForEach(0..<4) { column in
                            let tile = tiles[row * 4 + column]
                            tileView(tile.0, tile.1)
                        }
                    }
                }
            }
            VStack(spacing: u * 0.3) {
                Caption("GAMES BY MODE", size: u * 0.28, opacity: 0.4)
                HStack(spacing: u * 0.3) {
                    ForEach(GameMode.allCases, id: \.self) { mode in
                        VStack(spacing: u * 0.12) {
                            Image(systemName: mode.symbol)
                                .font(.system(size: u * 0.42, weight: .bold))
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(height: u * 0.5)
                            Text((stats.gamesPlayed[mode] ?? 0).formatted())
                                .font(.rounded(u * 0.5, .bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                            Caption(mode.title, size: u * 0.24, opacity: 0.45)
                        }
                        .frame(width: u * 3)
                    }
                }
            }
            .padding(.top, u * 0.2)
        }
    }

    private func tileView(_ title: String, _ value: String) -> some View {
        let u = unit
        return VStack(spacing: u * 0.14) {
            Caption(title, size: u * 0.26, opacity: 0.45)
            Text(value)
                .font(.rounded(u * 0.7, .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .shadow(color: .cyan.opacity(0.4), radius: u * 0.3)
        }
        .frame(width: u * 4, height: u * 1.7)
        .background(RoundedRectangle(cornerRadius: u * 0.25).fill(.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: u * 0.25).strokeBorder(.white.opacity(0.06)))
    }
}

// MARK: - Settings

struct SettingsPage: View {
    let controller: GameController
    let unit: CGFloat

    var body: some View {
        let u = unit
        let settings = controller.profile.settings
        MenuPanel(unit: u, title: "SETTINGS", hints: [.select, KeyHint(key: "←→", action: "ADJUST"), .back]) {
            VStack(spacing: u * 0.12) {
                ForEach(Array(SettingsItem.allCases.enumerated()), id: \.offset) { index, item in
                    let selected = controller.menu.setting == index
                    SelectableRow(unit: u, isSelected: selected,
                                  onHover: { controller.select { $0.setting = index } },
                                  action: { if item.isDiscrete { controller.adjust(item, by: 1) } }) {
                        HStack {
                            Text(item.title)
                                .font(.rounded(u * 0.42, .heavy))
                                .tracking(u * 0.12)
                                .foregroundStyle(.white.opacity(selected ? 1 : 0.6))
                                .fixedSize()
                            Spacer(minLength: u * 0.5)
                            switch item {
                            case .ghost: choice(settings.ghost.title, isOn: settings.ghost != .off)
                            case .rotation: choice(settings.rotation.title, isOn: true)
                            case .controls: toggle(settings.showControls)
                            case .music: volume(item, settings.musicVolume)
                            case .effects: volume(item, settings.effectsVolume)
                            }
                        }
                    }
                }
            }
            .frame(width: u * 12.5)
        }
    }

    private func toggle(_ isOn: Bool) -> some View {
        choice(isOn ? "ON" : "OFF", isOn: isOn)
    }

    private func choice(_ title: String, isOn: Bool) -> some View {
        let u = unit
        return Text(title)
            .font(.rounded(u * 0.32, .heavy))
            .tracking(u * 0.1)
            .foregroundStyle(isOn ? .black : .white.opacity(0.6))
            .frame(width: u * 2.1, height: u * 0.55)
            .background(Capsule().fill(isOn ? Palette.tetris : .white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(.white.opacity(isOn ? 0 : 0.2)))
    }

    private func volume(_ item: SettingsItem, _ value: Double) -> some View {
        let u = unit
        return HStack(spacing: u * 0.3) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(Palette.tetris).frame(width: max(proxy.size.width * value, u * 0.16))
                        .opacity(value > 0 ? 1 : 0)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    controller.setVolume(item, to: drag.location.x / proxy.size.width)
                })
            }
            .frame(width: u * 3.2, height: u * 0.16)
            Text("\(Int((value * 100).rounded()))%")
                .font(.rounded(u * 0.32, .bold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: u * 1.1, alignment: .trailing)
        }
    }
}
