#!/usr/bin/env bash
# Builds a release binary and wraps it into NotchIsland.app (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib_sign.sh

swift build -c release --build-system native
BIN_DIR=$(swift build -c release --build-system native --show-bin-path)

APP="build/NotchIsland.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/NotchIsland" "$APP/Contents/MacOS/NotchIsland"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Translations (en, es, fr, de, hi, ja, zh-Hans).
cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
# Sparkle (automatic updates).
embed_sparkle "$APP" "$BIN_DIR"

# Sign with a stable identity when there is one, so macOS keeps Accessibility and other
# permissions across rebuilds (ad-hoc signatures change every build, and permissions reset).
# Override with SIGN_IDENTITY="..."; SIGN_IDENTITY=- forces ad-hoc.
if [[ -z ${SIGN_IDENTITY:-} ]]; then
  identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
  SIGN_IDENTITY=$(printf '%s\n' "$identities" | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
  [[ -z $SIGN_IDENTITY ]] && SIGN_IDENTITY=$(printf '%s\n' "$identities" | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
  [[ -z $SIGN_IDENTITY ]] && SIGN_IDENTITY="-"
fi
if [[ $SIGN_IDENTITY == "-" ]]; then
  echo "Signing ad-hoc (permissions reset on every rebuild — see docs/RELEASING.md)"
  sign_app "$APP" - dev
else
  echo "Signing with: $SIGN_IDENTITY"
  sign_app "$APP" "$SIGN_IDENTITY" dev Resources/NotchIsland.entitlements
fi

echo "Built $APP"
echo "Run it with: open $APP"
