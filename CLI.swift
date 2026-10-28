import Foundation

/// The `switcheroo` command-line tool. It is the app's own binary: given a command it runs here and exits
/// instead of opening the window, so there is nothing else to install. It does what the window does
/// (list / add / remove rewrites, turn the system proxy on and off) by talking to the running proxy.
enum CLI {
    /// Any word argument means CLI mode, so a typo gets an error instead of launching the app. Options like
    /// -AppleInterfaceStyle (which AppKit reads) leave it to the window. With no arguments, a terminal gets the
    /// help text; Finder and `open` get the window.
    static func requested(_ args: [String]) -> Bool {
        guard let first = args.dropFirst().first else { return isatty(STDOUT_FILENO) == 1 }
        return !first.hasPrefix("-") || first == "-h" || first == "--help" || first == "-v" || first == "--version"
    }

    struct Flags { var json = false, noProxy = false, quiet = false }

    private static let color = isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    private static func paint(_ code: String, _ s: String) -> String { color ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    private static func dim(_ s: String) -> String { paint("2", s) }
    private static func bold(_ s: String) -> String { paint("1", s) }
    private static func accent(_ s: String) -> String { paint("38;2;255;83;70", s) }

    static func run(_ args: [String]) -> Int32 {
        let argv = Array(args.dropFirst())
        let flags = Flags(json: argv.contains("--json"), noProxy: argv.contains("--no-proxy"), quiet: argv.contains("--quiet"))
        let words = argv.filter { !$0.hasPrefix("--") && $0 != "-h" }
        do {
            if argv.contains("-v") || argv.contains("--version") || words.first == "version" { print(Config.version); return 0 }
            guard let cmd = words.first, !argv.contains("-h"), !argv.contains("--help") else { print(help); return 0 }
            let rest = Array(words.dropFirst())
            switch cmd {
            case "list", "ls": try list(flags)
            case "add": try add(rest)
            case "remove", "rm": try remove(rest)
            case "on", "off": try proxy(cmd)
            case "proxy": try proxy(rest.first ?? "")
            case "status": try status(flags)
            case "serve": try serve(flags)
            case "open": try open()
            case "install": try install(quiet: flags.quiet)
            case "help": print(help)
            default: throw SwitcherooError("Unknown command \"\(cmd)\". Try: switcheroo help")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data((paint("31", "error: ") + error.localizedDescription + "\n").utf8))
            return 1
        }
    }

    // MARK: talking to the running proxy

    private struct NotRunning: LocalizedError {
        var errorDescription: String? { "Switcheroo isn't running. Start it with `switcheroo open` (app) or `switcheroo serve` (no window)." }
    }

    private static func api(_ method: String, _ body: [String: String]? = nil) throws -> [Mapping] {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(Config.port)/api/mappings")!,
                             cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]   // never through the system proxy (that is us)
        var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        let done = DispatchSemaphore(value: 0)
        URLSession(configuration: cfg).dataTask(with: req) { result = ($0, $1, $2); done.signal() }.resume()
        done.wait()
        if let e = result.2 as NSError? {
            throw e.domain == NSURLErrorDomain && e.code == NSURLErrorCannotConnectToHost ? NotRunning() : e
        }
        guard let data = result.0, let http = result.1 as? HTTPURLResponse else { throw SwitcherooError("No response from the proxy") }
        if http.statusCode == 200, let list = try? JSONDecoder().decode([Mapping].self, from: data) { return list }
        let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
        throw SwitcherooError(msg ?? "Unexpected response from port \(Config.port) (is something else using it?)")
    }

    private static func isRunning() throws -> Bool {
        do { _ = try api("GET"); return true } catch is NotRunning { return false }
    }

    // MARK: commands

