// Runs the iOS tunnel's proxy (ios/ShifterTunnel/TunnelProxy.swift) as a
// plain Mac program, so test/proxy_test.dart runs the same tests against it
// as against the Dart proxy, without an iPhone (Network.framework is the
// same on macOS). The test builds it:
//   swiftc -O ios/ShifterTunnel/TunnelProxy.swift tool/e2e/tunnel_proxy/main.swift -o build/tunnel_proxy
//   build/tunnel_proxy <gateway host> <port> <username> <password> <bypass,comma,separated>
// Prints "PORT <n>". Commands on stdin: "login <username> [bypass]", "status".
import Foundation

let args = CommandLine.arguments
guard args.count >= 6, let gatewayPort = Int(args[2]) else {
    FileHandle.standardError.write(Data("usage: tunnel_proxy host port username password bypass\n".utf8))
    exit(2)
}
var login = GatewayLogin(host: args[1], port: gatewayPort, username: args[3], password: args[4], bypass: args[5].split(separator: ",").map(String.init))
let proxy = TunnelProxy()
proxy.setLogin(login)
proxy.start { result in
    switch result {
    case let .success(port): print("PORT \(port)")
    case let .failure(error): print("ERROR \(error)"); exit(1)
    }
    fflush(stdout)
}
DispatchQueue.global().async {
    while let line = readLine() {
        let parts = line.split(separator: " ").map(String.init)
        switch parts.first {
        case "login" where parts.count >= 2:
            login.username = parts[1]
            if parts.count > 2 { login.bypass = parts[2].split(separator: ",").map(String.init) }
            proxy.setLogin(login)
            print("OK")
        case "status":
            let data = try! JSONSerialization.data(withJSONObject: proxy.status())
            print(String(decoding: data, as: UTF8.self))
        default:
            print("?")
        }
        fflush(stdout)
    }
    exit(0)
}
dispatchMain()
