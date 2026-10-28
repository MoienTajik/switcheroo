#!/bin/bash
# Build dist/Switcheroo-<version>.dmg: the drag-and-drop installer (the app + an Applications shortcut).
# Signs with a Developer ID and (when credentials are stored) notarizes + staples, so a downloaded copy
# opens cleanly. Run: ./make-dmg.sh
set -eu
cd "$(dirname "$0")"

./build-app.sh
APP="Switcheroo.app"

# Signing. Default to the Developer ID so a downloaded copy passes Gatekeeper once notarized.
# Overrides: SIGN_ID="-" gives an ad-hoc signature (local use only); NOTARY_PROFILE names the stored
# notarytool credentials (the hint printed at the end shows how to create them).
SIGN_ID="${SIGN_ID:-Developer ID Application: Simber Tech (BJ7A45T36J)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-switcheroo-notary}"
RUNTIME=""; [ "$SIGN_ID" = "-" ] || RUNTIME="--options runtime --timestamp"

# Sign nested code first (the bundled mkcert), then the bundle, which seals the main binary and resources.
[ -f "$APP/Contents/Resources/mkcert" ] && codesign --force $RUNTIME --sign "$SIGN_ID" "$APP/Contents/Resources/mkcert"
codesign --force $RUNTIME --sign "$SIGN_ID" "$APP"
codesign --verify --strict "$APP"

# Notary credentials: an App Store Connect API key (CI) wins, else a stored keychain profile (local).
NOTARY_AUTH=()
if [ "$SIGN_ID" != "-" ]; then
  if [ -n "${NOTARY_KEY_PATH:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ]; then
    NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
  fi
fi
NOTARIZE=0; [ "${#NOTARY_AUTH[@]}" -gt 0 ] && NOTARIZE=1

if [ "$NOTARIZE" = 1 ]; then
  # Notarize the app and STAPLE it, so a copy dragged to /Applications opens offline, no Gatekeeper prompt.
  echo "Notarizing the app (uploading to Apple)..."
  ditto -c -k --keepParent "$APP" ".notarize-app.zip"
  xcrun notarytool submit ".notarize-app.zip" "${NOTARY_AUTH[@]}" --wait
  rm -f ".notarize-app.zip"
  xcrun stapler staple "$APP"
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
VOL="Switcheroo"
OUT="dist/Switcheroo-$VERSION.dmg"
MOUNT="/Volumes/$VOL"
mkdir -p dist

# Finder addresses the disk by name, so a stale mount of an earlier build would break the layout step.
[ -d "$MOUNT" ] && { hdiutil detach "$MOUNT" -quiet || { echo "Eject the \"$VOL\" disk first." >&2; exit 1; }; }

TMP="$(mktemp -d)"
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; rm -rf "$TMP"' EXIT

STAGE="$TMP/stage"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
swiftc make-dmg-background.swift -o "$TMP/bg" && "$TMP/bg" "$STAGE/.background/background.png" >/dev/null

SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -size "${SIZE_MB}m" "$TMP/rw.dmg" -quiet
hdiutil attach "$TMP/rw.dmg" -mountpoint "$MOUNT" -noautoopen -quiet

# Disk icon, then the Finder window: icon view, no toolbar, app and Applications on the artwork's marks.
cp AppIcon.icns "$MOUNT/.VolumeIcon.icns" && SetFile -a C "$MOUNT"
osascript <<EOF || echo "warning: couldn't lay out the Finder window (allow Terminal to control Finder); the DMG still works." >&2
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 542}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.png"
    set position of item "$APP" of container window to {165, 215}
    set position of item "Applications" of container window to {495, 215}
    -- park hidden items (.background, .fseventsd) out of sight for people who show hidden files
    repeat with n in {".background", ".fseventsd"}
      try
        set position of item n of container window to {120, 620}
      end try
    end repeat
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF

sync
for i in 1 2 3 4 5; do hdiutil detach "$MOUNT" -quiet 2>/dev/null && break; sleep 2; done
[ -d "$MOUNT" ] && hdiutil detach "$MOUNT" -force -quiet

rm -f "$OUT"
hdiutil convert "$TMP/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet

[ "$SIGN_ID" = "-" ] || codesign --force --timestamp --sign "$SIGN_ID" "$OUT"

if [ "$NOTARIZE" = 1 ]; then
  echo "Notarizing the DMG..."
  xcrun notarytool submit "$OUT" "${NOTARY_AUTH[@]}" --wait
  xcrun stapler staple "$OUT"
  echo "Built, notarized and stapled $OUT ($(du -h "$OUT" | cut -f1))"
elif [ "$SIGN_ID" = "-" ]; then
  echo "Built $OUT ($(du -h "$OUT" | cut -f1)) -- ad-hoc signed, NOT notarized (local use only)."
else
  echo "Built $OUT ($(du -h "$OUT" | cut -f1)) -- signed but NOT notarized (no credentials)."
  echo "Store credentials once, then re-run ./make-dmg.sh:"
  echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <your-apple-id> --team-id BJ7A45T36J --password <app-specific-password>"
fi
