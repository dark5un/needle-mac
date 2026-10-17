#!/bin/sh
# install.sh — needle-mac installer for a packaged (pre-built) copy.
# Needs NO dev tools on the target Mac: no Xcode, no swiftc.
#   ./install.sh                  install + autostart at login
#   ./install.sh --no-autostart   install only
set -eu
cd "$(dirname "$0")"

[ -d NeedleMac.app ] || { echo "needle-mac: NeedleMac.app not next to this script" >&2; exit 1; }

NO_AUTOSTART=0
ENDPOINT="" ; MODEL="" ; FALLBACK_URL="" ; FALLBACK_MODEL="" ; FALLBACK_KEY="" ; KEY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-autostart)  NO_AUTOSTART=1 ;;
        --endpoint)      ENDPOINT="$2"; shift ;;
        --model)         MODEL="$2"; shift ;;
        --key)           KEY="$2"; shift ;;
        --fallback-url)   FALLBACK_URL="$2"; shift ;;
        --fallback-model) FALLBACK_MODEL="$2"; shift ;;
        --fallback-key)   FALLBACK_KEY="$2"; shift ;;
        *) echo "needle-mac: unknown option $1" >&2; exit 64 ;;
    esac
    shift
done

APP="$HOME/Applications/NeedleMac.app"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R NeedleMac.app "$APP"

# config: never overwrite an existing one
CFG_DIR="$HOME/.config/needle-mac"
mkdir -p "$CFG_DIR"
if [ ! -f "$CFG_DIR/config" ]; then
    cp config.example "$CFG_DIR/config"
    # apply connection details given on the command line (they edit the local
    # config only; nothing is baked into the app or the package)
    set_key() {  # $1 = config key, $2 = value; awk avoids sed metachar issues
        # escape & in the replacement (awk reads it as "the whole match")
        awk -v k="$1" -v v="$2" 'BEGIN { gsub(/&/, "\\\\&", v) }
            { if ($0 ~ "^"k"[ \t]*=") sub(/=.*/, "= " v); print }' \
            "$CFG_DIR/config" > "$CFG_DIR/config.tmp" && mv "$CFG_DIR/config.tmp" "$CFG_DIR/config"
    }
    [ -n "$ENDPOINT" ]      && set_key endpoint "$ENDPOINT"
    [ -n "$MODEL" ]         && set_key model "$MODEL"
    [ -n "$FALLBACK_URL" ]  && set_key fallback_endpoint "$FALLBACK_URL"
    [ -n "$FALLBACK_MODEL" ] && set_key fallback_model "$FALLBACK_MODEL"
fi
# keys go to a mode-600 env file, never into the config or the app.
# Prefer --key-file (a path) or the interactive prompt over --key on argv:
# argv is visible in the process table and shell history.
umask 077
write_env() {  # $1 = file, $2 = value
    printf 'API_KEY=%s\n' "$2" > "$1"
    chmod 600 "$1"
}
if [ -n "$KEY" ]; then write_env "$CFG_DIR/engine.env" "$KEY"; fi
if [ -n "$FALLBACK_KEY" ]; then
    write_env "$CFG_DIR/fallback.env" "$FALLBACK_KEY"
    awk -v f="$CFG_DIR/fallback.env" '{ if ($0 ~ /^fallback_key_file/) sub(/=.*/, "= " f); print }' \
        "$CFG_DIR/config" > "$CFG_DIR/config.tmp" && mv "$CFG_DIR/config.tmp" "$CFG_DIR/config"
fi
[ -f "$CFG_DIR/engine.env" ] || [ -f "$CFG_DIR/fallback.env" ] || {
    # no key given on the command line: offer to enter it without echoing
    if [ -t 0 ] && [ -n "$FALLBACK_URL" ]; then
        printf 'Fallback endpoint needs an API key? Enter it (empty to skip, not echoed): '
        read -r FK
        if [ -n "$FK" ]; then
            write_env "$CFG_DIR/fallback.env" "$FK"
            awk -v f="$CFG_DIR/fallback.env" '{ if ($0 ~ /^fallback_key_file/) sub(/=.*/, "= " f); print }' \
                "$CFG_DIR/config" > "$CFG_DIR/config.tmp" && mv "$CFG_DIR/config.tmp" "$CFG_DIR/config"
        fi
    fi
}

if [ "$NO_AUTOSTART" -eq 0 ]; then
    PLIST="$HOME/Library/LaunchAgents/local.needle-mac.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    sed "s|@APP@|$APP|g" <<'EOF' > "$PLIST"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.needle-mac</string>
  <key>ProgramArguments</key>
  <array>
    <string>@APP@/Contents/MacOS/needle-mac</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/needle-mac.out</string>
  <key>StandardErrorPath</key><string>/tmp/needle-mac.err</string>
</dict>
</plist>
EOF
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    echo "installed + autostart enabled: $APP"
else
    open "$APP"
    echo "installed: $APP"
fi

echo
echo "Next steps:"
echo "  1. Edit $CFG_DIR/config — point 'endpoint' at your local engine"
echo "     (Strata: http://127.0.0.1:8080/v1, Ollama: http://127.0.0.1:11434/v1)."
echo "     Optional fallback_* keys: a second OpenAI-compatible endpoint."
echo "  2. System Settings > Privacy & Security > Accessibility: enable needle-mac"
echo "     (needed for the hotkey path; the Services right-click menu works without it)."
echo "  3. Select text, press ctrl+opt+o (replace) or ctrl+opt+i (clipboard only)."
