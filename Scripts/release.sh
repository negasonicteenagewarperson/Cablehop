#!/bin/zsh
# Tests, builds and packages Cablehop for a GitHub release:
#   dist/Cablehop-<version>.dmg, dist/Cablehop-<version>.zip and SHA256SUMS.txt
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/env.sh

./Scripts/test.sh
./Scripts/build-app.sh

DIST=dist
NAME="Cablehop-$VERSION"
mkdir -p "$DIST"
rm -f "$DIST/$NAME.dmg" "$DIST/$NAME.zip" "$DIST/SHA256SUMS.txt" "$DIST/SHA256SUMS.txt.sig"

# Disk image with a styled drag-to-Applications window (and signing/notarization if configured).
./Scripts/make-dmg.sh

# Zip, for people who prefer it (keeps the code signature and extended attributes intact).
ditto -c -k --sequesterRsrc --keepParent build/Cablehop.app "$DIST/$NAME.zip"

(cd "$DIST" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)
# Sign the checksum list; the in-app updater only installs releases signed with this key.
swift Scripts/sign-release.swift "$DIST/SHA256SUMS.txt"
echo "Release $VERSION ready in $DIST/:"
ls -lh "$DIST"