    private static func list(_ flags: Flags) throws {
        let rows = try api("GET")
        if flags.json {
            let json = rows.map { ["from": $0.from, "to": $0.to] }
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
            return print(String(decoding: data, as: UTF8.self))
        }
        if rows.isEmpty { return print(dim("No rewrites yet. Add one: switcheroo add 'https://example.com/*' http://localhost:3000/")) }
        let width = rows.map { $0.from.count }.max() ?? 0
        for r in rows {
            let kind = r.from.hasSuffix("*") ? accent("path ") : dim("exact")
            print("\(kind)  \(r.from.padding(toLength: width, withPad: " ", startingAt: 0))  \(dim("→"))  \(r.to)")
        }
    }

    private static func add(_ a: [String]) throws {
        guard a.count >= 2 else { throw SwitcherooError("Usage: switcheroo add <from> <to>   (quote a trailing * so your shell doesn't expand it)") }
        let rows = try api("POST", ["from": a[0], "to": a[1]])
        guard let r = rows.last else { return }   // the new (normalized) rewrite goes last
        print("Added  \(r.from)  \(dim("→"))  \(r.to)")
        print(dim("\(rows.count) rewrite\(rows.count == 1 ? "" : "s")"))
    }

    private static func remove(_ a: [String]) throws {
        guard let from = a.first else { throw SwitcherooError("Usage: switcheroo remove <from>") }
        let before = try api("GET")
        let after = try api("DELETE", ["from": from])
        if after.count == before.count { throw SwitcherooError("No rewrite matches \(from)") }
        print("Removed  \(from)")
        print(dim("\(after.count) rewrite\(after.count == 1 ? "" : "s")"))
    }

