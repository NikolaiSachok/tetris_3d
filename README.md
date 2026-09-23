# Tetris 3D

A native macOS Tetris with a Metal renderer: shadow-mapped PBR candy-glass blocks, HDR bloom, ACES tone mapping,
a procedural starfield/nebula backdrop, particles, synthesized music and sound effects, five game modes,
achievements with 3D badges, stats and local leaderboards.

## Build & run

```sh
./scripts/build_app.sh      # builds build/Tetris3D.app (release, ad-hoc signed)
open build/Tetris3D.app
swift test                  # rules, scoring, modes, meta-game
```

Requires macOS 14+ and Xcode (Swift 6). Shaders are compiled at runtime, so the offline Metal toolchain is not needed.

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
