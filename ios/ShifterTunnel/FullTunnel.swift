import Foundation
import HevSocks5Tunnel
import Network
import NetworkExtension

/// Full-device mode: the tunnel routes every IPv4 and IPv6 packet,
/// hev-socks5-tunnel (ios/Frameworks, MIT) turns them back into TCP
/// connections, and [GatewayBridge] carries each one to the gateway over TLS
/// as an HTTP CONNECT with the plan login. DNS is answered in the engine and
/// resolved by name at the gateway. UDP is refused for now (apps fall back to
/// TCP). The extension's own sockets never enter the tunnel, so the bridge
/// reaches the gateway directly.
final class FullTunnel {
    private var thread: Thread?
    private var finished = DispatchSemaphore(value: 0)
    private var bridge: GatewayBridge?
    private var mappedRange = 0
    private(set) var login: SocksLogin?
    private var rejectedLogin = false
    var rejected: Bool { rejectedLogin || bridge?.rejected == true }

    /// Local networks (printers, casting, the router) stay direct.
    static let directRoutes: [NEIPv4Route] = [
        NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
        NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
        NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
        NEIPv4Route(destinationAddress: "169.254.0.0", subnetMask: "255.255.0.0"),
        NEIPv4Route(destinationAddress: "224.0.0.0", subnetMask: "240.0.0.0"),
    ]

    static func settings(for login: SocksLogin) -> NEPacketTunnelNetworkSettings {
        // iOS wants an IP address here, not a host name.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: ipv4Address(of: login.host) ?? "127.0.0.1")
        settings.mtu = NSNumber(value: mtu)
        let ipv4 = NEIPv4Settings(addresses: [tunnelIPv4], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = directRoutes
        settings.ipv4Settings = ipv4
        // IPv6 also enters the tunnel, so nothing leaves around the proxy.
        let ipv6 = NEIPv6Settings(addresses: [tunnelIPv6], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6
        // DNS is answered inside the engine (mapped DNS): apps get a
        // placeholder address and the gateway resolves the real name at the
        // exit, so DNS never reaches the ISP and needs no UDP.
        let dns = NEDNSSettings(servers: [mappedDNS])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        return settings
    }

    /// Checks that the gateway answers and accepts the plan login, and
    /// returns the bridge to run with. Throws `FullTunnel.Rejected` when the
    /// gateway refuses the login.
    func prepare(_ login: SocksLogin) async throws -> GatewayBridge {
        let bridge = GatewayBridge(login)
        try await bridge.check()
        return bridge
    }

    /// Starts [bridge] and the engine on the tunnel's packets. Call after the
    /// network settings are applied (the utun interface exists then).
    func start(_ bridge: GatewayBridge) async throws {
        guard let fd = Self.tunnelFileDescriptor() else { throw Self.error("Shifter couldn't open the connection. Try again.") }
        stop()
        let port = try await bridge.start()
        self.bridge = bridge
        login = bridge.login
        rejectedLogin = false
        // A fresh placeholder range on every start: addresses apps cached
        // from the previous run fail instead of reaching another host.
        mappedRange = (mappedRange + 1) % Self.mappedRanges.count
        let config = Self.config(port: port, secret: bridge.secret, mappedNetwork: Self.mappedRanges[mappedRange])
        finished = DispatchSemaphore(value: 0)
        let done = finished
        let thread = Thread {
            let bytes = Array(config.utf8)
            _ = bytes.withUnsafeBufferPointer { buf in
                hev_socks5_tunnel_main_from_str(buf.baseAddress, UInt32(buf.count), fd)
            }
            done.signal()
        }
        thread.name = "io.shifter.tunnel.engine"
        thread.stackSize = 1 << 20
        self.thread = thread
        thread.start()
    }

    /// Stops the engine and the bridge; every connection closes (new location
    /// or New IP restarts them, so all apps reconnect through the new exit).
    func stop() {
        if thread != nil {
            hev_socks5_tunnel_quit()
            _ = finished.wait(timeout: .now() + 3)
            thread = nil
        }
        bridge?.stop()
        bridge = nil
    }

    func markRejected() { rejectedLogin = true }

    func status() -> [String: Any] {
        ["port": 0, "full": true, "rejected": rejected]
    }

    // ── Engine configuration ─────────────────────────────────────────────

    private static let mtu = 8500
    private static let tunnelIPv4 = "198.18.0.1"
    private static let tunnelIPv6 = "fc00::1"
    private static let mappedDNS = "198.18.0.2"

    /// Placeholder ranges for mapped DNS, inside 100.64.0.0/10.
    private static let mappedRanges = ["100.64.0.0", "100.80.0.0", "100.96.0.0", "100.112.0.0"]

    private static func config(port: UInt16, secret: String, mappedNetwork: String) -> String {
        // Small buffers and a session cap keep the engine well under the
        // 50 MB iOS allows a tunnel extension (values from the engine's docs).
        """
        tunnel:
          mtu: \(mtu)
          ipv4: \(tunnelIPv4)
          ipv6: '\(tunnelIPv6)'
        socks5:
          address: 127.0.0.1
          port: \(port)
          udp: 'udp'
          username: 'shifter'
          password: '\(secret)'
        mapdns:
          address: \(mappedDNS)
          port: 53
          network: \(mappedNetwork)
          netmask: 255.240.0.0
          cache-size: 4096
        misc:
          task-stack-size: 24576
          tcp-buffer-size: 4096
          max-session-count: 1200
          connect-timeout: 10000
          log-level: warn
        """
    }

    /// The gateway's first IPv4 address (the host itself when it already is one).
    private static func ipv4Address(of host: String) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        var addr = first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buf)
    }

