import Cocoa

/// Checks GitHub Releases for a newer version and, when there is one, offers to download it.
/// Lazy by design — it notifies and fetches the .dmg rather than replacing the app in place.
/// ponytail: download-and-open; a full in-place self-update (Sparkle-style) is the upgrade path if wanted.
enum Updater {
    private static let lastCheckKey = "LastUpdateCheck"

    /// Call on launch (silent: true). Throttled to once a day so it doesn't nag or hit the network every launch.
    static func checkInBackground() {
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        check(silent: true)
    }

    /// silent: true only speaks up when an update exists; false also reports "up to date" / errors (menu item).
    static func check(silent: Bool) {
        guard let url = URL(string: "https://api.github.com/repos/\(Config.repo)/releases/latest") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                if !silent { DispatchQueue.main.async { tell("Couldn't check for updates", code == 404 ? "No releases published yet." : "Try again later.") } }
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = (json["assets"] as? [[String: Any]]) ?? []
            let dmg = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
            let link = (dmg?["browser_download_url"] as? String) ?? (json["html_url"] as? String)
            let notes = (json["body"] as? String) ?? ""
            DispatchQueue.main.async {
                if isNewer(latest, than: Config.version) {
                    offer(version: latest, notes: notes, url: link.flatMap(URL.init))
                } else if !silent {
                    tell("You're up to date", "Switcheroo \(Config.version) is the latest version.")
                }
            }
        }.resume()
    }

    /// Numeric semver compare: true if `a` is a newer version than `b`.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let (x, y) = (parts(a), parts(b))
        for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : 0) != (i < y.count ? y[i] : 0) {
            return (i < x.count ? x[i] : 0) > (i < y.count ? y[i] : 0)
        }
        return false
    }

    private static func offer(version: String, notes: String, url: URL?) {
        let a = NSAlert()
        a.messageText = "Switcheroo \(version) is available"
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        a.informativeText = (trimmed.isEmpty ? "" : String(trimmed.prefix(600)) + "\n\n") + "You have \(Config.version)."
        a.addButton(withTitle: "Download")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn, let url {
            NSWorkspace.shared.open(url)   // the browser downloads the .dmg; the user drags the new app over the old
        }
    }

    private static func tell(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
