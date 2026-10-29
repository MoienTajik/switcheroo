import Foundation
import Network
import Security

/// The "map remote" proxy. Browsers reach it through the PAC file; it swaps the content of mapped URLs and
/// otherwise stays out of the way (plain HTTP is forwarded, HTTPS to unmapped hosts is tunneled untouched).
final class ProxyServer {
    let store: MappingStore
    let port: UInt16
    let certDir: String
    /// One serial queue for every connection: simple, and plenty for a local dev tool.
    let queue = DispatchQueue(label: "switcheroo.proxy", qos: .userInitiated)

    private var listener: NWListener?
    private var decrypters: [String: Decrypter] = [:]
    private let lock = NSLock()
    /// Every live client session. Only touched on `queue`. The sweeper closes the ones that have gone quiet.
    private var sessions: [ObjectIdentifier: ClientSession] = [:]
    private var sweeper: DispatchSourceTimer?

    init(store: MappingStore, port: UInt16 = Config.port, certDir: String = Config.certsDir) {
        self.store = store
        self.port = port
        self.certDir = certDir
    }

    func register(_ s: ClientSession) { sessions[ObjectIdentifier(s)] = s }
    func unregister(_ s: ClientSession) { sessions[ObjectIdentifier(s)] = nil }

    /// Closes sessions that have been silent longer than their limit. Without this, a peer that never answers
    /// a close (an idle browser connection, a stalled server) would hold two sockets open forever.
    private func startSweeper() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            for s in Array(self.sessions.values) where s.idleFor > s.idleLimit { s.closeAll() }
        }
        t.resume()
        sweeper = t
    }

    func start() throws {
        // A busy proxy holds two sockets per connection; macOS's default soft limit is low.
        var rl = rlimit()
        if getrlimit(RLIMIT_NOFILE, &rl) == 0 {
            rl.rlim_cur = min(rl.rlim_max, 10240)
            setrlimit(RLIMIT_NOFILE, &rl)
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in
            guard let self else { return c.cancel() }
            ClientSession(conn: c, server: self, mode: .proxy).start()
        }
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let e): failure = e; ready.signal()
            default: break
            }
        }
        l.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut { throw SwitcherooError("The proxy didn't start listening on port \(port).") }
        if let f = failure { throw f }
        listener = l
        startSweeper()
    }

    func stop() {
        sweeper?.cancel()
        queue.async { for s in Array(self.sessions.values) { s.closeAll() } }
        listener?.cancel()
        lock.lock(); let all = Array(decrypters.values); decrypters = [:]; lock.unlock()
        all.forEach { $0.cancel() }
    }

    var pac: String {
        """
        function FindProxyForURL(url, host) {
          if (isPlainHostName(host) || /^(localhost|127\\.|10\\.|192\\.168\\.|\\[?::1)/.test(host) || /\\.(local|localhost)$/.test(host)) return "DIRECT";
          return "PROXY 127.0.0.1:\(port); DIRECT";
        }

        """
    }

    // MARK: HTTPS to a mapped host

    /// The loopback port of the TLS endpoint that decrypts traffic for `host:port`, created on first use.
    /// (A listener per host, because Network.framework has one certificate per listener.)
    func decrypterPort(host: String, port: Int, done: @escaping (Result<UInt16, Error>) -> Void) {
        let key = "\(host):\(port)"
        lock.lock(); let existing = decrypters[key]; lock.unlock()
        if let d = existing { return done(.success(d.port)) }
        DispatchQueue.global().async {   // creating a certificate shells out to mkcert: keep it off the network queue
            do {
                let d = try Decrypter(host: host, tlsPort: port, identity: try self.identity(for: host), server: self)
                self.lock.lock()
                if let raced = self.decrypters[key] { self.lock.unlock(); d.cancel(); return done(.success(raced.port)) }
                self.decrypters[key] = d
                self.lock.unlock()
                done(.success(d.port))
            } catch { done(.failure(error)) }
        }
    }

    /// A TLS identity for `host`: a certificate signed by the local mkcert CA, which the system trusts.
    private func identity(for host: String) throws -> sec_identity_t {
        guard host.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil else {
            throw SwitcherooError("Can't make a certificate for \"\(host)\".")
        }
        try FileManager.default.createDirectory(atPath: certDir, withIntermediateDirectories: true)
        let p12 = "\(certDir)/\(host).p12"
        if !FileManager.default.fileExists(atPath: p12) {
            guard let mkcert = findBin("mkcert") else { throw SwitcherooError("mkcert isn't available, so HTTPS to \(host) can't be decrypted.") }
            let out = shell(mkcert, ["-pkcs12", "-p12-file", p12, host])
            guard FileManager.default.fileExists(atPath: p12) else { throw SwitcherooError("mkcert failed for \(host): \(out)") }
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: p12))
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: "changeit",
                                                      kSecImportToMemoryOnly as String: true] as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let raw = first[kSecImportItemIdentity as String],
              let id = sec_identity_create(raw as! SecIdentity) else {
            throw SwitcherooError("Couldn't load the certificate for \(host) (error \(status)).")
        }
        return id
    }
}

