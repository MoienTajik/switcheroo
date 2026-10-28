#!/bin/bash
# Build "Switcheroo.app": one native Swift binary (window, proxy server and CLI), no Node, no web view.
# Re-run after changing any .swift file or proxyctl.sh. (Icon: ./make-icon.sh regenerates AppIcon.icns.)
set -eu
cd "$(dirname "$0")"

# Oldest macOS the app runs on. The SDK is whatever Xcode ships; this keeps the binary from
# requiring that same (newest) OS. Apple Silicon only.
TARGET="${SWITCHEROO_TARGET:-arm64-apple-macos15.0}"
VERSION="$(cat "$(dirname "$0")/VERSION")"   # single source of truth for the app version

APP="Switcheroo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc main.swift Config.swift Mappings.swift HTTP.swift ProxyServer.swift CLI.swift Updater.swift -O -target "$TARGET" -framework Cocoa \
  -o "$APP/Contents/MacOS/switcheroo"

cp proxyctl.sh AppIcon.icns "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/proxyctl.sh"

# mkcert (a small, self-contained binary) makes the local certificates for HTTPS rewrites. Bundling it means
# nothing has to be installed. It is BSD-3-Clause licensed (github.com/FiloSottile/mkcert).
if MKCERT="$(command -v mkcert)"; then
  cp "$MKCERT" "$APP/Contents/Resources/mkcert"
else
  echo "warning: mkcert not found; the app will need it installed (brew install mkcert) for HTTPS rewrites." >&2
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Switcheroo</string>
  <key>CFBundleDisplayName</key><string>Switcheroo</string>
  <key>CFBundleIdentifier</key><string>local.switcheroo</string>
  <key>CFBundleVersion</key><string>__VERSION__</string>
  <key>CFBundleShortVersionString</key><string>__VERSION__</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>switcheroo</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
/usr/bin/sed -i '' "s/__VERSION__/$VERSION/g" "$APP/Contents/Info.plist"

echo "Built $APP (v$VERSION)"