    // ── The utun file descriptor ─────────────────────────────────────────

    /// NEPacketTunnelFlow doesn't expose its socket; find the utun control
    /// socket among the extension's descriptors (the method WireGuard uses).
    private static func tunnelFileDescriptor() -> Int32? {
        var info = CtlInfo()
        withUnsafeMutableBytes(of: &info.name) { raw in
            let name = Array("com.apple.net.utun_control".utf8)
            raw.copyBytes(from: name)
        }
        for fd: Int32 in 0...1024 {
            var addr = SockaddrCtl()
            var len = socklen_t(MemoryLayout<SockaddrCtl>.size)
            let ok = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) }
            }
            guard ok == 0, addr.family == UInt8(AF_SYSTEM) else { continue }
            if info.id == 0, ioctl(fd, ctlIocgInfo, &info) != 0 { continue }
            if addr.id == info.id { return fd }
        }
        return nil
    }

    /// sys/kern_control.h, which the iOS SDK doesn't ship.
    /// 100 bytes, 4-byte aligned, exactly like the C struct (an 8-byte field
    /// here would add padding and break the ioctl).
    private struct CtlInfo {
        var id: UInt32 = 0
        var name: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                   UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) // char[96]
    }
    private struct SockaddrCtl {
        var len: UInt8 = 0
        var family: UInt8 = 0
        var sysaddr: UInt16 = 0
        var id: UInt32 = 0
        var unit: UInt32 = 0
        var reserved: (UInt32, UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
    }
    /// _IOWR('N', 3, struct ctl_info)
    private static let ctlIocgInfo: UInt = 0xC064_4E03

    struct Rejected: LocalizedError {
        var errorDescription: String? { "Shifter refused the plan login. Check the plan in your Shifter account." }
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "io.shifter.tunnel", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Local bridge between the engine and the Shifter gateway, on 127.0.0.1
/// inside the extension. Each SOCKS5 CONNECT from the engine becomes one TLS
/// connection to the gateway carrying an HTTP CONNECT with the plan login, so
/// everything between the device and the gateway is encrypted. The engine
/// must present [secret]; UDP is refused for now.
final class GatewayBridge: @unchecked Sendable {
    let login: SocksLogin
    let secret: String = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    private(set) var rejected = false
    fileprivate let queue = DispatchQueue(label: "io.shifter.tunnel.bridge")
    private var listener: NWListener?
    fileprivate var sessions: [ObjectIdentifier: BridgeSession] = [:]
    fileprivate let authorization: String

    init(_ login: SocksLogin) {
        self.login = login
        authorization = "Basic " + Data("\(login.username):\(login.password)".utf8).base64EncodedString()
    }

    /// Listens on 127.0.0.1; returns the port.
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            let session = BridgeSession(bridge: self, client: connection)
            self.sessions[ObjectIdentifier(session)] = session
            session.start()
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { cont.resume(returning: listener.port?.rawValue ?? 0) }
                case let .failed(e): once.run { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for session in sessions.values { session.close() }
            sessions.removeAll()
        }
    }

    /// One test CONNECT before the tunnel starts. Throws `FullTunnel.Rejected`
    /// on a refused login, another error when the gateway can't be reached.
    func check() async throws {
        let status: String? = try await withCheckedThrowingContinuation { cont in
            let once = Once()
            connectGateway("www.google.com:443") { up, status in
                up?.cancel()
                once.run { cont.resume(returning: status) }
            }
            queue.asyncAfter(deadline: .now() + 15) {
                once.run { cont.resume(throwing: FullTunnel.error("Couldn't reach Shifter. Check your connection and try again.")) }
            }
        }
        if status == "407" { throw FullTunnel.Rejected() }
        guard status == "200" else { throw FullTunnel.error("Couldn't reach Shifter. Check your connection and try again.") }
    }

    /// TLS to the gateway, then CONNECT [target]. Calls back on [queue] with
    /// the open connection (status 200) and the status code, or nil on failure.
    fileprivate func connectGateway(_ target: String, _ done: @escaping (NWConnection?, String?) -> Void) {
        let up = NWConnection(host: NWEndpoint.Host(login.host), port: NWEndpoint.Port(rawValue: UInt16(login.port))!,
                              using: NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options()))
        var reported = false
        let finish: (NWConnection?, String?) -> Void = { c, s in
            guard !reported else { return }
            reported = true
            done(c, s)
        }
        up.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let request = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\nProxy-Authorization: \(self.authorization)\r\n\r\n"
                up.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
                Self.readHead(up, Data()) { head, rest in
                    let status = head.flatMap { String(decoding: $0, as: UTF8.self).split(separator: " ").dropFirst().first.map(String.init) }
                    if status == "407" { self.rejected = true }
                    if status == "200", rest.isEmpty {
                        finish(up, status)
                    } else {
                        up.cancel()
                        finish(nil, status)
                    }
                }
            case .failed, .cancelled:
                finish(nil, nil)
            case let .waiting(error):
                _ = error
                up.cancel()
                finish(nil, nil)
            default:
                break
            }
        }
        up.start(queue: queue)
    }

    /// Reads an HTTP header block; calls back with it and any bytes after it.
    fileprivate static func readHead(_ c: NWConnection, _ buffer: Data, _ done: @escaping (Data?, Data) -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                return done(buffer[..<end.lowerBound], Data(buffer[end.upperBound...]))
            }
            if isComplete || error != nil || buffer.count > 16_384 { return done(nil, Data()) }
            readHead(c, buffer, done)
        }
    }

    /// host:port with a plain host name or IPv4 address: nothing that could break the CONNECT line.
    fileprivate static func valid(_ target: String) -> Bool {
        target.range(of: "^[A-Za-z0-9.-]{1,253}:[0-9]{1,5}$", options: .regularExpression) != nil
    }
}

