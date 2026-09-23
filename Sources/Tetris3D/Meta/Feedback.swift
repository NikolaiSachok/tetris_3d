import MetaGame
import Observation
import SwiftUI
import TetrisCore

/// Short-lived messages: scoring callouts beside the board, banners across it and achievement toasts.
@MainActor
@Observable
final class Feedback {
    struct Callout: Identifiable, Equatable {
        let id: Int
        /// "BACK-TO-BACK", "MINI" or both, above the headline.
        var caption: String?
        var headline: String
        var tint: Color
        var backToBack: Bool
        var combo: Int
        var points: Int
    }

    struct Banner: Identifiable, Equatable {
        let id: Int
        var text: String
        var tint: Color
    }

    struct Toast: Identifiable, Equatable {
        let id: Int
        var achievement: Achievement
    }

    static let calloutDuration = 1.8
    static let bannerDuration = 1.6
    static let toastDuration = 3.6

    private(set) var callout: Callout?
    private(set) var banner: Banner?
    private(set) var toast: Toast?

    @ObservationIgnored private var calloutAge = 0.0
    @ObservationIgnored private var bannerAge = 0.0
    @ObservationIgnored private var toastAge = 0.0
    @ObservationIgnored private var pendingToasts: [Achievement] = []
    @ObservationIgnored private var nextID = 0

    func post(_ action: ScoreAction) {
        if action.perfectClear { show(banner: "PERFECT CLEAR", tint: Palette.gold) }
        let (headline, tint) = Feedback.headline(for: action)
        let caption = [action.backToBack ? "BACK-TO-BACK" : nil, action.tSpin == .mini ? "MINI" : nil]
            .compactMap { $0 }.joined(separator: " ")
        callout = Callout(id: makeID(), caption: caption.isEmpty ? nil : caption, headline: headline, tint: tint,
                          backToBack: action.backToBack, combo: action.combo, points: action.points)
        calloutAge = 0
    }

    func postLevel(_ level: Int) {
        show(banner: "LEVEL \(level)", tint: .white)
    }

    func postFinish(_ mode: GameMode, _ outcome: GameOutcome) {
        switch (mode, outcome) {
        case (_, .toppedOut): show(banner: "TOP OUT", tint: Palette.danger)
        case (.ultra, .completed): show(banner: "TIME UP!", tint: Palette.gold)
        case (_, .completed): show(banner: "FINISH!", tint: Palette.gold)
        }
    }

    func post(_ achievement: Achievement) {
        pendingToasts.append(achievement)
        if toast == nil { showNextToast() }
    }

    func update(dt: Double) {
        calloutAge += dt
        bannerAge += dt
        toastAge += dt
        if callout != nil, calloutAge > Feedback.calloutDuration { callout = nil }
        if banner != nil, bannerAge > Feedback.bannerDuration { banner = nil }
        if toast != nil, toastAge > Feedback.toastDuration { showNextToast() }
    }

    /// Drops in-game messages when a game ends or restarts. Toasts carry on: they are about the player, not the game.
    func clearCallouts() {
        callout = nil
        banner = nil
    }

    private func show(banner text: String, tint: Color) {
        banner = Banner(id: makeID(), text: text, tint: tint)
        bannerAge = 0
    }

    private func showNextToast() {
        toast = pendingToasts.isEmpty ? nil : Toast(id: makeID(), achievement: pendingToasts.removeFirst())
        toastAge = 0
    }

    private func makeID() -> Int {
        nextID += 1
        return nextID
    }

    static func headline(for action: ScoreAction) -> (String, Color) {
        let count = ["", "SINGLE", "DOUBLE", "TRIPLE", "TETRIS"][min(action.lines, 4)]
        if action.tSpin != .none { return (action.lines == 0 ? "T-SPIN" : "T-SPIN \(count)", Palette.tSpin) }
        return (count, action.lines == 4 ? Palette.tetris : .white)
    }
}
