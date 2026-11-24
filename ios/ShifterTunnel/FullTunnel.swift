import Foundation
import HevSocks5Tunnel
import Network
import NetworkExtension

/// The gateway's SOCKS5 login. Same username format as the HTTP gateway
/// (targeting and session in the username).
struct SocksLogin: Codable, Equatable {
    var host: String
    var port: Int
    var username: String
    var password: String
}

/// Full-device mode: the tunnel routes every IPv4 and IPv6 packet, and
/// hev-socks5-tunnel (ios/Frameworks, MIT) turns them back into SOCKS5
/// connections to the gateway: TCP as CONNECT, UDP (QUIC, DNS, calls, games)
/// as UDP ASSOCIATE. The extension's own sockets never enter the tunnel, so
/// the engine reaches the gateway directly.
final class FullTunnel {
    private let queue = DispatchQueue(label: "io.shifter.tunnel.full")
    private var thread: Thread?
    private var finished = DispatchSemaphore(value: 0)
    private(set) var login: SocksLogin?
    private(set) var rejected = false

    /// Local networks (printers, casting, the router) stay direct.
    static let directRoutes: [NEIPv4Route] = [
        NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
        NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
        NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
        NEIPv4Route(destinationAddress: "169.254.0.0", subnetMask: "255.255.0.0"),
        NEIPv4Route(destinationAddress: "224.0.0.0", subnetMask: "240.0.0.0"),
    ]

