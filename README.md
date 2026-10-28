# Switcheroo

Make a URL — even a real website — serve another URL's content, on your Mac only. The address bar never changes.

Point `https://example.com/app.js` at `http://localhost:3000/app.js` and the browser loads your local file while the page still thinks it's loading the real one. Handy for testing a local build against a production site, patching a third‑party script, or mocking an API, without touching DNS, `/etc/hosts`, or the site itself.

A single native Mac app: the window, the proxy, and a command‑line tool are one Swift binary. No Node, no browser extension, nothing else to install.

![CI](https://github.com/MoienTajik/switcheroo/actions/workflows/ci.yml/badge.svg)

## Download

Grab the latest `Switcheroo.dmg` from [**Releases**](https://github.com/MoienTajik/switcheroo/releases/latest), open it, and drag Switcheroo onto Applications. On first launch macOS asks for your password once, to trust the local certificate that lets Switcheroo show rewritten **HTTPS** pages without warnings.

The app is signed with a Developer ID and notarized by Apple, so it opens with a normal first‑launch prompt. **Apple Silicon, macOS 15 or later.**

## Use it

Add a pair in the window:

- **Replace** `https://example.com/app.js` (exact match) or `https://example.com/*` (everything under it)
- **With** `http://localhost:3000/app.js`, or `http://localhost:3000/` for a `*` rewrite

Changes apply immediately. The **Proxy** switch in the title bar turns routing on and off; quitting turns it off and restores your proxy settings.

- Swapped responses carry an `x-switcheroo` header naming the URL they came from (DevTools → Network).
- Still seeing old content? Hard‑reload (⌘⇧R) — the browser may have cached it.
- If Switcheroo isn't running, browsers connect directly.

## Command line

Everything the window does, from the terminal. The app adds `switcheroo` to your `PATH` on first launch (a link in `/opt/homebrew/bin` or `/usr/local/bin`; it never replaces anything that isn't its own link). It's the same binary — given a command it runs in the terminal instead of opening the window.

```bash
switcheroo list [--json]                         # show rewrites
switcheroo add 'https://example.com/*' http://localhost:3000/
switcheroo remove 'https://example.com/*'
switcheroo on | off                              # system proxy, same as the title-bar switch
switcheroo status                                # server, system proxy, rewrite count
switcheroo serve                                 # run the proxy with no window (Ctrl-C stops it)
switcheroo open                                  # launch the app
switcheroo --version
```

Quote URLs ending in `*` so your shell doesn't expand them. `list`, `add`, and `remove` need the proxy running (the app, or `switcheroo serve`). To remove the command and stop the app re‑adding it:

```bash
rm "$(which switcheroo)"
defaults write local.switcheroo InstallCLI -bool false
```

## How it works

Browsers are pointed at a proxy auto‑config file (`http://localhost:8899/proxy.pac`) through the macOS system proxy settings, which covers Chrome, Arc, and Safari alike. The built‑in proxy then:

- swaps the content of URLs you mapped, and forwards everything else untouched (plain HTTP as‑is — cookies, compression, and redirects included);
- tunnels HTTPS to hosts you haven't mapped **without** decrypting it;
- for a host with a rewrite, decrypts HTTPS using a certificate from a local CA ([mkcert](https://github.com/FiloSottile/mkcert), bundled) that your system trusts.

The PAC file skips localhost and private IPs. Rewrites and certificates live in `~/Library/Application Support/Switcheroo`.

Updates are checked against GitHub Releases once a day (and from **Switcheroo → Check for Updates…**); a newer version offers a one‑click download.

## Build from source

Needs Xcode's command‑line tools and, to bundle mkcert, `brew install mkcert`.

```bash
./build-app.sh && open Switcheroo.app     # build and run
./test.sh                                 # end-to-end self-check
./make-dmg.sh                             # build the installer DMG
```

`make-dmg.sh` signs with a Developer ID and, when notarization credentials are available, notarizes and staples both the app and the DMG. Set `SIGN_ID` to your identity; `SIGN_ID="-" ./make-dmg.sh` falls back to an ad‑hoc signature for local use.

### Releasing

Push a `vX.Y.Z` tag (matching `VERSION`) and the [release workflow](.github/workflows/release.yml) builds, signs, notarizes, and publishes a GitHub Release with the DMG. It needs these repository secrets:

| Secret | What |
| --- | --- |
| `MACOS_CERT_P12_BASE64` | Your *Developer ID Application* certificate + key, exported as `.p12` and base64‑encoded |
| `MACOS_CERT_PASSWORD` | Password you set on that `.p12` |
| `NOTARY_APPLE_ID` | Apple ID for notarization |
| `NOTARY_PASSWORD` | An [app‑specific password](https://appleid.apple.com) for that Apple ID |
| `NOTARY_TEAM_ID` | Your team ID (`BJ7A45T36J`) |

## Credits

Local certificates by [mkcert](https://github.com/FiloSottile/mkcert) (BSD‑3‑Clause), bundled in the app.