    private static func setProxy(_ on: Bool) throws {
        let r = proxyctl(on ? "on" : "off")
        if r.status != 0 { throw SwitcherooError(r.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "networksetup failed" : r.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func proxy(_ state: String) throws {
        guard state == "on" || state == "off" else { throw SwitcherooError("Usage: switcheroo on | off") }
        try setProxy(state == "on")
        print(state == "on" ? "System proxy on. Browsers now route through Switcheroo." : "System proxy off.")
        if state == "on", try !isRunning() {
            print(dim("Note: the proxy server isn't running yet, so browsers connect directly until you `switcheroo open` or `serve`."))
        }
    }

    private static func status(_ flags: Flags) throws {
        let rows: [Mapping]?
        do { rows = try api("GET") } catch is NotRunning { rows = nil }
        let server = rows != nil ? "running on 127.0.0.1:\(Config.port)" : "not running"
        let sys = proxyctl("status").output.trimmingCharacters(in: .whitespacesAndNewlines) == "on" ? "on" : "off"
        let service = proxyctl("service").output.trimmingCharacters(in: .whitespacesAndNewlines)
        if flags.json {
            var obj: [String: Any] = ["server": server, "systemProxy": sys, "service": service]
            obj["rewrites"] = rows?.count ?? NSNull()
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            return print(String(decoding: data, as: UTF8.self))
        }
        print("Proxy server   \(server)")
        print("System proxy   \(sys) \(dim("(\(service))"))")
        print("Rewrites       \(rows.map { String($0.count) } ?? "-")")
    }

    private static var signalSources: [DispatchSourceSignal] = []

    /// Runs the proxy with no window: same server as the app. Ctrl-C stops it and restores the system proxy.
    private static func serve(_ flags: Flags) throws {
        if try isRunning() { throw SwitcherooError("Port \(Config.port) is already serving Switcheroo (is the app running?).") }
        let server = ProxyServer(store: MappingStore(path: Config.mappingsFile))
        do { try server.start() } catch { throw SwitcherooError("Couldn't listen on port \(Config.port): \(error.localizedDescription)") }
        print(bold("Switcheroo proxy listening on 127.0.0.1:\(Config.port)"))
        var proxied = false
        if !flags.noProxy {
            try setProxy(true)
            proxied = true
            print("System proxy on. Ctrl-C stops the server and turns it off.")
        }
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { if proxied { _ = proxyctl("off") }; exit(0) }
            source.resume()
            signalSources.append(source)
        }
        dispatchMain()
    }

    private static func open() throws {
        if shellResult("/usr/bin/open", ["-b", "local.switcheroo"]).status != 0 {
            throw SwitcherooError("Could not open the Switcheroo app (build it with ./build-app.sh first).")
        }
    }

    // MARK: putting `switcheroo` on the PATH

    enum LinkState { case missing, mine, ours, foreign }

    /// What `link` is: missing, already pointing at this binary (mine), a stale link to another Switcheroo
    /// copy (ours: dangling, or with proxyctl.sh beside its target), or anything else (foreign).
    static func linkState(_ link: String, _ me: String) -> LinkState {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: link) else { return .missing }
        guard attrs[.type] as? FileAttributeType == .typeSymbolicLink, let raw = try? fm.destinationOfSymbolicLink(atPath: link) else { return .foreign }
        let dest = URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: link).deletingLastPathComponent()).standardizedFileURL.path
        if dest == me { return .mine }
        let dir = (dest as NSString).deletingLastPathComponent
        let dangling = !fm.fileExists(atPath: dest)
        let sibling = fm.fileExists(atPath: dir + "/proxyctl.sh") || fm.fileExists(atPath: dir + "/../Resources/proxyctl.sh")
        return (dest as NSString).lastPathComponent == "switcheroo" && (dangling || sibling) ? .ours : .foreign
    }

    /// Links this binary into the first writable bin directory so `switcheroo` works in any terminal. Never
    /// replaces anything that isn't a Switcheroo link. `quiet` (used by the app at startup) never fails or prints.
    static func install(quiet: Bool) throws {
        let me = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
        // Not from a disk image or a translocated copy: the link would break when that goes away.
        guard !me.hasPrefix("/Volumes/"), !me.contains("/AppTranslocation/") else {
            if quiet { return }
            throw SwitcherooError("Run this from the installed app (drag Switcheroo to Applications first).")
        }
        let say = { (m: String) in if !quiet { print(m) } }
        let dirs = (ProcessInfo.processInfo.environment["SWITCHEROO_BIN_DIRS"] ?? "/opt/homebrew/bin:/usr/local/bin").split(separator: ":").map(String.init)
        let fm = FileManager.default
        for dir in dirs where fm.isWritableFile(atPath: dir) {
            let link = dir + "/switcheroo"
            switch linkState(link, me) {
            case .foreign:
                if quiet { return }
                throw SwitcherooError("\(link) exists and isn't a Switcheroo link; remove it first.")
            case .mine:
                return say("Already linked \(link)")
            case .ours:
                try fm.removeItem(atPath: link)
                fallthrough
            case .missing:
                try fm.createSymbolicLink(atPath: link, withDestinationPath: me)
                return say("Linked \(link) \(dim("→")) \(me)")
            }
        }
        if !quiet { throw SwitcherooError("No writable bin directory. Run: sudo ln -sf '\(me)' /usr/local/bin/switcheroo") }
    }

    static let help = """
    \(bold("switcheroo")) — serve one URL's content in place of another, on this Mac.

    \(bold("Rewrites"))
      switcheroo list [--json]            show all rewrites
      switcheroo add <from> <to>          add one (a trailing * on <from> maps a whole path)
      switcheroo remove <from>            remove one (alias: rm)

    \(bold("System proxy"))
      switcheroo on | off                 route browser traffic through Switcheroo, or stop
      switcheroo status [--json]          proxy server, system proxy and rewrite count

    \(bold("App / server"))
      switcheroo open                     launch the Switcheroo app
      switcheroo serve [--no-proxy]       run the proxy with no window (Ctrl-C stops it)
      switcheroo install                  link this tool into your PATH (the app also does this at startup)

    Quote URLs ending in * so your shell doesn't expand them:
      switcheroo add 'https://example.com/*' http://localhost:3000/
    """
}
