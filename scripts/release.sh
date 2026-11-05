#!/usr/bin/env bash
# Builds a signed, notarized NotchIsland-<version>.dmg ready to upload.
#
# One-time setup (see docs/RELEASING.md):
#   1. A "Developer ID Application" certificate in your login keychain.
#   2. xcrun notarytool store-credentials notchisland --apple-id you@example.com --team-id TEAMID
#
# Usage:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" scripts/release.sh
# Options (environment):
#   NOTARY_PROFILE  keychain profile from step 2 (default: notchisland)
#   ARCHS           architectures to build (default: "arm64 x86_64" = universal)
#   SKIP_NOTARIZE=1 sign only (for a quick local check)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib_sign.sh

# Where releases live (GitHub Releases of the public repo) and the website's appcast.
DOWNLOAD_BASE="https://github.com/ashikahmed001/notchisland/releases/download"
RELEASE_NOTES_URL="https://ashikahmed001.github.io/notchisland/changelog.html"
APPCAST="website/appcast.xml"

: "${DEVELOPER_ID:?Set DEVELOPER_ID, e.g. \"Developer ID Application: Your Name (TEAMID)\" — list yours with: security find-identity -v -p codesigning}"
NOTARY_PROFILE=${NOTARY_PROFILE:-notchisland}
ARCHS=${ARCHS:-"arm64 x86_64"}
SKIP_NOTARIZE=${SKIP_NOTARIZE:-0}

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)
OUT="build/release"
APP="$OUT/NotchIsland.app"
# Same file name every release, so the website's ".../releases/latest/download/NotchIsland.dmg" always works.
DMG="$OUT/NotchIsland.dmg"
ENTITLEMENTS="Resources/NotchIsland.entitlements"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# Automatic updates only when Sparkle is set up (public key in Info.plist + Sparkle in Package.swift).
UPDATES=1
grep -q "REPLACE_WITH_SPARKLE_PUBLIC_KEY" Resources/Info.plist && UPDATES=0
grep -q "sparkle-project\|Vendor/Sparkle" Package.swift || UPDATES=0
if [[ $UPDATES == 1 && -x Vendor/Sparkle/bin/generate_keys ]]; then
  # The public key in the app must match the private key in your Keychain, or no
  # update would ever be accepted by users' Macs.
  KEYCHAIN_PUB=$(Vendor/Sparkle/bin/generate_keys -p 2>/dev/null | tail -1 | tr -d '[:space:]')
  PLIST_PUB=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Resources/Info.plist)
  [[ -n $KEYCHAIN_PUB && $KEYCHAIN_PUB == "$PLIST_PUB" ]] \
    || fail "SUPublicEDKey in Info.plist ($PLIST_PUB) doesn't match your Sparkle key ($KEYCHAIN_PUB)."
fi
security find-identity -v -p codesigning | grep -qF "$DEVELOPER_ID" \
  || fail "No signing identity named \"$DEVELOPER_ID\" in your keychain."
if [[ $SKIP_NOTARIZE != 1 ]]; then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "Notary profile \"$NOTARY_PROFILE\" not found. Run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <email> --team-id <TEAMID>"
fi

step "Building $VERSION ($BUILD) for: $ARCHS"
rm -rf "$OUT"; mkdir -p "$OUT"
binaries=()
for arch in $ARCHS; do
  swift build -c release --build-system native --arch "$arch" --scratch-path ".build/release-$arch"
  bin_dir=$(swift build -c release --build-system native --arch "$arch" --scratch-path ".build/release-$arch" --show-bin-path)
  binaries+=("$bin_dir/NotchIsland")
done

step "Assembling the app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if (( ${#binaries[@]} > 1 )); then
  lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/NotchIsland"
else
  cp "${binaries[0]}" "$APP/Contents/MacOS/NotchIsland"
