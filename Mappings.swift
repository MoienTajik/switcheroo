import Foundation

struct Mapping: Codable, Equatable {
    let from: String
    let to: String
    /// Also match the same URL with `www.` added or removed. Left out of the JSON when off, and absent from
    /// files written before this option existed.
    let www: Bool?

    init(from: String, to: String, www: Bool = false) {
        self.from = from
        self.to = to
        self.www = www ? true : nil
    }

    var coversWWW: Bool { www == true }
}

func encodeMappings(_ list: [Mapping]) -> Data {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
    return (try? e.encode(list)) ?? Data("[]".utf8)
}

/// The same URL with `www.` removed from its host, or added if it had none. Expects a normalized URL.
func wwwTwin(_ url: String) -> String {
    guard let r = url.range(of: "://") else { return url }
    let rest = String(url[r.upperBound...])
    return String(url[..<r.upperBound]) + (rest.hasPrefix("www.") ? String(rest.dropFirst(4)) : "www." + rest)
}

/// Canonical form so "https://Site.com" and "https://site.com/" compare equal. A trailing * means prefix match.
func normalizeURL(_ input: String) throws -> String {
    let star = input.hasSuffix("*")
    let raw = (star ? String(input.dropLast()) : input).trimmingCharacters(in: .whitespacesAndNewlines)
    guard var c = URLComponents(string: raw), let scheme = c.scheme?.lowercased() else {
        throw SwitcherooError("Invalid URL: \(input)")
    }
    guard scheme == "http" || scheme == "https" else { throw SwitcherooError("Not an http(s) URL: \(input)") }
    guard let host = c.host?.lowercased(), !host.isEmpty else { throw SwitcherooError("Invalid URL: \(input)") }
    c.scheme = scheme
    c.host = host
    if (scheme == "http" && c.port == 80) || (scheme == "https" && c.port == 443) { c.port = nil }
    if c.path.isEmpty { c.path = "/" }
    c.fragment = nil
    guard let out = c.string else { throw SwitcherooError("Invalid URL: \(input)") }
    return out + (star ? "*" : "")
}

/// The list of rewrites, persisted to mappings.json (same format as the earlier Node version).
final class MappingStore {
    private var items: [Mapping] = []
    private let path: String
    private let queue = DispatchQueue(label: "switcheroo.mappings")

    init(path: String) {
        self.path = path
        if let data = FileManager.default.contents(atPath: path), let m = try? JSONDecoder().decode([Mapping].self, from: data) {
            items = m
        }
    }

    var all: [Mapping] { queue.sync { items } }

    private func normalizeTarget(_ to: String) throws -> String {
        var t = try normalizeURL(to)
        if t.hasSuffix("*") { t.removeLast() }
        return t
    }

    /// Adds (or replaces) a rewrite and returns the updated list. The new one goes last.
    func add(from: String, to: String, www: Bool = false) throws -> [Mapping] {
        let f = try normalizeURL(from)
        let t = try normalizeTarget(to)
        return queue.sync {
            items.removeAll { $0.from == f }
            items.append(Mapping(from: f, to: t, www: www))
            save()
            return items
        }
    }

    /// Changes an existing rewrite in place, keeping its position, and returns the updated list.
    func update(original: String, from: String, to: String, www: Bool) throws -> [Mapping] {
        let o = try normalizeURL(original)
        let f = try normalizeURL(from)
        let t = try normalizeTarget(to)
        return try queue.sync {
            guard let i = items.firstIndex(where: { $0.from == o }) else { throw SwitcherooError("No rewrite matches \(original)") }
            if f != o, items.contains(where: { $0.from == f }) { throw SwitcherooError("A rewrite for \(f) already exists.") }
            items[i] = Mapping(from: f, to: t, www: www)
            save()
            return items
        }
    }

    func remove(from: String) throws -> [Mapping] {
        let f = try normalizeURL(from)
        return queue.sync {
            items.removeAll { $0.from == f }
            save()
            return items
        }
    }

    /// What each rewrite matches. Rules as written come first, so a rule for www.x.com beats the twin of one for x.com.
    private var patterns: [(from: String, to: String)] {
        items.map { ($0.from, $0.to) } + items.filter(\.coversWWW).map { (wwwTwin($0.from), $0.to) }
    }

    /// Exact match wins; otherwise the longest matching prefix, with the rest of the URL appended to `to`.
    func resolve(_ url: String) -> String? {
        queue.sync {
            let all = patterns
            if let exact = all.first(where: { $0.from == url }) { return exact.to }
            var best: (from: String, to: String)?
            for p in all where p.from.hasSuffix("*") && url.hasPrefix(p.from.dropLast()) && p.from.count > (best?.from.count ?? 0) {
                best = p
            }
            guard let best else { return nil }
            return best.to + url.dropFirst(best.from.count - 1)
        }
    }

    /// True if any rewrite is for this host, so HTTPS to it must be decrypted (everything else is tunneled untouched).
    func mappedHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return queue.sync {
            patterns.contains { m in
                let raw = m.from.hasSuffix("*") ? String(m.from.dropLast()) : m.from
                return URLComponents(string: raw)?.host?.lowercased() == h
            }
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? encodeMappings(items).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
