#!/bin/sh
# make_package.sh — build a universal NeedleMac.app and bundle it into an
# install package that needs NO dev tools on the target Mac.
#
#   ./make_package.sh          -> dist/needle-mac-<version>-macos.tar.gz
#                                 dist/needle-mac-<version>-macos.dmg
#
# The target Mac (Apple Silicon or Intel, macOS 13+) just:
#   tar xzf needle-mac-*-macos.tar.gz && cd needle-mac && ./install.sh
set -eu
cd "$(dirname "$0")"

VERSION=$(sed -n 's|.*CFBundleShortVersionString</key><string>\(.*\)</string>.*|\1|p' Info.plist)
[ -n "$VERSION" ] || VERSION="0.1"
STAGE="dist/needle-mac"
OUT_DIR="dist"

rm -rf "$STAGE" "$OUT_DIR/NeedleMac.app"
mkdir -p "$OUT_DIR"

# --- universal build (arm64 + x86_64) --------------------------------------
APP="NeedleMac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -target arm64-apple-macos13  Sources/needle-mac/main.swift -o /tmp/needle-arm64  -framework Cocoa -framework Carbon
swiftc -O -target x86_64-apple-macos13 Sources/needle-mac/main.swift -o /tmp/needle-x86_64 -framework Cocoa -framework Carbon 2>/dev/null || \
    echo "note: x86_64 slice failed (this Mac's SDK); packaging arm64 only"
if [ -f /tmp/needle-x86_64 ]; then
    lipo -create /tmp/needle-arm64 /tmp/needle-x86_64 -output "$APP/Contents/MacOS/needle-mac"
else
    cp /tmp/needle-arm64 "$APP/Contents/MacOS/needle-mac"
fi
lipo -archs "$APP/Contents/MacOS/needle-mac"

cp Info.plist "$APP/Contents/Info.plist"
[ -f NeedleMac.icns ] && cp NeedleMac.icns "$APP/Contents/Resources/app.icns"

# sign: the local developer identity when present, else ad-hoc (both are fine
# for a copy-based install; the package tar does not set quarantine bits).
# Any "Apple Development" identity in the keychain is picked automatically.
IDENTITY=$(security find-identity -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: .*\)".*/\1/p' | head -1)
if [ -n "$IDENTITY" ]; then
    codesign --force --deep --sign "$IDENTITY" --identifier local.needle-mac "$APP"
else
    codesign --force --deep --sign - --identifier local.needle-mac "$APP"
fi

# --- the package payload ----------------------------------------------------
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp install-package.sh "$STAGE/install.sh"
cp config.example "$STAGE/config.example"
cp README.md "$STAGE/README.md"
chmod +x "$STAGE/install.sh"

TARBALL="$OUT_DIR/needle-mac-$VERSION-macos.tar.gz"
tar -czf "$TARBALL" -C "$OUT_DIR" "needle-mac"

# a DMG too (drag-to-Applications friendly): app + installer alias + README
DMG="$OUT_DIR/needle-mac-$VERSION-macos.dmg"
DMG_DIR="$OUT_DIR/dmg-root"
rm -rf "$DMG_DIR"; mkdir -p "$DMG_DIR"
cp -R "$APP" "$DMG_DIR/"
cp README.md "$DMG_DIR/README.md"
cp install-package.sh "$DMG_DIR/install.command"
chmod +x "$DMG_DIR/install.command"
hdiutil create -volname "needle-mac" -srcfolder "$DMG_DIR" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_DIR"

echo
echo "package built:"
echo "  $(pwd)/$TARBALL"
echo "  $(pwd)/$DMG"
