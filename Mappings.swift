import Foundation

struct Mapping: Codable, Equatable {
    let from: String
    let to: String
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

    /// Adds (or replaces) a rewrite and returns the updated list. The new one goes last.
    func add(from: String, to: String) throws -> [Mapping] {
        let f = try normalizeURL(from)
        var t = try normalizeURL(to)
        if t.hasSuffix("*") { t.removeLast() }
        return queue.sync {
            items.removeAll { $0.from == f }
            items.append(Mapping(from: f, to: t))
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

    /// Exact match wins; otherwise the longest matching prefix, with the rest of the URL appended to `to`.
    func resolve(_ url: String) -> String? {
        queue.sync {
            if let exact = items.first(where: { $0.from == url }) { return exact.to }
            let prefix = items
                .filter { $0.from.hasSuffix("*") && url.hasPrefix($0.from.dropLast()) }
                .max { $0.from.count < $1.from.count }
            guard let p = prefix else { return nil }
            return p.to + url.dropFirst(p.from.count - 1)
        }
    }

    /// True if any rewrite is for this host, so HTTPS to it must be decrypted (everything else is tunneled untouched).
    func mappedHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return queue.sync {
            items.contains { m in
                let raw = m.from.hasSuffix("*") ? String(m.from.dropLast()) : m.from
                return URLComponents(string: raw)?.host?.lowercased() == h
            }
        }
    }

    private func save() {
        let json = items.map { ["from": $0.from, "to": $0.to] }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
