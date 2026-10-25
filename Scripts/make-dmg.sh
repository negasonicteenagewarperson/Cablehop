#!/bin/zsh
# Packages build/Cablehop.app into dist/Cablehop-<version>.dmg: a drag-to-Applications window with
# a custom background and volume icon.
#
# Optional, for a DMG that opens with no Gatekeeper warning on any Mac:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"  signs the app and the DMG
#   NOTARY_PROFILE=<name>  notarizes and staples it (create once with `xcrun notarytool store-credentials`)
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/env.sh

APP=build/Cablehop.app
[[ -d $APP ]] || { echo "Build the app first: ./Scripts/build-app.sh" >&2; exit 1; }
NAME="Cablehop-$VERSION"
VOLUME="Cablehop $VERSION"
OUT="dist/$NAME.dmg"
mkdir -p dist

if [[ -n ${DEVELOPER_ID:-} ]]; then
  echo "Signing with $DEVELOPER_ID"
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
fi

WORK=$(mktemp -d)
MOUNT="$WORK/mount"
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"

# Background, 1x + 2x combined so Retina screens get the sharp one.
swift Scripts/make-dmg-background.swift "$WORK" "$VERSION"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$STAGE/.background/background.tiff" 2>/dev/null

# Writable image first, so Finder can save the window layout into it.
RW="$WORK/rw.dmg"
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
mkdir -p "$MOUNT"
hdiutil attach -quiet -readwrite -noverify -noautoopen -mountpoint "$MOUNT" "$RW"
SetFile -c icnC "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"

# Lay out the window. Finder can only be scripted with your permission; if that's declined the DMG
# still works, it just opens with Finder's default layout.
if ! osascript <<APPLESCRIPT 2>"$WORK/finder.log"
tell application "Finder"
  set dmgFolder to (POSIX file "$MOUNT") as alias
  open dmgFolder
  set theWindow to container window of dmgFolder
  set current view of theWindow to icon view
  set toolbar visible of theWindow to false
  set statusbar visible of theWindow to false
  set bounds of theWindow to {200, 120, 860, 568}
  set viewOptions to icon view options of theWindow
  set arrangement of viewOptions to not arranged
  set icon size of viewOptions to 128
  set text size of viewOptions to 13
  set background picture of viewOptions to file ".background:background.tiff" of dmgFolder
  set position of item "Cablehop.app" of dmgFolder to {170, 200}
  set position of item "Applications" of dmgFolder to {490, 200}
  update dmgFolder without registering applications
  delay 1
  close theWindow
end tell
APPLESCRIPT
then
  echo "warning: couldn't arrange the DMG window ($(cat "$WORK/finder.log")); using Finder's default layout" >&2
fi

sync
hdiutil detach -quiet "$MOUNT"
rm -f "$OUT"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT"

if [[ -n ${DEVELOPER_ID:-} ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$OUT"
  if [[ -n ${NOTARY_PROFILE:-} ]]; then
    echo "Notarizing (this takes a few minutes)…"
    xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT"
  fi
fi

echo "Created $OUT ($(du -h "$OUT" | cut -f1))"
