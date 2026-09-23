#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) release binary and wraps it in build/Tetris3D.app,
# stamped with the version from VERSION and the git commit count as the build number.
# Signs with the first "Developer ID Application" identity in the keychain (hardened runtime, ready for
# notarization), or ad-hoc when none is available. Override with SIGN_IDENTITY="..." or SIGN_IDENTITY=-.
set -euo pipefail

root="${0:A:h:h}"
app="$root/build/Tetris3D.app"
arch_flags=(--arch arm64 --arch x86_64)

swift build -c release "${arch_flags[@]}" --package-path "$root" >&2
bin="$(swift build -c release "${arch_flags[@]}" --package-path "$root" --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Tetris3D" "$app/Contents/MacOS/Tetris3D"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"

# Version comes from the VERSION file; the build number is the commit count, so it only ever increases.
version="$(tr -d '[:space:]' < "$root/VERSION")"
build="$(git -C "$root" rev-list --count HEAD)"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" \
    -c "Add :CFBundleVersion string $build" "$app/Contents/Info.plist"
if [[ -n "$(git -C "$root" status --porcelain)" ]]; then
    echo "Warning: uncommitted changes; build $build does not match a commit exactly" >&2
fi
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
if [[ -n "$identity" && "$identity" != "-" ]]; then
    codesign --force --options runtime --timestamp --sign "$identity" "$app"
    echo "Signed with: $identity" >&2
else
    codesign --force --sign - "$app"
    echo "Signed ad-hoc (runs only on this Mac without Gatekeeper prompts)" >&2
fi

echo "Version $version (build $build)" >&2
echo "$app"