    static func settings(for login: SocksLogin) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: login.host)
        settings.mtu = NSNumber(value: mtu)
        let ipv4 = NEIPv4Settings(addresses: [tunnelIPv4], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = directRoutes
        settings.ipv4Settings = ipv4
        // IPv6 also enters the tunnel, so nothing leaves around the proxy.
        let ipv6 = NEIPv6Settings(addresses: [tunnelIPv6], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6
        // DNS goes through the tunnel as UDP over SOCKS5, never to the ISP.
        let dns = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        return settings
    }

    /// Checks the login and pins the session to a UDP-capable exit before any
    /// TCP flows (a first UDP request on a TCP-pinned session moves the exit).
    /// Throws `FullTunnel.Rejected` when the gateway refuses the login.
    func prepare(_ login: SocksLogin) async throws {
        try await SocksProbe(login).checkLoginAndWarmUDP()
    }

    /// Starts the engine on the tunnel's packets. Call after the network
    /// settings are applied (the utun interface exists then).
    func start(_ login: SocksLogin) throws {
        guard let fd = Self.tunnelFileDescriptor() else { throw Self.error("Shifter couldn't open the connection. Try again.") }
        stop()
        self.login = login
        rejected = false
        let config = Self.config(for: login)
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

    /// Stops the engine and closes every connection (new location or New IP
    /// restarts it, so all apps reconnect through the new exit).
    func stop() {
        guard thread != nil else { return }
        hev_socks5_tunnel_quit()
        _ = finished.wait(timeout: .now() + 3)
        thread = nil
    }

    func markRejected() { rejected = true }

    func status() -> [String: Any] {
        ["port": 0, "full": true, "rejected": rejected]
    }

    // ── Engine configuration ─────────────────────────────────────────────

    private static let mtu = 8500
    private static let tunnelIPv4 = "198.18.0.1"
    private static let tunnelIPv6 = "fc00::1"

    private static func config(for login: SocksLogin) -> String {
        // Small buffers and a session cap keep the engine well under the
        // 50 MB iOS allows a tunnel extension (values from the engine's docs).
        """
        tunnel:
          mtu: \(mtu)
          ipv4: \(tunnelIPv4)
          ipv6: '\(tunnelIPv6)'
        socks5:
          address: '\(yaml(login.host))'
          port: \(login.port)
          udp: 'udp'
          username: '\(yaml(login.username))'
          password: '\(yaml(login.password))'
        misc:
          task-stack-size: 24576
          tcp-buffer-size: 4096
          max-session-count: 1200
          connect-timeout: 10000
          log-level: warn
        """
    }

    private static func yaml(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }

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
    private struct CtlInfo {
        var id: UInt32 = 0
        var name: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) // char[96]
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

/// A short SOCKS5 exchange with the gateway before the engine starts:
/// confirms the login, then one UDP ASSOCIATE with a DNS query so the session
/// starts on a UDP-capable exit.
private struct SocksProbe {
    let login: SocksLogin
    init(_ login: SocksLogin) { self.login = login }

    func checkLoginAndWarmUDP() async throws {
        let control = try await connect(.tcp)
        defer { control.cancel() }
        try await send(control, Data([5, 1, 2]))
        let method = try await receive(control, 2)
        guard method.count == 2, method[1] == 2 else { throw FullTunnel.error("The Shifter gateway didn't accept the login method.") }
        let user = Data(login.username.utf8), pass = Data(login.password.utf8)
        try await send(control, Data([1, UInt8(user.count)]) + user + Data([UInt8(pass.count)]) + pass)
        let auth = try await receive(control, 2)
        guard auth.count == 2, auth[1] == 0 else { throw FullTunnel.Rejected() }

        // UDP ASSOCIATE from 0.0.0.0:0; the reply names the relay.
        try await send(control, Data([5, 3, 0, 1, 0, 0, 0, 0, 0, 0]))
        let head = try await receive(control, 4)
        guard head.count == 4, head[1] == 0 else { return } // No UDP on this exit: TCP still works.
        let relayHost: String
        switch head[3] {
        case 1: relayHost = try await receive(control, 4).map(String.init).joined(separator: ".")
        case 3: relayHost = String(decoding: try await receive(control, Int(try await receive(control, 1)[0])), as: UTF8.self)
        default: _ = try await receive(control, 16); return
        }
        let portBytes = try await receive(control, 2)
        let relayPort = UInt16(portBytes[0]) << 8 | UInt16(portBytes[1])
        let host = relayHost == "0.0.0.0" ? login.host : relayHost
        let udp = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: relayPort)!, using: .udp)
        defer { udp.cancel() }
        try await ready(udp)
        // A DNS query for example.com to 1.1.1.1:53, wrapped in the SOCKS5 UDP header.
        let query = Data([0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7]) + Data("example".utf8) + Data([3]) + Data("com".utf8) + Data([0, 0, 1, 0, 1])
        try await send(udp, Data([0, 0, 0, 1, 1, 1, 1, 1, 0, 53]) + query)
        _ = try? await withTimeout(3) { try await receiveMessage(udp) }
    }

    private func connect(_ params: NWParameters) async throws -> NWConnection {
        let c = NWConnection(host: NWEndpoint.Host(login.host), port: NWEndpoint.Port(rawValue: UInt16(login.port))!, using: params)
        try await ready(c)
        return c
    }

    private func ready(_ c: NWConnection) async throws {
        try await withTimeout(10) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let once = Once()
                c.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.run { cont.resume() }
                    case let .failed(e), let .waiting(e): once.run { cont.resume(throwing: e) }
                    case .cancelled: once.run { cont.resume(throwing: FullTunnel.error("Connection cancelled.")) }
                    default: break
                    }
                }
                c.start(queue: .global())
            }
        }
    }

    private func send(_ c: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: data, completion: .contentProcessed { e in e.map { cont.resume(throwing: $0) } ?? cont.resume() })
        }
    }

    private func receive(_ c: NWConnection, _ count: Int) async throws -> Data {
        try await withTimeout(10) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                c.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, e in
                    if let e { return cont.resume(throwing: e) }
                    guard let data, data.count == count else { return cont.resume(throwing: FullTunnel.error("The Shifter gateway closed the connection.")) }
                    cont.resume(returning: data)
                }
            }
        }
    }

    private func receiveMessage(_ c: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            c.receiveMessage { data, _, _, e in
                if let e { return cont.resume(throwing: e) }
                cont.resume(returning: data ?? Data())
            }
        }
    }

    private func withTimeout<T>(_ seconds: Double, _ body: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw FullTunnel.error("The Shifter gateway didn't answer in time.")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
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
