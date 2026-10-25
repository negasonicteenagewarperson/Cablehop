#!/bin/zsh
# Builds Cablehop.app (universal: Apple silicon + Intel) into ./build
set -euo pipefail
cd "$(dirname "$0")/.."

YEAR=$(date +%Y)

source Scripts/env.sh

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Cablehop"
APP=build/Cablehop.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cablehop"

# Icon
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
swift Scripts/make-icon.swift "$ICONSET/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Cablehop</string>
  <key>CFBundleDisplayName</key><string>Cablehop</string>
  <key>CFBundleIdentifier</key><string>app.cablehop.Cablehop</string>
  <key>CFBundleExecutable</key><string>Cablehop</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>© ${YEAR} Cablehop contributors</string>
  <key>NSLocalNetworkUsageDescription</key><string>Cablehop finds and connects to Android phones on your Wi-Fi network for wireless file transfer.</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_adb-tls-pairing._tcp</string>
    <string>_adb-tls-connect._tcp</string>
    <string>_adb._tcp</string>
  </array>
</dict>
</plist>
PLIST

codesign --force --options runtime --sign - "$APP" >/dev/null
echo "Built $APP (version $VERSION, $(lipo -archs "$APP/Contents/MacOS/Cablehop"))"
