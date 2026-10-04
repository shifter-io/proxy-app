import Foundation
import Network

/// The gateway login the app hands over (lib/proxy/tunnel_proxy_engine.dart).
struct GatewayLogin: Codable {
    var host: String
    var port: Int
    var username: String
    var password: String
    /// Hosts that skip the gateway (lib/proxy/bypass.dart, already expanded).
    var bypass: [String]
}

/// Swift twin of lib/proxy/local_proxy.dart for the iOS packet tunnel, which
/// can't host Flutter: an HTTP proxy on 127.0.0.1 that adds the gateway
/// login to every request (CONNECT and absolute-form), sends bypassed hosts
/// direct, and turns a refused login (407) into a 502 plus [rejected].
/// Everything runs on [queue]; each direction reads the next chunk only once
/// the previous one is sent, so memory stays flat on slow readers.
final class TunnelProxy {
    let queue = DispatchQueue(label: "io.shifter.tunnel.proxy")
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: ProxySession] = [:]
    private(set) var login: GatewayLogin?
    private(set) var authorization = ""
    private(set) var port: UInt16 = 0
    /// The gateway refused the login since it was last set.
    private(set) var rejected = false

    init() {
        raiseOpenFileLimit()
    }

    func start(_ done: @escaping (Result<UInt16, Error>) -> Void) {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            return done(.failure(error))
        }
        self.listener = listener
        var reported = false
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !reported else { return }
            switch state {
            case .ready:
                reported = true
                self.port = listener.port?.rawValue ?? 0
                done(.success(self.port))
            case let .failed(error):
                reported = true
                done(.failure(error))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            let session = ProxySession(proxy: self, client: connection)
            self.sessions[ObjectIdentifier(session)] = session
            session.start()
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for session in sessions.values { session.close() }
            sessions.removeAll()
        }
    }

    /// New location, New IP or settings: later requests use the new login;
    /// open gateway tunnels are dropped so apps reconnect through it.
    func setLogin(_ next: GatewayLogin) {
        queue.sync {
            let changed = login.map {
                $0.host != next.host || $0.port != next.port || $0.username != next.username || $0.password != next.password
            } ?? false
            login = next
            authorization = "Basic " + Data("\(next.username):\(next.password)".utf8).base64EncodedString()
            rejected = false
            if changed {
                for session in sessions.values where session.viaGateway { session.close() }
            }
        }
    }

    func status() -> [String: Any] {
        queue.sync { ["port": Int(port), "rejected": rejected, "connections": sessions.count] }
    }

    func markRejected() { rejected = true }

    func remove(_ session: ProxySession) {
        sessions[ObjectIdentifier(session)] = nil
    }

    func isBypassed(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return (login?.bypass ?? []).contains { rule in
            let r = rule.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if let slash = r.firstIndex(of: "/") {
                guard let ip = ipv4(h), let net = ipv4(String(r[..<slash])), let bits = UInt32(r[r.index(after: slash)...]), bits <= 32 else {
                    return false
                }
                let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
                return ip & mask == net & mask
            }
            if r.hasPrefix("*.") { return h == String(r.dropFirst(2)) || h.hasSuffix(String(r.dropFirst(1))) }
            return h == r
        }
    }

    private func ipv4(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ ($0 ?? 256) <= 255 }) else { return nil }
        return parts.reduce(0) { $0 << 8 | $1! }
    }

    /// Two open files per connection; extensions start with a low limit.
    private func raiseOpenFileLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        for want: rlim_t in [10240, 4096, 2048] where want > limit.rlim_cur && want <= limit.rlim_max {
            limit.rlim_cur = want
            if setrlimit(RLIMIT_NOFILE, &limit) == 0 { return }
        }
    }
}

/// One app connection: read the request head, open the upstream (gateway or
/// direct), then pipe both ways.
final class ProxySession {
    private weak var proxy: TunnelProxy?
    private let client: NWConnection
    private let queue: DispatchQueue
    private var upstream: NWConnection?
    private var head = Data()
    private var closed = false
    private var finishedDirections = 0
    private(set) var viaGateway = false

    private static let headEnd = Data("\r\n\r\n".utf8)
    private static let maxHead = 64 * 1024
    private static let chunk = 64 * 1024

    init(proxy: TunnelProxy, client: NWConnection) {
        self.proxy = proxy
        self.client = client
        queue = proxy.queue
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        client.start(queue: queue)
        readHead()
    }

    func close() {
        guard !closed else { return }
        closed = true
        client.cancel()
        upstream?.cancel()
        proxy?.remove(self)
    }

