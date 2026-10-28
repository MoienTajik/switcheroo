#!/bin/bash
# Regenerate AppIcon.icns from make-icon.swift. Re-run after editing the drawing; build-app.sh bundles the result.
set -eu
cd "$(dirname "$0")"
TMP="$(mktemp -d)"
swiftc make-icon.swift -o "$TMP/make-icon"
"$TMP/make-icon" "$TMP/AppIcon.iconset" >/dev/null
iconutil -c icns "$TMP/AppIcon.iconset" -o AppIcon.icns
rm -rf "$TMP"
echo "Wrote AppIcon.icns"
