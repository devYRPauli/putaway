#!/bin/bash
# Installs Putaway: curl -fsSL https://raw.githubusercontent.com/devYRPauli/putaway/main/install.sh | bash
# Puts Putaway.app in ~/Applications and links the putaway command into ~/.local/bin.
set -euo pipefail

ZIP_URL="https://github.com/devYRPauli/putaway/releases/latest/download/Putaway.zip"
APPS="$HOME/Applications"
BIN="$HOME/.local/bin"

fail() { echo "putaway: $1" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail "Putaway runs on macOS only."
[[ "$(uname -m)" == arm64 ]] || fail "Putaway needs a Mac with Apple silicon."
(( "$(sw_vers -productVersion | cut -d. -f1)" >= 26 )) || fail "Putaway needs macOS 26 or later."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "Downloading Putaway..."
curl -fsSL "$ZIP_URL" -o "$tmp/Putaway.zip"
ditto -x -k "$tmp/Putaway.zip" "$tmp"
[[ -d "$tmp/Putaway.app" ]] || fail "the download did not contain Putaway.app."

pkill -x Putaway 2>/dev/null || true
mkdir -p "$APPS" "$BIN"
rm -rf "$APPS/Putaway.app"
mv "$tmp/Putaway.app" "$APPS/"
ln -sf "$APPS/Putaway.app/Contents/Helpers/putaway" "$BIN/putaway"

echo "Installed $APPS/Putaway.app"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "To use the putaway command, add $BIN to your PATH." ;;
esac
open "$APPS/Putaway.app"
