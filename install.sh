#!/bin/sh
# install.sh — build and install needle-mac on any Apple Silicon Mac.
#   ./install.sh            build + install to ~/Applications + autostart
#   ./install.sh --no-autostart   skip the login item
set -eu
cd "$(dirname "$0")"

NO_AUTOSTART=0
[ "${1:-}" = "--no-autostart" ] && NO_AUTOSTART=1

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

if [ "$NO_AUTOSTART" -eq 0 ]; then
    PLIST="$HOME/Library/LaunchAgents/local.needle-mac.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    sed "s|@APP@|$APP|g" launchd.plist.example > "$PLIST"
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    echo "installed + autostart enabled: $APP"
else
    # run once now so the Services menu registers
    open "$APP"
    echo "installed: $APP"
fi

echo
echo "Next steps:"
echo "  1. Edit $CFG_DIR/config (endpoint, model, fallback)."
echo "  2. System Settings > Privacy & Security > Accessibility: allow needle-mac"
echo "     (needed only for the hotkey capture/paste path; the Services menu works without it)."
echo "  3. Try it:  echo 'fix ths txt' | $APP/Contents/MacOS/needle-mac proofread"
echo "  4. Right-click selected text in any app > Services > needle: <action>."
