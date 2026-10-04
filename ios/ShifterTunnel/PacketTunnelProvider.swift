import NetworkExtension

/// iOS's only way to give other apps a proxy: a packet tunnel whose network
/// settings carry an HTTP proxy ([TunnelProxy] on 127.0.0.1 in this
/// extension). It routes no packets (no included routes); apps that follow
/// the proxy talk to the local proxy, which speaks Shifter's proxy protocol
/// to the gateway, and everything else goes direct, as on desktop.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let proxy = TunnelProxy()

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let json = options?["login"] as? String, let login = Self.decode(Data(json.utf8)) else {
            // Started from Settings or On Demand, without a location chosen in the app.
            return completionHandler(Self.error("Open Shifter and tap Connect."))
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

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        proxy.stop()
        completionHandler()
    }

    /// {"login": {...}} swaps the login (new location, New IP, settings);
    /// anything else just asks for the status. Replies {"port", "rejected"}.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if let message = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
           let raw = message["login"], let data = try? JSONSerialization.data(withJSONObject: raw),
           let login = Self.decode(data) {
            let bypassChanged = proxy.login?.bypass != login.bypass
            proxy.setLogin(login)
            if bypassChanged {
                setTunnelNetworkSettings(Self.settings(port: proxy.port, login: login)) { [weak self] _ in
                    completionHandler?(self?.statusData())
                }
                return
            }
        }
        completionHandler?(statusData())
    }

    private func statusData() -> Data? {
        try? JSONSerialization.data(withJSONObject: proxy.status())
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
