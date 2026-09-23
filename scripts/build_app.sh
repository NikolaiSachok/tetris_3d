#!/bin/zsh
# Builds a release binary and wraps it in build/Tetris3D.app (ad-hoc signed).
set -euo pipefail

root="${0:A:h:h}"
app="$root/build/Tetris3D.app"

swift build -c release --package-path "$root"
bin="$(swift build -c release --package-path "$root" --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Tetris3D" "$app/Contents/MacOS/Tetris3D"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
if [[ -f "$root/Resources/AppIcon.icns" ]]; then
    cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$app" >/dev/null

echo "$app"
