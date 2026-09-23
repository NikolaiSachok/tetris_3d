# Agent guide

Native macOS Tetris in Swift 6 + Metal. See README.md for architecture, build and release.

## Commands

- Test: `swift test` (must stay green, zero warnings)
- Build app: `./scripts/build_app.sh` → `build/Tetris3D.app`
- Release: `./scripts/make_dmg.sh` → notarized `build/Tetris3D-<version>-<build>.dmg`

## Versioning (required)

The version in `VERSION` follows semantic versioning and is bumped with every change that reaches a user,
in the same commit as the change:

| Change | Command | Example |
| --- | --- | --- |
| Bug fix, tuning, polish | `./scripts/bump_version.sh patch` | 1.0.0 → 1.0.1 |
| New feature, mode, screen, content | `./scripts/bump_version.sh minor` | 1.0.1 → 1.1.0 |
| Breaking change (e.g. save data reset), major overhaul | `./scripts/bump_version.sh major` | 1.1.0 → 2.0.0 |

- A commit containing several changes gets one bump, at the highest level among them.
- Changes invisible to users (tests, docs, scripts, refactors without behaviour change) do not bump.
- Never edit the build number: it is the git commit count, stamped by `build_app.sh`.
- Mention the new version in the commit message, e.g. `Fix hold during line clear (1.0.1)`.

## Commits

- Do not add AI co-author or attribution lines to commit messages.
- Once an issue is implemented and `swift test` is green, commit and push without asking.
