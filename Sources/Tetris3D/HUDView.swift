import MetaGame
import SwiftUI
import TetrisCore

/// 2D overlay: in-game labels pinned to projected 3D anchors, plus the menu, pause and result screens.
struct HUDView: View {
    let controller: GameController

    var body: some View {
        let layout = controller.layout
        let u = max(layout.unit, 8)
        ZStack {
            switch controller.screen {
            case let .menu(page):
                MenuScreen(controller: controller, page: page, unit: u)
            case .countdown, .playing:
                GameHUD(controller: controller, layout: layout, unit: u)
            case .paused:
                GameHUD(controller: controller, layout: layout, unit: u)
                PauseScreen(controller: controller, unit: u)
            case .results:
                if let result = controller.result {
                    ResultsScreen(controller: controller, result: result, unit: u)
                }
            }
            ToastLayer(feedback: controller.feedback, anchor: layout.toast, unit: u)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Everything drawn around the well while a game is on screen.
private struct GameHUD: View {
    let controller: GameController
    let layout: HUDLayout
    let unit: CGFloat

    var body: some View {
        let u = unit
        ZStack {
            Caption("HOLD", size: u * 0.5).position(layout.hold)
            Caption("NEXT", size: u * 0.5).position(layout.next)
            StatsPanel(controller: controller, unit: u)
                .position(x: layout.stats.x, y: layout.stats.y + u * 3.6)
            if controller.profile.settings.showControls {
                ControlsHint(unit: u).position(x: layout.controls.x, y: layout.controls.y - u * 1.7)
            }
            CalloutLayer(feedback: controller.feedback, anchor: layout.callout, boardCenter: layout.boardCenter, unit: u)
            CountdownLayer(step: controller.countdownStep, anchor: layout.boardCenter, unit: u)
        }
        .allowsHitTesting(false)
    }
}

/// Mode-specific numbers in the left column. Kept in its own view so the per-frame clock only redraws this.
private struct StatsPanel: View {
    let controller: GameController
    let unit: CGFloat

    var body: some View {
        let hud = controller.hud
        let best = controller.profile.profile.leaderboard(hud.mode).best
        let u = unit
        VStack(spacing: u * 0.9) {
            Caption(hud.mode.title, size: u * 0.36, opacity: 0.35)
            switch hud.mode {
            case .marathon:
                stat("SCORE", hud.score.formatted(), large: true)
                HStack(spacing: u * 1.2) {
                    stat("LEVEL", "\(hud.level)")
                    stat("LINES", "\(hud.lines)")
                }
                stat("BEST", max(best?.score ?? 0, hud.score).formatted())
            case .sprint:
                stat("TIME", clock(hud.centiseconds), large: true, animated: false)
                stat("LINES LEFT", "\(hud.linesRemaining ?? 0)")
                stat("BEST", best.map { Format.time($0.time) } ?? "—")
            case .ultra:
                let remaining = hud.remainingCentiseconds ?? 0
                stat("TIME LEFT", clock(remaining), large: true, animated: false,
                     tint: remaining <= 1000 && remaining > 0 ? Palette.danger : .white)
                stat("SCORE", hud.score.formatted())
                stat("BEST", max(best?.score ?? 0, hud.score).formatted())
            case .dig:
                stat("TIME", clock(hud.centiseconds), large: true, animated: false)
                stat("GARBAGE LEFT", "\(hud.garbageRemaining)")
                stat("BEST", best.map { Format.time($0.time) } ?? "—")
            case .zen:
                stat("SCORE", hud.score.formatted(), large: true)
                HStack(spacing: u * 1.2) {
                    stat("LINES", "\(hud.lines)")
                    stat("TIME", Format.minutes(Double(hud.centiseconds) / 100), animated: false)
                }
            }
        }
        // Top-aligned so the mode caption sits at the same height whatever the mode shows below it.
        .frame(width: u * 7, height: u * 7.6, alignment: .top)
    }

    private func clock(_ centiseconds: Int) -> String { Format.time(Double(centiseconds) / 100) }

    private func stat(_ title: String, _ value: String, large: Bool = false, animated: Bool = true,
                      tint: Color = .white) -> some View {
        let u = unit
        return VStack(spacing: u * 0.12) {
            Caption(title, size: u * 0.36)
            Text(value)
                .font(.rounded(u * (large ? 1.05 : 0.75), .bold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .shadow(color: (tint == .white ? Color.cyan : tint).opacity(0.45), radius: u * 0.3)
                .contentTransition(animated ? .numericText() : .identity)
                .animation(animated ? .snappy : nil, value: value)
        }
    }
}

private struct ControlsHint: View {
    let unit: CGFloat

    var body: some View {
        let u = unit
        let rows: [(String, String)] = [
            ("← →", "Move"), ("↓", "Soft drop"), ("Space", "Hard drop"),
            ("↑ X / Z", "Rotate"), ("C / ⇧", "Hold"), ("P / Esc", "Pause"),
        ]
        Grid(alignment: .leading, horizontalSpacing: u * 0.4, verticalSpacing: u * 0.14) {
            ForEach(rows, id: \.0) { key, action in
                GridRow {
                    Text(key).foregroundStyle(.white.opacity(0.75)).gridColumnAlignment(.trailing)
                    Text(action).foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .font(.rounded(u * 0.3, .semibold))
    }
}
