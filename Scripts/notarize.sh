#!/usr/bin/env bash
# Builds a Developer ID signed, notarized, stapled build/Putaway-<version>.zip for release.
# One-time setup: xcrun notarytool store-credentials putaway --apple-id <id> --team-id <team>
# Usage: APP_IDENTITY="Developer ID Application: Name (TEAMID)" VERSION=0.1.0 Scripts/notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${APP_IDENTITY:?set APP_IDENTITY to your Developer ID Application certificate name}"
: "${VERSION:?set VERSION, e.g. 0.1.0}"
PROFILE="${NOTARY_PROFILE:-putaway}"

Scripts/package_app.sh
APP=build/Putaway.app
ZIP="build/Putaway-${VERSION}.zip"

rm -f "$ZIP"
ditto --norsrc -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -t exec -vv "$APP"

# Re-zip so the download carries the stapled ticket.
rm -f "$ZIP"
xattr -cr "$APP"
ditto --norsrc -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"
