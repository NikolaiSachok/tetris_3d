#!/bin/zsh
# Packages build/Tetris3D.app into a signed, notarized and stapled build/Tetris3D-<version>-<build>.dmg that opens
# cleanly on any Mac running macOS 14+.
#
# One-time setup (stores notarization credentials in the keychain; use an app-specific password
# from https://account.apple.com):
#   xcrun notarytool store-credentials tetris3d --apple-id <your Apple ID> --team-id <Team ID>
# Set NOTARY_PROFILE to use a different profile name; NOTARY_PROFILE=none skips notarization.
set -euo pipefail

root="${0:A:h:h}"
profile="${NOTARY_PROFILE:-tetris3d}"
staging="$root/build/dmg"

app="$("$root/scripts/build_app.sh")"
info="$app/Contents/Info.plist"
dmg="$root/build/Tetris3D-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$info")-$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$info").dmg"
identity="$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)/\1/p' | head -1)"
[[ -n "$identity" ]] || { echo "The app is not signed with a Developer ID; cannot notarize." >&2; exit 1; }

rm -rf "$staging" "$dmg"
mkdir -p "$staging"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Tetris 3D" -srcfolder "$staging" -fs HFS+ -format UDZO "$dmg" >/dev/null
rm -rf "$staging"
codesign --force --timestamp --sign "$identity" "$dmg"

if [[ "$profile" != "none" ]]; then
    xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose "$dmg"
fi

echo "$dmg"
