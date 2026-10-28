import Foundation

struct RequestHead {
    var method: String
    var target: String
    var version: String
    var headers: [(name: String, value: String)]

    func value(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Just enough HTTP/1.1 to rewrite the head of a request and response. Bodies are never parsed or touched:
/// they are piped through byte for byte, so cookies, compression, redirects and chunking behave exactly as
/// the real server sent them. Heads are handled as ISO-8859-1 so every byte survives the round trip.
enum HTTP {
    private static let endOfHead = Data([13, 10, 13, 10])
    private static let latin1 = String.Encoding.isoLatin1

    /// Splits at the blank line that ends the header block; nil until that much has arrived.
    static func splitHead(_ data: Data) -> (head: Data, rest: Data)? {
        guard let r = data.range(of: endOfHead) else { return nil }
        return (Data(data[data.startIndex..<r.lowerBound]), Data(data[r.upperBound...]))
    }

    static func parseRequest(_ head: Data) -> RequestHead? {
        guard let text = String(data: head, encoding: latin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else { return nil }
        var headers: [(String, String)] = []
        for line in lines where !line.isEmpty {
            guard let i = line.firstIndex(of: ":") else { return nil }
            headers.append((String(line[..<i]), line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)))
        }
        return RequestHead(method: String(parts[0]), target: String(parts[1]), version: String(parts[2]), headers: headers)
    }

    /// Connection-level headers that must not be forwarded: we speak to the upstream one request per connection.
    private static let hopByHop: Set<String> = ["connection", "proxy-connection", "keep-alive", "proxy-authorization", "upgrade", "te", "trailer"]

    /// The request as the upstream server should see it: origin-form path, its own Host, no hop-by-hop headers,
    /// and `Connection: close` so the response ends when the upstream closes (no body framing to track).
    static func upstreamRequest(_ h: RequestHead, path: String, host: String) -> Data {
        var s = "\(h.method) \(path) HTTP/1.1\r\nHost: \(host)\r\n"
        for (n, v) in h.headers {
            let l = n.lowercased()
            if l == "host" || hopByHop.contains(l) { continue }
            s += "\(n): \(v)\r\n"
        }
        s += "Connection: close\r\n\r\n"
        return Data(s.data(using: latin1) ?? Data(s.utf8))
    }

    /// The response head for the client: `Connection: close`, plus `x-switcheroo` when the URL was swapped.
    static func clientResponseHead(_ head: Data, swappedTo: String?) -> Data {
        guard let text = String(data: head, encoding: latin1) else { return head + endOfHead }
        var lines = text.components(separatedBy: "\r\n")
        let status = lines.removeFirst()
        lines.removeAll {
            let l = $0.lowercased()
            return l.hasPrefix("connection:") || l.hasPrefix("keep-alive:") || l.hasPrefix("proxy-connection:")
        }
        lines.append("Connection: close")
        if let t = swappedTo { lines.append("x-switcheroo: \(t)") }
        let out = ([status] + lines).joined(separator: "\r\n") + "\r\n\r\n"
        return Data(out.data(using: latin1) ?? Data(out.utf8))
    }

    /// A complete small response (used for the local API and for errors).
    static func response(_ status: Int, contentType: String = "text/plain; charset=utf-8", body: Data = Data(), extra: [String] = []) -> Data {
        let reasons = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                       413: "Payload Too Large", 415: "Unsupported Media Type", 502: "Bad Gateway"]
        var s = "HTTP/1.1 \(status) \(reasons[status] ?? "Status")\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for e in extra { s += e + "\r\n" }
        return Data(s.utf8) + Data("\r\n".utf8) + body
    }
}
