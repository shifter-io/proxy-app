import NetworkExtension

/// The Shifter packet tunnel. Two modes, chosen by the login the app sends:
///
/// - Full device (login has `socks`): every packet goes through the gateway,
///   encrypted ([FullTunnel], [GatewayBridge]).
/// - Proxy settings (no `socks`): the tunnel routes no packets; its network
///   settings carry an HTTP proxy ([TunnelProxy] on 127.0.0.1 in this
///   extension), and apps that follow it go through Shifter.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let proxy = TunnelProxy()
    private let full = FullTunnel()
    private var login: GatewayLogin?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let json = options?["login"] as? String, let login = Self.decode(Data(json.utf8)) else {
            // Started from Settings or On Demand, without a location chosen in the app.
            return completionHandler(Self.error("Open Shifter and tap Connect."))
        }
        self.login = login
        if let socks = login.socks {
            return startFull(socks, completionHandler)
        }
        proxy.setLogin(login)
        proxy.start { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                completionHandler(error)
            case let .success(port):
                self.setTunnelNetworkSettings(Self.settings(port: port, login: login), completionHandler: completionHandler)
            }
        }
    }

    private func startFull(_ socks: SocksLogin, _ completionHandler: @escaping (Error?) -> Void) {
        Task {
            do {
                let bridge = try await full.prepare(socks)
                try await setTunnelNetworkSettings(FullTunnel.settings(for: socks))
                try await full.start(bridge)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        full.stop()
        proxy.stop()
        completionHandler()
    }

    /// {"login": {...}} swaps the login (new location, New IP, settings);
    /// anything else just asks for the status. Replies {"port", "rejected"}
    /// (plus "full" in full-device mode).
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              let raw = message["login"], let data = try? JSONSerialization.data(withJSONObject: raw),
              let login = Self.decode(data) else {
            completionHandler?(statusData())
            return
        }
        let previous = self.login
        self.login = login
        if let socks = login.socks {
            if previous?.socks == socks {
                completionHandler?(statusData())
                return
            }
            // A new exit for every app: restart the engine on the new login.
            Task {
                do {
                    let bridge = try await full.prepare(socks)
                    if previous?.socks == nil {
                        proxy.stop()
                        try await setTunnelNetworkSettings(FullTunnel.settings(for: socks))
                    }
                    try await full.start(bridge)
                } catch is FullTunnel.Rejected {
                    full.markRejected()
                } catch {}
                completionHandler?(statusData())
            }
            return
        }
        proxy.setLogin(login)
        if previous?.socks != nil {
            full.stop()
            proxy.start { [weak self] result in
                guard let self, case let .success(port) = result else { return completionHandler?(self?.statusData()) ?? () }
                self.setTunnelNetworkSettings(Self.settings(port: port, login: login)) { [weak self] _ in
                    completionHandler?(self?.statusData())
                }
            }
            return
        }
        if previous?.bypass != login.bypass {
            setTunnelNetworkSettings(Self.settings(port: proxy.port, login: login)) { [weak self] _ in
                completionHandler?(self?.statusData())
            }
            return
        }
        completionHandler?(statusData())
    }

    private func statusData() -> Data? {
        try? JSONSerialization.data(withJSONObject: login?.socks != nil ? full.status() : proxy.status())
    }

    private static func settings(port: UInt16, login: GatewayLogin) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.215.173.1"], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = []
        settings.ipv4Settings = ipv4
        let server = NEProxyServer(address: "127.0.0.1", port: Int(port))
        let proxy = NEProxySettings()
        proxy.httpEnabled = true
        proxy.httpServer = server
        proxy.httpsEnabled = true
        proxy.httpsServer = server
        proxy.excludeSimpleHostnames = true
        // Host names only; the local proxy itself sends CIDR ranges direct.
        proxy.exceptionList = login.bypass.filter { $0.range(of: "^[A-Za-z0-9*._-]+$", options: .regularExpression) != nil }
        // Every domain: without routes, proxy settings apply only to matchDomains.
        proxy.matchDomains = [""]
        settings.proxySettings = proxy
        return settings
    }

    private static func decode(_ data: Data) -> GatewayLogin? {
        try? JSONDecoder().decode(GatewayLogin.self, from: data)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "io.shifter.tunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
