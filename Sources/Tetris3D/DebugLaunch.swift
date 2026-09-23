#if DEBUG
import Foundation
import MetaGame
import TetrisCore

/// Debug-build launch hooks for checking screens without a keyboard:
/// `TETRIS_DATA_DIR=<dir>` keeps a separate profile, `TETRIS_SCREEN=<page|mode|pause>` opens a screen,
/// `TETRIS_AUTOPLAY=1` lets the autopilot play the started game.
enum DebugLaunch {
    private static let environment = ProcessInfo.processInfo.environment

    static var profileStore: ProfileStore? {
        environment["TETRIS_DATA_DIR"].map { ProfileStore(url: URL(filePath: $0).appending(path: "profile.json")) }
    }

    static var autoplay: Bool { environment["TETRIS_AUTOPLAY"] == "1" }

    @MainActor
    static func apply(to controller: GameController) {
        let pages: [String: MenuPage] = [
            "play": .play, "leaderboards": .leaderboards, "achievements": .achievements,
            "stats": .stats, "settings": .settings,
        ]
        guard let name = environment["TETRIS_SCREEN"] else { return }
        if let page = pages[name] {
            controller.showMenu(page)
        } else if let mode = GameMode(rawValue: name) {
            controller.play(mode)
        } else if name == "pause" {
            controller.play(.marathon)
            controller.pause()
        }
    }
}
#endif
