#!/bin/bash
# System-proxy + CA helper for Switcheroo.app. Keeps the privileged, macOS-prompted
# steps (CA trust, proxy config) in one place the Swift app shells out to.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"

# The copy bundled next to this script wins, then Homebrew's.
find_bin() {
  for p in "$HERE/$1" "/opt/homebrew/bin/$1" "/usr/local/bin/$1" "$(command -v "$1" 2>/dev/null)"; do
    [ -x "$p" ] && { echo "$p"; return; }
  done
}

# Primary network service = the one on the default-route interface; fall back to Wi-Fi.
# ponytail: single active service, fine for one Mac; loop all services if multi-homed.
service() {
  local dev svc
  dev="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  svc="$(networksetup -listnetworkserviceorder | awk -v d="$dev" '
    /^\([0-9]+\)/ { n=$0; sub(/^\([0-9]+\) /,"",n) }
    $0 ~ "Device: " d "\\)" { print n; exit }')"
  echo "${svc:-Wi-Fi}"
}

case "${1:-}" in
  service) service ;;
  claim)   # free port 8899 from any stray instance so the app's server can bind it
    lsof -nP -tiTCP:8899 -sTCP:LISTEN 2>/dev/null | xargs -r kill 2>/dev/null; sleep 1 ;;
  on)
    MK="$(find_bin mkcert)"; [ -n "$MK" ] && "$MK" -install >/dev/null 2>&1
    networksetup -setautoproxyurl "$(service)" "http://localhost:8899/proxy.pac" ;;
  off)
    networksetup -setautoproxystate "$(service)" off ;;
  status)  # prints "on" only when the system PAC points at us, else "off"
    s="$(networksetup -getautoproxyurl "$(service)")"
    if grep -q "Enabled: Yes" <<<"$s" && grep -q "localhost:8899" <<<"$s"; then echo on; else echo off; fi ;;
  *) echo "usage: proxyctl.sh {service|claim|on|off|status}" >&2; exit 2 ;;
esac
