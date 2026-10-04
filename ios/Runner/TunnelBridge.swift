import Flutter
import NetworkExtension

/// `shifter/tunnel` channel (lib/proxy/tunnel_proxy_engine.dart): installs
/// the Shifter VPN configuration once (iOS asks the user), starts the packet
/// tunnel with the gateway login, swaps the login while connected, and
/// reports when the tunnel stops without the app asking.
final class TunnelBridge {
    private static let providerBundleIdentifier = (Bundle.main.bundleIdentifier ?? "io.shifter.shifterApp") + ".tunnel"
    private let channel: FlutterMethodChannel
    private var manager: NETunnelProviderManager?
    private var stopRequested = false
    private var wasConnected = false

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "shifter/tunnel", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
        NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] note in
            self?.statusChanged((note.object as? NEVPNConnection)?.status)
        }
    }

    private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "apply":
            guard let login = call.arguments as? [String: Any] else { return result(FlutterError(code: "args", message: "No login", details: nil)) }
            apply(login, result)
        case "stop":
            stopRequested = true
            manager?.connection.stopVPNTunnel()
            result(nil)
        case "status":
            send([:]) { reply in result(reply) }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func apply(_ login: [String: Any], _ result: @escaping FlutterResult) {
        loadManager { [weak self] manager, error in
            guard let self else { return }
            guard let manager else {
                return result(FlutterError(code: "config", message: Self.message(error), details: nil))
            }
            self.manager = manager
            if manager.connection.status == .connected {
                return self.send(["login": login]) { reply in result(reply) }
            }
            do {
                let json = String(decoding: try JSONSerialization.data(withJSONObject: login), as: UTF8.self)
                self.stopRequested = false
                try manager.connection.startVPNTunnel(options: ["login": json as NSString])
            } catch {
                return result(FlutterError(code: "start", message: Self.message(error), details: nil))
            }
            self.waitForConnected(manager, since: Date()) { connected in
                guard connected else {
                    return result(FlutterError(code: "start", message: "The connection didn't start. Try again.", details: nil))
                }
                self.send([:]) { reply in result(reply) }
            }
        }
    }

    /// The saved Shifter VPN configuration, created on first use (iOS shows
    /// "Shifter Would Like to Add VPN Configurations").
    private func loadManager(_ done: @escaping (NETunnelProviderManager?, Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error { return done(nil, error) }
            let manager = managers?.first ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.providerBundleIdentifier
            proto.serverAddress = "Shifter"
            manager.protocolConfiguration = proto
            manager.localizedDescription = "Shifter"
            manager.isEnabled = true
            manager.saveToPreferences { error in
                if let error { return done(nil, error) }
                manager.loadFromPreferences { error in done(error == nil ? manager : nil, error) }
            }
        }
    }

    private func waitForConnected(_ manager: NETunnelProviderManager, since start: Date, _ done: @escaping (Bool) -> Void) {
        let elapsed = Date().timeIntervalSince(start)
        switch manager.connection.status {
        case .connected: return done(true)
        // A tunnel that fails to start drops back to disconnected.
        case .disconnected, .invalid where elapsed > 2: return done(false)
        default: if elapsed > 20 { return done(false) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.waitForConnected(manager, since: start, done) }
    }

    /// Message to the running tunnel; replies {"port", "rejected"} or nil.
    private func send(_ message: [String: Any], _ done: @escaping ([String: Any]?) -> Void) {
        guard let session = manager?.connection as? NETunnelProviderSession, session.status == .connected,
              let data = try? JSONSerialization.data(withJSONObject: message) else { return done(nil) }
        do {
            try session.sendProviderMessage(data) { reply in
                let status = reply.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                DispatchQueue.main.async { done(status) }
            }
        } catch {
            done(nil)
        }
    }

    private func statusChanged(_ status: NEVPNStatus?) {
        if status == .connected { wasConnected = true }
        guard status == .disconnected, wasConnected else { return }
        wasConnected = false
        if !stopRequested { channel.invokeMethod("stopped", arguments: "disconnected") }
        stopRequested = false
    }

    private static func message(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "Could not set up the connection." }
        if error.domain == NEVPNErrorDomain, error.code == NEVPNError.configurationReadWriteFailed.rawValue {
            return "Shifter needs your permission to add a VPN configuration. Tap Connect and choose Allow."
        }
        return error.localizedDescription
    }
}
