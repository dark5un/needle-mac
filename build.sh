#!/bin/sh
# build.sh — compile needle-mac and assemble NeedleMac.app (a menu-bar
# daemon; the .app bundle is what makes the Services menu entries work).
set -eu
cd "$(dirname "$0")"

swiftc -O Sources/needle-mac/main.swift -o needle-mac \
    -framework Cocoa -framework Carbon

APP=NeedleMac.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp needle-mac "$APP/Contents/MacOS/needle-mac"
cp Info.plist "$APP/Contents/Info.plist"
[ -f NeedleMac.icns ] && cp NeedleMac.icns "$APP/Contents/Resources/app.icns"

# sign with a local developer identity when present (stable across rebuilds,
# so the Accessibility grant survives); fall back to ad-hoc. Any "Apple
# Development" identity in the keychain is picked automatically.
IDENTITY=$(security find-identity -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: .*\)".*/\1/p' | head -1)
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" --identifier local.needle-mac "$APP"
else
    codesign --force --sign - --identifier local.needle-mac "$APP"
fi

echo "built: $(pwd)/$APP"