/// One engine connection: SOCKS5 handshake (secret), then a piped CONNECT.
private final class BridgeSession {
    private weak var bridge: GatewayBridge?
    private let client: NWConnection
    private var upstream: NWConnection?
    private var buffer = Data()
    private var closed = false
    private var finishedDirections = 0

    init(bridge: GatewayBridge, client: NWConnection) {
        self.bridge = bridge
        self.client = client
    }

    func start() {
        guard let bridge else { return }
        client.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
        }
        client.start(queue: bridge.queue)
        read(2) { head in
            guard head[0] == 5 else { return self.close() }
            self.read(Int(head[1])) { methods in
                guard methods.contains(2) else { return self.send([5, 0xFF], thenClose: true) }
                self.send([5, 2])
                self.authenticate()
            }
        }
    }

    private func authenticate() {
        read(2) { head in
            self.read(Int(head[1])) { user in
                self.read(1) { len in
                    self.read(Int(len[0])) { pass in
                        guard let bridge = self.bridge,
                              String(decoding: user, as: UTF8.self) == "shifter",
                              Self.constantTimeEqual(pass, Data(bridge.secret.utf8)) else {
                            return self.send([1, 1], thenClose: true)
                        }
                        self.send([1, 0])
                        self.request()
                    }
                }
            }
        }
    }

    private func request() {
        read(4) { head in
            guard head[1] == 1 else { return self.reply(7) } // only CONNECT: no UDP for now
            switch head[3] {
            case 1:
                self.read(4) { ip in self.readPort(ip.map(String.init).joined(separator: ".")) }
            case 3:
                self.read(1) { len in self.read(Int(len[0])) { name in self.readPort(String(decoding: name, as: UTF8.self)) } }
            default:
                self.reply(8) // IPv6: the gateway reaches IPv4 only
            }
        }
    }

    private func readPort(_ host: String) {
        read(2) { p in
            let target = "\(host):\(Int(p[0]) << 8 | Int(p[1]))"
            guard GatewayBridge.valid(target), let bridge = self.bridge else { return self.reply(4) }
            bridge.connectGateway(target) { up, _ in
                guard !self.closed else { up?.cancel(); return }
                guard let up else { return self.reply(5) }
                self.upstream = up
                self.send([5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
                if !self.buffer.isEmpty {
                    let early = self.buffer
                    self.buffer = Data()
                    up.send(content: early, completion: .contentProcessed { _ in })
                }
                self.pipe(from: self.client, to: up)
                self.pipe(from: up, to: self.client)
            }
        }
    }

    private func reply(_ code: UInt8) {
        send([5, code, 0, 1, 0, 0, 0, 0, 0, 0], thenClose: true)
    }

    private func send(_ bytes: [UInt8], thenClose: Bool = false) {
        client.send(content: Data(bytes), completion: .contentProcessed { [weak self] _ in
            if thenClose { self?.close() }
        })
    }

    /// Exactly [count] bytes from the client (buffered), then [then].
    private func read(_ count: Int, _ then: @escaping (Data) -> Void) {
        if buffer.count >= count {
            let chunk = Data(buffer.prefix(count))
            buffer = Data(buffer.dropFirst(count))
            return then(chunk)
        }
        client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            if self.buffer.count < count && (isComplete || error != nil) { return self.close() }
            self.read(count, then)
        }
    }

    private func pipe(from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
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

    func close() {
        guard !closed else { return }
        closed = true
        client.cancel()
        upstream?.cancel()
        bridge?.sessions[ObjectIdentifier(self)] = nil
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}

/// Runs its block at most once, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ block: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { block() }
    }
}
