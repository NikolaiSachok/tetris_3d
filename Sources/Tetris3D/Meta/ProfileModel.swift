import Foundation
import MetaGame
import Observation
import os
import TetrisCore

/// The persistent profile as observable app state. Every change is written straight to disk.
@MainActor
@Observable
final class ProfileModel {
    private(set) var profile: Profile

    @ObservationIgnored private let store: ProfileStore
    @ObservationIgnored private let logger = Logger(subsystem: "Tetris3D", category: "Profile")

    init(store: ProfileStore) {
        self.store = store
        profile = store.load()
    }

    var settings: Settings {
        get { profile.settings }
        set {
            guard newValue != profile.settings else { return }
            profile.settings = newValue
            save()
        }
    }

    func record(_ session: SessionRecord) -> GameReport {
        let report = profile.record(session, on: .now)
        save()
        return report
    }

    func unlockAchievements(during session: SessionRecord) -> [Achievement] {
        let unlocked = profile.unlockAchievements(during: session, on: .now)
        if !unlocked.isEmpty { save() }
        return unlocked
    }

    private func save() {
        do {
            try store.save(profile)
        } catch {
            logger.error("Saving the profile failed: \(error.localizedDescription)")
        }
    }
}
