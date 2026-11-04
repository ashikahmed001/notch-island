# Releasing Notch Island

Notch Island is distributed directly (not through the Mac App Store), signed with a
Developer ID and notarized by Apple so it opens without warnings.

## One-time setup

1. **Join the Apple Developer Program** (individual, $99/year) at developer.apple.com.
2. **Create a Developer ID Application certificate.** Xcode ▸ Settings ▸ Accounts ▸
   Manage Certificates ▸ + ▸ *Developer ID Application*. Check it's in your keychain:

   ```sh
   security find-identity -v -p codesigning
   # → "Developer ID Application: Your Name (TEAMID)"
   ```

3. **Create an app-specific password** at account.apple.com ▸ Sign-In and Security, then
   save notarization credentials in the keychain:

   ```sh
   xcrun notarytool store-credentials notchisland \
     --apple-id you@example.com --team-id TEAMID
   # paste the app-specific password when asked
   ```

## Automatic updates (Sparkle), one-time

The app checks `https://ashikahmed001.github.io/notchisland/appcast.xml` once a day.
Every update must be signed with your Sparkle key as well as your Developer ID.

1. Download Sparkle and create your key (stored in your login Keychain):

   ```sh
   swift package resolve
   "$(find .build/artifacts -type f -path '*/bin/generate_keys' | head -1)"
   ```

   It prints a public key like `pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ=`.
2. Put that public key in `Resources/Info.plist` → `SUPublicEDKey`.
3. Back up the private key: `generate_keys -x sparkle-private-key.txt` and store the file
   somewhere safe (password manager). **If it's lost, existing users can't auto-update.**

## Each release

1. Bump `CFBundleShortVersionString` (e.g. 0.9.1) and `CFBundleVersion` (always increasing:
   3, 4, 5…) in `Resources/Info.plist`.
2. Add the release to `website/changelog.html`.
3. Build, sign, notarize, package, and add it to the update feed:

   ```sh
   DEVELOPER_ID="Developer ID Application: Ashik Ahmed (524AC2747P)" scripts/release.sh
   ```

   Output: `build/release/NotchIsland.dmg`, and a new entry in `website/appcast.xml`.
4. GitHub ▸ ashikahmed001/notchisland ▸ Releases ▸ Draft a new release ▸ tag `v<version>` ▸
   attach `build/release/NotchIsland.dmg` ▸ Publish. (Keep the file name `NotchIsland.dmg`.)
5. Push `website/appcast.xml` and `website/changelog.html` to the `notchisland` repo.
   **Publish the release first** — the feed points at the release's download link.

Within a day, everyone on an older version gets the update prompt.

## Notes

- **Permissions stay granted across updates** once the app is signed with the same
  Developer ID (ad-hoc builds from `scripts/bundle.sh` reset them).
- **Entitlements** live in `Resources/NotchIsland.entitlements`: Apple Events (Music,
  Spotify, browsers) and Calendars (Calendar + Reminders). Add one there if a new feature
  needs a protected resource — without it the hardened runtime silently blocks it.
- **If notarization is rejected**, the script prints Apple's log. Common causes: an
  unsigned nested binary, or a missing `--timestamp`.