/// A loopback TLS endpoint for one mapped host. CONNECTs for that host are piped here, we terminate TLS with
/// the host's certificate, and the decrypted requests go through the same rewrite path as plain HTTP.
final class Decrypter {
    private(set) var port: UInt16 = 0
    private let listener: NWListener

    init(host: String, tlsPort: Int, identity: sec_identity_t, server: ProxyServer) throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let l = listener
        l.newConnectionHandler = { [weak server] c in
            guard let server else { return c.cancel() }
            ClientSession(conn: c, server: server, mode: .decrypted(host: host, port: tlsPort)).start()
        }
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let e): failure = e; ready.signal()
            default: break
            }
        }
        l.start(queue: server.queue)
        _ = ready.wait(timeout: .now() + 5)
        if let f = failure { throw f }
        guard let p = l.port else { throw SwitcherooError("The TLS helper for \(host) didn't start.") }
        port = p.rawValue
    }

    func cancel() { listener.cancel() }
}

/// Copies bytes one way until the sender finishes. The caller decides what ending means.
enum Pump {
    static func run(_ from: NWConnection, _ to: NWConnection, onData: @escaping () -> Void, onEnd: @escaping (_ clean: Bool) -> Void) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            if let data, !data.isEmpty {
                onData()
                to.send(content: data, completion: .contentProcessed { err in
                    if err != nil { onEnd(false) } else if complete { onEnd(true) } else { run(from, to, onData: onData, onEnd: onEnd) }
                })
            } else if error != nil { onEnd(false) }
            else if complete { onEnd(true) }
            else { run(from, to, onData: onData, onEnd: onEnd) }
        }
    }
}

/// One client connection: reads a request head, then answers it locally, forwards it, or tunnels.
final class ClientSession {
    enum Mode {
        case proxy                                  // a browser talking to the proxy port
        case decrypted(host: String, port: Int)     // already-decrypted HTTPS for a mapped host
    }

    private let conn: NWConnection
    private let server: ProxyServer
    private let mode: Mode
    private var buffer = Data()

    // Lifetime: the server sweeps sessions that stay silent past `idleLimit` and closes both sockets.
    private var peer: NWConnection?
    private var lastActivity = Date()
    var idleLimit: TimeInterval = 60   // until a request head arrives; raised once there's real traffic
    var idleFor: TimeInterval { Date().timeIntervalSince(lastActivity) }
    func touch() { lastActivity = Date() }
    func closeAll() { conn.cancel(); peer?.cancel() }

    init(conn: NWConnection, server: ProxyServer, mode: Mode) {
        self.conn = conn
        self.server = server
        self.mode = mode
    }

    func start() {
        server.register(self)
        conn.stateUpdateHandler = { [self] state in
            switch state {
            case .failed: closeAll()
            case .cancelled:
                peer?.cancel()
                conn.stateUpdateHandler = nil
                server.unregister(self)
            default: break
            }
        }
        conn.start(queue: server.queue)
        readHead()
    }

