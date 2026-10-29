import Foundation

enum Config {
    /// Port the proxy and its API listen on. SWITCHEROO_PORT overrides it (used by the tests).
    static let port: UInt16 = UInt16(ProcessInfo.processInfo.environment["SWITCHEROO_PORT"] ?? "") ?? 8899

    /// Data folder: mappings.json and certs/. SWITCHEROO_HOME overrides it (used by the tests).
    static let support: String = ProcessInfo.processInfo.environment["SWITCHEROO_HOME"]
        ?? ("~/Library/Application Support/Switcheroo" as NSString).expandingTildeInPath

    /// The app's Resources folder (proxyctl.sh, mkcert). Resolves symlinks first, so it also works when
    /// the binary is run through the `switcheroo` link on PATH.
    static let resources: String = {
        let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
        let res = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources").path
        return FileManager.default.fileExists(atPath: res) ? res : (Bundle.main.resourcePath ?? res)
    }()

    static var mappingsFile: String { support + "/mappings.json" }
    static var certsDir: String { support + "/certs" }

    /// How long a connection may stay open, silent, after one side has closed. Browsers and servers that don't
    /// answer a close within this are abandoned, so half-closed sockets can't pile up. SWITCHEROO_GRACE (seconds)
    /// overrides it for the tests.
    static let halfCloseGrace: TimeInterval = TimeInterval(ProcessInfo.processInfo.environment["SWITCHEROO_GRACE"] ?? "") ?? 30

    /// GitHub repo for the auto-updater (owner/name).
    static let repo = "MoienTajik/switcheroo"
    /// This build's version, from Info.plist (CFBundleShortVersionString).
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
}

/// Finds a helper binary: the copy bundled in the app first, then the usual Homebrew locations.
func findBin(_ name: String) -> String? {
    for p in ["\(Config.resources)/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"] {
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
}

/// Runs a command to completion and returns its exit status and combined output.
func shellResult(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (127, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

@discardableResult
func shell(_ path: String, _ args: [String]) -> String { shellResult(path, args).output }

/// The proxy/CA helper script bundled in the app (turns the system proxy on and off).
func proxyctl(_ command: String) -> (status: Int32, output: String) {
    shellResult("/bin/bash", ["\(Config.resources)/proxyctl.sh", command])
}

struct SwitcherooError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
