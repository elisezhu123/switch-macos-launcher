#!/bin/zsh
# Build the launcher, strip the quarantine attribute and pack it for a GitHub release.
set -e
cd "$(dirname "$0")/.."
VERSION="${1:-1.3.0}"
./build.sh "$VERSION"
APP="sw-launcher.app"
xattr -cr "$APP"                                   # no com.apple.quarantine inside the bundle we ship
if xattr -lr "$APP" | grep -q com.apple.quarantine; then echo "quarantine attribute is still present" >&2; exit 1; fi
mkdir -p dist
ZIP="dist/sw-launcher-v${VERSION}-arm64.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noacl --noqtn "$APP" "$ZIP"   # no AppleDouble files, no quarantine
( cd dist && shasum -a 256 "$(basename "$ZIP")" | tee "$(basename "$ZIP").sha256" )
echo "ready: $ZIP"