    private func readHead() {
        client.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if let data { self.head.append(data) }
            if let end = self.head.range(of: Self.headEnd) {
                let text = String(decoding: self.head[..<end.lowerBound], as: UTF8.self)
                self.route(text, rest: Data(self.head[end.upperBound...]))
            } else if done || error != nil || self.head.count > Self.maxHead {
                self.close()
            } else {
                self.readHead()
            }
        }
    }

    private func route(_ text: String, rest: Data) {
        guard let proxy else { return close() }
        var lines = text.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return reply("400 Bad Request") }
        let (method, target, version) = (parts[0], parts[1], parts[2])
        let isConnect = method.uppercased() == "CONNECT"
        guard let (host, port) = isConnect ? Self.hostPort(target) : Self.urlHostPort(target) else {
            return reply("400 Bad Request")
        }
        lines.removeAll { $0.lowercased().hasPrefix("proxy-authorization:") }

        if proxy.isBypassed(host) {
            // Direct, like the desktop proxy: CONNECT answers itself,
            // absolute-form becomes origin-form.
            lines.removeAll { $0.lowercased().hasPrefix("proxy-") }
            open(host: host, port: port) { [weak self] up in
                guard let self else { return }
                if isConnect {
                    self.client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                    if !rest.isEmpty { up.send(content: rest, completion: .contentProcessed { _ in }) }
                } else {
                    let request = "\(method) \(Self.originForm(target)) \(version)\r\n" + lines.map { $0 + "\r\n" }.joined() + "\r\n"
                    up.send(content: Data(request.utf8) + rest, completion: .contentProcessed { _ in })
                }
                self.pipe(from: self.client, to: up)
                self.pipe(from: up, to: self.client)
            }
            return
        }

        guard let login = proxy.login else { return reply("502 Bad Gateway") }
        viaGateway = true
        lines.append("Proxy-Authorization: \(proxy.authorization)")
        let request = "\(method) \(target) \(version)\r\n" + lines.map { $0 + "\r\n" }.joined() + "\r\n"
        open(host: login.host, port: login.port) { [weak self] up in
            guard let self else { return }
            up.send(content: Data(request.utf8) + rest, completion: .contentProcessed { _ in })
            self.pipe(from: self.client, to: up)
            // First answer: a 407 means the login was refused (plan out of
            // traffic, expired); the app shows that and disconnects.
            up.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [weak self] data, _, done, error in
                guard let self, !self.closed else { return }
                guard let data, !data.isEmpty else { return done || error != nil ? self.close() : () }
                if data.starts(with: Data("HTTP/1.1 407".utf8)) || data.starts(with: Data("HTTP/1.0 407".utf8)) {
                    self.proxy?.markRejected()
                    return self.reply("502 Bad Gateway")
                }
                self.client.send(content: data, completion: .contentProcessed { [weak self] err in
                    guard let self else { return }
                    if err != nil { return self.close() }
                    if done { self.finish(self.client) } else { self.pipe(from: up, to: self.client) }
                })
            }
        }
    }

    private func open(host: String, port: Int, ready: @escaping (NWConnection) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return reply("400 Bad Request") }
        let params = NWParameters.tcp
        params.preferNoProxies = true
        let up = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        upstream = up
        var started = false
        up.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready where !started:
                started = true
                ready(up)
            case .failed, .waiting:
                started ? self.close() : self.reply("502 Bad Gateway")
            case .cancelled:
                self.close()
            default:
                break
            }
        }
        up.start(queue: queue)
    }

    private func pipe(from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { [weak self] err in
                    guard let self, !self.closed else { return }
                    if err != nil { return self.close() }
                    if done { self.finish(to) } else { self.pipe(from: from, to: to) }
                })
            } else if error != nil {
                self.close()
            } else if done {
                self.finish(to)
            } else {
                self.pipe(from: from, to: to)
            }
        }
    }

    /// One side finished sending: pass the half-close on; both done = close.
    private func finish(_ to: NWConnection) {
        to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        finishedDirections += 1
        if finishedDirections == 2 { close() }
    }

    private func reply(_ status: String) {
        let text = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        client.send(content: Data(text.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    private static func hostPort(_ target: String) -> (String, Int)? {
        if target.hasPrefix("["), let end = target.firstIndex(of: "]") {
            let host = String(target[target.index(after: target.startIndex)..<end])
            let port = Int(target[target.index(after: end)...].dropFirst()) ?? 443
            return (host, port)
        }
        let parts = target.split(separator: ":")
        guard let host = parts.first, !host.isEmpty else { return nil }
        return (String(host), parts.count > 1 ? Int(parts[1]) ?? 443 : 443)
    }

    private static func urlHostPort(_ target: String) -> (String, Int)? {
        guard let url = URL(string: target), let host = url.host else { return nil }
        return (host, url.port ?? (url.scheme == "https" ? 443 : 80))
    }

    /// "http://host:80/path?q" -> "/path?q"
    private static func originForm(_ target: String) -> String {
        guard let scheme = target.range(of: "://") else { return target }
        let afterHost = target[scheme.upperBound...]
        return afterHost.firstIndex(of: "/").map { String(afterHost[$0...]) } ?? "/"
    }
}
