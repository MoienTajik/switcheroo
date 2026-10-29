#!/bin/bash
# End-to-end self-check: ./test.sh
# Builds the binary, starts a throwaway proxy (own port, temp data folder; your app, rewrites and system proxy are
# untouched) and drives it with the CLI and curl. The HTTPS checks run only if mkcert and its CA are present.
set -u
cd "$(dirname "$0")"

TMP="$(mktemp -d)"
BIN="$TMP/switcheroo"
PID=""
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$TMP"' EXIT
swiftc main.swift Config.swift Mappings.swift HTTP.swift ProxyServer.swift CLI.swift Updater.swift -O -framework Cocoa -o "$BIN" || exit 1

PORT=$((RANDOM % 20000 + 30000))
while nc -z 127.0.0.1 "$PORT" 2>/dev/null; do PORT=$((RANDOM % 20000 + 30000)); done
export SWITCHEROO_HOME="$TMP/home" SWITCHEROO_PORT="$PORT" SWITCHEROO_GRACE=2 NO_COLOR=1
PROXY="http://127.0.0.1:$PORT"
mkdir -p "$SWITCHEROO_HOME"

FAILED=0
ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILED=1; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) fail "$1 (wanted: $2)"; printf '        got: %s\n' "$3" | head -c 300; echo ;; esac; }
lacks(){ case "$3" in *"$2"*) fail "$1 (unexpected: $2)" ;; *) ok "$1" ;; esac; }
sw()   { "$BIN" "$@" 2>&1; }
curlx(){ curl -s --max-time 10 -x "$PROXY" "$@" 2>&1; }

start() { "$BIN" serve --no-proxy >"$TMP/server.log" 2>&1 & PID=$!; for _ in $(seq 50); do "$BIN" list >/dev/null 2>&1 && return; sleep 0.1; done; echo "server didn't start:"; cat "$TMP/server.log"; exit 1; }
stop()  { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=""; }

echo "CLI and rewrite rules"
out="$("$BIN" list 2>&1)"; has "not running -> clear error" "isn't running" "$out"
"$BIN" list >/dev/null 2>&1; [ $? -eq 1 ] && ok "not running -> exit 1" || fail "not running exit code"
start
has "empty list" "No rewrites yet" "$(sw list)"
has "add normalizes the URL" "Added  https://example.com/  →  http://localhost:3000/" "$(sw add 'https://Example.COM' http://localhost:3000)"
sw add 'https://example.com/*' http://localhost:3000/ >/dev/null
has "list shows kinds" "path   https://example.com/*" "$(sw list)"
has "list --json" '"from" : "https://example.com/"' "$(sw list --json)"
has "bad URL is rejected" "error:" "$(sw add 'not a url' http://x/)"
has "non-http URL is rejected" "Not an http(s) URL" "$(sw add 'ftp://x/' http://x/)"
has "add needs two arguments" "Usage: switcheroo add" "$(sw add https://example.com/x)"
has "remove" "Removed" "$(sw remove https://example.com/)"
has "remove missing" "No rewrite matches" "$(sw rm https://example.com/nope)"
has "unknown command" "Unknown command" "$(sw frobnicate)"
has "help" "switcheroo list" "$(sw help)"
sw remove 'https://example.com/*' >/dev/null

echo "Plain HTTP through the proxy"
PAC="$PROXY/proxy.pac"
sw add http://exact.test/page "$PAC" >/dev/null
r="$(curlx -i http://exact.test/page)"
has "exact match is swapped" "FindProxyForURL" "$r"
has "swapped response is marked" "x-switcheroo: $PAC" "$(printf '%s' "$r" | tr 'A-Z' 'a-z' | sed 's/^x-switcheroo/x-switcheroo/')"
sw add 'http://site.test/*' "$PROXY/" >/dev/null
has "prefix match appends the rest" "FindProxyForURL" "$(curlx http://site.test/proxy.pac)"
sw add http://site.test/proxy.pac "$PROXY/" >/dev/null
has "exact beats prefix" "Switcheroo is running" "$(curlx http://site.test/proxy.pac)"
r="$(curlx -i "$PROXY/proxy.pac")"
has "unmapped URLs pass through" "FindProxyForURL" "$r"
lacks "unmapped responses are not marked" "x-switcheroo" "$(printf '%s' "$r" | tr 'A-Z' 'a-z')"
has "POST body is forwarded" "FindProxyForURL" "$(curlx -d hello http://exact.test/page)"
head -c 200000 /dev/zero | tr '\0' 'a' > "$TMP/big.txt"
has "large POST (Expect: 100-continue)" "FindProxyForURL" "$(curlx -d @"$TMP/big.txt" -H 'Expect: 100-continue' http://exact.test/page)"
sw add http://down.test/ http://127.0.0.1:1/ >/dev/null
has "unreachable target -> 502" "502" "$(curlx -o /dev/null -w '%{http_code}' http://down.test/)"

echo "Local API guards"
has "wrong Host is refused" "403" "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.test' "$PROXY/api/mappings")"
has "non-JSON write is refused" "415" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -d 'from=x' "$PROXY/api/mappings")"
has "unknown path" "404" "$(curl -s -o /dev/null -w '%{http_code}' "$PROXY/nope")"
has "PAC file" "PROXY 127.0.0.1:$PORT" "$(curl -s "$PROXY/proxy.pac")"