fi
lipo -info "$APP/Contents/MacOS/NotchIsland"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
# Sparkle (its macOS slice is already universal, so either build's copy will do).
first_arch=${ARCHS%% *}
embed_sparkle "$APP" "$(swift build -c release --build-system native --arch "$first_arch" --scratch-path ".build/release-$first_arch" --show-bin-path)"
# Bundled resources from SwiftPM targets, if any.
for arch in $ARCHS; do
  bin_dir=$(swift build -c release --build-system native --arch "$arch" --scratch-path ".build/release-$arch" --show-bin-path)
  for bundle in "$bin_dir"/*.bundle; do
    [[ -e $bundle ]] && cp -R "$bundle" "$APP/Contents/Resources/"
  done
  break
done
xattr -cr "$APP"

step "Signing (hardened runtime)"
sign_app "$APP" "$DEVELOPER_ID" release "$ENTITLEMENTS"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q apple-events || fail "Entitlements missing from signature"

notarize() {   # $1 = file to submit
  # The login keychain can lock during a long wait (sleep, screen lock): unlock it first.
  security unlock-keychain "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null || true
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json \
    > "$OUT/notary.json" 2> "$OUT/notary.err" || true
  if ! grep -q '"status" *: *"Accepted"' "$OUT/notary.json"; then
    id=$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' "$OUT/notary.json" | head -1)
    if [[ -z $id ]]; then
      # Never reached Apple (credentials, keychain, network) — not a rejection.
      cat "$OUT/notary.err" >&2
      fail "Couldn't submit $(basename "$1") to Apple (see above). Nothing was rejected; fix that and run again."
    fi
    cat "$OUT/notary.json"
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE"
    fail "Notarization of $(basename "$1") was rejected (Apple's log above)."
  fi
}

if [[ $SKIP_NOTARIZE != 1 ]]; then
  step "Notarizing the app (usually a few minutes)"
  ditto -c -k --keepParent "$APP" "$OUT/NotchIsland.zip"
  notarize "$OUT/NotchIsland.zip"
  xcrun stapler staple "$APP"
  rm "$OUT/NotchIsland.zip"
fi

step "Making the disk image"
staging="$OUT/dmg"
mkdir -p "$staging"
cp -R "$APP" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Notch Island" -srcfolder "$staging" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$staging"
codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"

if [[ $SKIP_NOTARIZE != 1 ]]; then
  step "Notarizing the disk image"
  notarize "$DMG"
  xcrun stapler staple "$DMG"

  step "Checking what Gatekeeper will say"
  spctl --assess --type execute --verbose=2 "$APP"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"

if [[ $SKIP_NOTARIZE != 1 && $UPDATES == 1 ]]; then
  step "Adding $VERSION to the update feed ($APPCAST)"
  SIGN_UPDATE=$(sparkle_tool sign_update) || true
  [[ -n ${SIGN_UPDATE:-} ]] || fail "Sparkle's sign_update not found (run: swift package resolve)"
  # → sparkle:edSignature="…" length="…"  (uses the private key in your Keychain)
  SIGNATURE=$("$SIGN_UPDATE" "$DMG")
  [[ $SIGNATURE == *edSignature* ]] || fail "sign_update failed: $SIGNATURE"
  PUB_DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
  MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Resources/Info.plist)
  ITEM="    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$RELEASE_NOTES_URL</sparkle:releaseNotesLink>
      <enclosure url=\"$DOWNLOAD_BASE/v$VERSION/NotchIsland.dmg\" type=\"application/octet-stream\" $SIGNATURE/>
    </item>"
  # Newest first; replaces an earlier entry for the same build.
  ITEM="$ITEM" BUILD="$BUILD" APPCAST="$APPCAST" python3 - <<'PY'
import os, re
path, item, build = os.environ["APPCAST"], os.environ["ITEM"], os.environ["BUILD"]
xml = open(path, encoding="utf-8").read()
xml = re.sub(r"\s*<item>(?:(?!</item>).)*?<sparkle:version>%s</sparkle:version>.*?</item>" % re.escape(build), "", xml, flags=re.S)
marker = "<!-- releases (newest first) -->"
xml = xml.replace(marker, marker + "\n" + item, 1)
open(path, "w", encoding="utf-8").write(xml)
PY
  echo "Appcast updated. After publishing the GitHub release (tag v$VERSION), push $APPCAST to the website."
fi
printf '\n\033[32m✓ %s\033[0m  (%s)  version %s (build %s)\n' "$DMG" "$(du -h "$DMG" | cut -f1)" "$VERSION" "$BUILD"
echo "Publish: GitHub ▸ notchisland ▸ Releases ▸ Draft a new release ▸ tag v$VERSION ▸ attach $DMG"
