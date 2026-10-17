#!/bin/sh
# install.sh — build and install needle-mac on any Apple Silicon Mac.
#   ./install.sh            build + install to ~/Applications + launch once
set -eu
cd "$(dirname "$0")"

command -v swiftc >/dev/null || {
    echo "needle-mac: swiftc not found. Install the Command Line Tools: xcode-select --install" >&2
    exit 1
}

./build.sh

APP="$HOME/Applications/NeedleMac.app"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R NeedleMac.app "$APP"

# config: never overwrite an existing one
CFG_DIR="$HOME/.config/needle-mac"
mkdir -p "$CFG_DIR"
[ -f "$CFG_DIR/config" ] || cp config.example "$CFG_DIR/config"

# run once now so the Services menu registers; autostart is the app's own
# "Launch at login" menu toggle (no launchd)
open "$APP"
echo "installed: $APP"

echo
echo "Next steps:"
echo "  1. Edit $CFG_DIR/config (endpoint, model, fallback)."
echo "  2. System Settings > Privacy & Security > Accessibility: allow needle-mac"
echo "     (needed only for the hotkey capture/paste path; the Services menu works without it)."
echo "  3. Optional: the menu-bar icon has a 'Launch at login' toggle."
echo "  4. Try it:  echo 'fix ths txt' | $APP/Contents/MacOS/needle-mac proofread"
echo "  5. Right-click selected text in any app > Services > needle: <action>."
