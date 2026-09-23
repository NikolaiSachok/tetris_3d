# Tetris 3D

A native macOS Tetris with a Metal renderer: shadow-mapped PBR candy-glass blocks, HDR bloom, ACES tone mapping,
a procedural starfield/nebula backdrop, particles, synthesized music and sound effects, five game modes,
achievements with 3D badges, stats and local leaderboards.

## Build & run

```sh
./scripts/build_app.sh      # builds build/Tetris3D.app (universal release)
open build/Tetris3D.app
swift test                  # rules, scoring, modes, meta-game
```

Requires macOS 14+ and Xcode (Swift 6). Shaders are compiled at runtime, so the offline Metal toolchain is not needed.

## Versioning & release

- **Version** (`CFBundleShortVersionString`) lives in `VERSION` and follows semantic versioning; every fix or
  feature bumps it via `scripts/bump_version.sh` (rules in [AGENTS.md](AGENTS.md)).
- **Build number** (`CFBundleVersion`) is the git commit count, stamped automatically; commit before building
  a release so the build maps to an exact commit.
- The main menu shows both (`V1.0.0 · BUILD 3`).

```sh
./scripts/build_app.sh   # universal app, Developer ID signed when available
./scripts/make_dmg.sh    # build/Tetris3D-<version>-<build>.dmg, notarized and stapled
```

Notarization needs a one-time keychain profile:
`xcrun notarytool store-credentials tetris3d --apple-id <Apple ID> --team-id <Team ID>`.

## Controls

| Key | Action |
| --- | --- |
| ← → | Move |
| ↓ | Soft drop |
| Space | Hard drop |
| ↑ / X, Z | Rotate CW / CCW |
| C / Shift | Hold |
| P / Esc | Pause |

## Layout

- `Sources/TetrisCore` — pure game rules (SRS, 7-bag, lock delay, scoring, T-spins, modes, autopilot)
- `Sources/MetaGame` — profile, stats, leaderboards, achievements (persisted to `~/Library/Application Support/Tetris3D/profile.json`)
- `Sources/Tetris3D` — app: Metal renderer, scene/animation, SwiftUI HUD & menus, `Audio/` synth engine, `Badges/` 3D badge renderer
- `scripts/make_icon.swift` — regenerates the app icon source image