    private func readHead() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            if let data { buffer.append(data); touch() }
            if let (head, rest) = HTTP.splitHead(buffer) {
                guard let req = HTTP.parseRequest(head) else { return reply(400, "Bad request") }
                handle(req, rest: rest)
            } else if buffer.count > 65536 || complete || error != nil {
                conn.cancel()
            } else {
                readHead()
            }
        }
    }

    private func handle(_ req: RequestHead, rest: Data) {
        switch mode {
        case .decrypted(let host, let port):
            let url = "https://\(host)\(port == 443 ? "" : ":\(port)")\(req.target)"
            forward(to: url, req, rest: rest)
        case .proxy:
            if req.method.uppercased() == "CONNECT" { connect(req, rest: rest) }
            else if req.target.hasPrefix("http://") || req.target.hasPrefix("https://") { forward(to: req.target, req, rest: rest) }
            else { local(req, rest: rest) }
        }
    }

    // MARK: forwarding

    /// Sends the request to its real destination, or to the rewrite's target, and relays the response.
    private func forward(to originalURL: String, _ req: RequestHead, rest: Data) {
        let swapped = (try? normalizeURL(originalURL)).flatMap { server.store.resolve($0) }
        let target = swapped ?? originalURL
        guard let c = URLComponents(string: target), let host = c.host, let scheme = c.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return reply(502, "Switcheroo: bad target URL \(target)") }
        let tls = scheme == "https"
        let port = c.port ?? (tls ? 443 : 80)
        var path = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
        if let q = c.percentEncodedQuery { path += "?" + q }
        let hostHeader = c.port.map { "\(host):\($0)" } ?? host
        guard let p = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: port)) else { return reply(502, "Switcheroo: bad port in \(target)") }

        let params: NWParameters = tls ? .tls : .tcp
        params.preferNoProxies = true   // we ARE the system proxy: never loop back into ourselves
        let up = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        peer = up
        touch()
        let request = HTTP.upstreamRequest(req, path: path, host: hostHeader) + rest
        var started = false

        up.stateUpdateHandler = { [self] state in
            switch state {
            case .ready where !started:
                started = true
                // ponytail: 10 min silence ceiling for a response in flight (covers long polls); lower it if you need tighter.
                idleLimit = 600
                touch()
                up.send(content: request, completion: .contentProcessed { _ in })
                // The rest of the request body (if any) flows on to the upstream. If the client goes away, give the
                // response a grace period and then drop everything, rather than waiting on an upstream forever.
                Pump.run(conn, up, onData: { self.touch() }, onEnd: { clean in
                    if !clean { up.cancel(); self.conn.cancel() }
                    else { self.idleLimit = Config.halfCloseGrace; self.touch() }
                })
                relayResponse(from: up, swapped: swapped)
            case .waiting(let e), .failed(let e):
                if !started {
                    started = true
                    up.cancel()
                    reply(502, "Switcheroo: can't reach \(host):\(port): \(e)")
                } else {
                    up.cancel(); conn.cancel()
                }
            case .cancelled:
                up.stateUpdateHandler = nil
            default: break
            }
        }
        up.start(queue: server.queue)
    }

    /// Reads the response head, rewrites it, then pipes the rest of the response through untouched.
    private func relayResponse(from up: NWConnection, swapped: String?) {
        var acc = Data()
        func more() {
            up.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
                if let data { acc.append(data); touch() }
                if let (head, rest) = HTTP.splitHead(acc) {
                    let out = HTTP.clientResponseHead(head, swappedTo: swapped) + rest
                    conn.send(content: out, completion: .contentProcessed { [self] err in
                        if err != nil { up.cancel(); conn.cancel(); return }
                        Pump.run(up, conn, onData: { self.touch() }, onEnd: { _ in
                            // The upstream is done (we asked it to close): end the response for the client.
                            self.conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                                self.conn.cancel(); up.cancel()
                            })
                        })
                    })
                } else if complete || error != nil {
                    up.cancel()
                    if acc.isEmpty { reply(502, "Switcheroo: the server closed the connection without answering") }
                    else { conn.send(content: acc, completion: .contentProcessed { [self] _ in conn.cancel() }) }
                } else {
                    more()
                }
            }
        }
        more()
    }

    // MARK: CONNECT (HTTPS)

    private func connect(_ req: RequestHead, rest: Data) {
        guard let (host, port) = Self.hostPort(req.target) else { return reply(400, "Bad CONNECT target") }
        if server.store.mappedHost(host) {
            server.decrypterPort(host: host, port: Int(port)) { [self] result in
                switch result {
                case .success(let local): tunnel(to: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: local)!, using: .tcp), initial: rest)
                case .failure(let e): reply(502, "Switcheroo: \(e.localizedDescription)")
                }
            }
        } else {
            let params = NWParameters.tcp
            params.preferNoProxies = true
            tunnel(to: NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params), initial: rest)
        }
    }

    private static func hostPort(_ target: String) -> (String, UInt16)? {
        guard let i = target.lastIndex(of: ":"), let port = UInt16(target[target.index(after: i)...]), port != 0 else { return nil }
        var host = String(target[..<i])
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host.isEmpty ? nil : (host, port)
    }

    /// Answers the CONNECT, then copies bytes both ways, closing each direction as its sender finishes.
    private func tunnel(to up: NWConnection, initial: Data) {
        peer = up
        touch()
        var started = false
        up.stateUpdateHandler = { [self] state in
            switch state {
            case .ready where !started:
                started = true
                conn.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { [self] _ in
                    if !initial.isEmpty { up.send(content: initial, completion: .contentProcessed { _ in }) }
                    // ponytail: a tunnel silent for 15 min is closed (browsers reconnect); raise if a long-idle protocol needs it.
                    self.idleLimit = 900
                    self.touch()
                    var ended = 0
                    func finished(to: NWConnection) -> (Bool) -> Void {
                        return { clean in
                            if clean {
                                to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                                // The other side now has a short grace to answer our close; if it never does, the
                                // sweeper drops both sockets instead of leaving them half-closed forever.
                                self.idleLimit = Config.halfCloseGrace
                                self.touch()
                            }
                            ended += clean ? 1 : 2
                            if ended >= 2 { self.conn.cancel(); up.cancel() }
                        }
                    }
                    Pump.run(conn, up, onData: { self.touch() }, onEnd: finished(to: up))
                    Pump.run(up, conn, onData: { self.touch() }, onEnd: finished(to: conn))
                })
            case .waiting(let e), .failed(let e):
                if !started { started = true; up.cancel(); reply(502, "Switcheroo: can't connect: \(e)") } else { up.cancel(); conn.cancel() }
            case .cancelled:
                up.stateUpdateHandler = nil
            default: break
            }
        }
        up.start(queue: server.queue)
    }

    // MARK: local API (what the app and the CLI talk to)

    private func local(_ req: RequestHead, rest: Data) {
        // Only answer requests addressed to us by name, so a web page can't reach the API through DNS tricks.
        let allowed = ["localhost:\(server.port)", "127.0.0.1:\(server.port)"]
        guard allowed.contains(req.value("host") ?? "") else { return reply(403, "Forbidden") }
        let path = String(req.target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        switch path {
        case "/proxy.pac":
            send(200, "application/x-ns-proxy-autoconfig", Data(server.pac.utf8))
        case "/":
            reply(200, "Switcheroo is running. Use the app, or the `switcheroo` command.\n")
        case "/api/mappings":
            api(req, rest: rest)
        default:
            reply(404, "Not found")
        }
    }

    private func api(_ req: RequestHead, rest: Data) {
        let method = req.method.uppercased()
        if method == "GET" { return sendMappings(server.store.all) }
        guard method == "POST" || method == "DELETE" else { return sendJSON(405, ["error": "Method not allowed"]) }
        // JSON-only forces a CORS preflight, so other sites open in the browser can't change rewrites.
        guard (req.value("content-type") ?? "").lowercased().hasPrefix("application/json") else {
            return sendJSON(415, ["error": "JSON only"])
        }
        let need = Int(req.value("content-length") ?? "") ?? 0
        guard need <= 65536 else { return sendJSON(413, ["error": "Body too large"]) }
        readBody(rest, need: need) { [self] body in
            guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let from = obj["from"] as? String else {
                return sendJSON(400, ["error": "Expected JSON like {\"from\": \"...\", \"to\": \"...\"}"])
            }
            do {
                if method == "POST" {
                    guard let to = obj["to"] as? String else { return sendJSON(400, ["error": "Missing \"to\""]) }
                    sendMappings(try server.store.add(from: from, to: to))
                } else {
                    sendMappings(try server.store.remove(from: from))
                }
            } catch {
                sendJSON(400, ["error": error.localizedDescription])
            }
        }
    }

    private func readBody(_ have: Data, need: Int, then: @escaping (Data) -> Void) {
        if have.count >= need { return then(Data(have.prefix(need))) }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, _, _ in
            guard let data, !data.isEmpty else { return conn.cancel() }
            readBody(have + data, need: need, then: then)
        }
    }

    // MARK: replies

    private func send(_ status: Int, _ type: String, _ body: Data) {
        conn.send(content: HTTP.response(status, contentType: type, body: body), completion: .contentProcessed { [self] _ in conn.cancel() })
    }

    private func reply(_ status: Int, _ text: String) { send(status, "text/plain; charset=utf-8", Data(text.utf8)) }

    private func sendJSON(_ status: Int, _ object: Any) {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("[]".utf8)
        send(status, "application/json", body)
    }

    private func sendMappings(_ list: [Mapping]) { sendJSON(200, list.map { ["from": $0.from, "to": $0.to] }) }
}