echo "HTTPS"
has "unmapped host: CONNECT is tunneled untouched" "FindProxyForURL" "$(curlx --proxytunnel "$PROXY/proxy.pac")"
CAROOT="$(mkcert -CAROOT 2>/dev/null)"
if command -v mkcert >/dev/null && [ -f "$CAROOT/rootCA.pem" ]; then
  sw add https://secure.test/ "$PAC" >/dev/null
  r="$(curlx -i --cacert "$CAROOT/rootCA.pem" https://secure.test/)"
  has "mapped host: HTTPS is decrypted and swapped" "FindProxyForURL" "$r"
  has "mapped host: response is marked" "x-switcheroo: $PAC" "$(printf '%s' "$r" | tr 'A-Z' 'a-z')"
  has "mapped host: POST over HTTPS" "FindProxyForURL" "$(curlx -d hello --cacert "$CAROOT/rootCA.pem" https://secure.test/)"
else
  echo "  skip  mapped-host HTTPS (needs mkcert and its CA: run 'mkcert -install')"
fi

echo "Connection hygiene (regression: half-closed tunnels used to leak until the proxy ran out of sockets)"
UP=$((PORT + 1))
python3 - "$UP" <<'PY' &
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(128)
while True:
    c, _ = s.accept(); c.close()      # an upstream that hangs up immediately
PY
UPPID=$!
sleep 0.7
socks() { lsof -nP -a -p "$PID" -iTCP 2>/dev/null | wc -l | tr -d ' '; }
base=$(socks)
# 40 clients that send a CONNECT and then ignore everything, including the proxy's close (like a browser's idle socket)
python3 - "$PORT" "$UP" 40 9 <<'PY' &
import socket, sys, time
port, up, n, hold = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
held = []
for _ in range(n):
    c = socket.create_connection(("127.0.0.1", port))
    c.sendall(("CONNECT 127.0.0.1:%d HTTP/1.1\r\nHost: x\r\n\r\n" % up).encode())
    held.append(c)                    # never read, never close
time.sleep(hold)
PY
HOLDPID=$!
sleep 1.2; during=$(socks)
sleep 5.5    # the grace period is 2 s here: the proxy must let go even though every client keeps its end open
after=$(socks)
{ kill "$UPPID" "$HOLDPID"; wait "$UPPID" "$HOLDPID"; } 2>/dev/null
[ $((during - base)) -ge 20 ] && ok "load was applied ($((during - base)) extra sockets while tunnels were open)" || fail "test load didn't register (base $base, during $during)"
[ $((after - base)) -lt 8 ] && ok "tunnels the peer never closes are dropped after the grace period (sockets: $base -> $during -> $after)" || fail "sockets leaked: $base -> $during -> $after"
has "proxy still serves after the burst" "FindProxyForURL" "$(curlx "$PROXY/proxy.pac")"

echo "Persistence and a second instance"
before="$(sw list --json)"
stop; start
[ "$(sw list --json)" = "$before" ] && ok "rewrites survive a restart" || fail "rewrites lost after restart"
r="$("$BIN" serve --no-proxy 2>&1)"; has "second instance is refused" "already serving" "$r"

echo "PATH installer"
BINDIR="$TMP/bin"; mkdir -p "$BINDIR"
inst() { SWITCHEROO_BIN_DIRS="$TMP/nope:$BINDIR" "$BIN" install "$@" 2>&1; }
has "install links into the first writable dir" "Linked $BINDIR/switcheroo" "$(inst)"
same() { [ "$(realpath "$1" 2>/dev/null)" = "$(realpath "$BIN")" ]; }
same "$BINDIR/switcheroo" && ok "link points at the binary" || fail "link target is $(readlink "$BINDIR/switcheroo")"
has "install is idempotent" "Already linked" "$(inst)"
[ -z "$(inst --quiet)" ] && ok "--quiet is silent" || fail "--quiet printed output"
rm "$BINDIR/switcheroo"; echo "someone else" > "$BINDIR/switcheroo"
has "a regular file is never replaced" "isn't a Switcheroo link" "$(inst)"
inst --quiet >/dev/null; [ "$(cat "$BINDIR/switcheroo")" = "someone else" ] && ok "--quiet leaves it alone too" || fail "foreign file was overwritten"
rm "$BINDIR/switcheroo"; ln -s /usr/bin/true "$BINDIR/switcheroo"
inst --quiet >/dev/null; [ "$(readlink "$BINDIR/switcheroo")" = "/usr/bin/true" ] && ok "a link to another tool is left alone" || fail "foreign link was replaced"
rm "$BINDIR/switcheroo"; ln -s "$TMP/gone/switcheroo" "$BINDIR/switcheroo"
inst --quiet >/dev/null; same "$BINDIR/switcheroo" && ok "a dangling Switcheroo link is repaired" || fail "dangling link not repaired"

echo
if [ "$FAILED" -eq 0 ]; then echo "all ok"; else echo "FAILED"; exit 1; fi
