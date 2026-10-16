#!/usr/bin/env bash
# Builds build/Putaway.app: the menu bar app, with the putaway CLI in Contents/Helpers.
# Signs ad hoc unless APP_IDENTITY names a "Developer ID Application" certificate.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUNDLE_ID="io.github.devyrpauli.putaway"

swift build -c release --product PutawayApp
swift build -c release --product putaway
BIN="$(swift build -c release --show-bin-path)"

APP=build/Putaway.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers"
cp "$BIN/PutawayApp" "$APP/Contents/MacOS/Putaway"
cp "$BIN/putaway" "$APP/Contents/Helpers/putaway"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Putaway</string>
    <key>CFBundleDisplayName</key><string>Putaway</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>Putaway</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>Tidy with Putaway</string></dict>
            <key>NSMessage</key><string>tidyFolder</string>
            <key>NSPortName</key><string>Putaway</string>
            <key>NSRequiredContext</key><dict/>
            <key>NSSendFileTypes</key><array><string>public.folder</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

if [[ -n "${APP_IDENTITY:-}" ]]; then
  SIGN=(--force --timestamp --options runtime --sign "$APP_IDENTITY")
else
  SIGN=(--force --sign -)
fi
codesign "${SIGN[@]}" "$APP/Contents/Helpers/putaway"
codesign "${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($VERSION, build $BUILD_NUMBER)"
