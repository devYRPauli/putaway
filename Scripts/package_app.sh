#!/usr/bin/env bash
# Builds build/Putaway.app (the menu bar app, with the putaway CLI in Contents/Helpers)
# and build/Putaway.zip, the release asset that install.sh downloads.
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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/PutawayApp" "$APP/Contents/MacOS/Putaway"
cp "$BIN/putaway" "$APP/Contents/Helpers/putaway"

ICONSET=build/Putaway.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift Scripts/make_icon.swift build/icon_1024.png
for sz in 16 32 128 256 512; do
  sips -z "$sz" "$sz" build/icon_1024.png --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  sips -z $((sz * 2)) $((sz * 2)) build/icon_1024.png --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Putaway.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Putaway</string>
    <key>CFBundleDisplayName</key><string>Putaway</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>Putaway</string>
    <key>CFBundleIconFile</key><string>Putaway</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSDownloadsFolderUsageDescription</key><string>Putaway reads the files in Downloads to suggest where each one goes.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>Putaway files things into the folders in Documents.</string>
    <key>NSDesktopFolderUsageDescription</key><string>Putaway can tidy your Desktop or file things into folders there.</string>
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
rm -f build/Putaway.zip
ditto --norsrc -c -k --keepParent "$APP" build/Putaway.zip
echo "Built $APP and build/Putaway.zip ($VERSION, build $BUILD_NUMBER)"
