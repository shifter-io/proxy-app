import Flutter
import StoreKit
import UIKit

final class UpdateBridge {
    private let channel: FlutterMethodChannel
    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "shifter/updates", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    }
    private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "identity":
            var value: [String: Any] = ["distribution": "appStore", "architecture": "universal", "osVersion": UIDevice.current.systemVersion]
            if let storefront = SKPaymentQueue.default().storefront { value["storefront"] = storefront.countryCode }
            result(value)
        case "eligible":
            guard let release = args["release"] as? [String: Any], let minimum = release["minimumOs"] as? String else { return result(false) }
            result(UIDevice.current.systemVersion.compare(minimum, options: .numeric) != .orderedAscending)
        case "openStore":
            guard let id = args["productId"] as? String, !id.isEmpty, id.allSatisfy({ $0.isNumber }),
                  let url = URL(string: "https://apps.apple.com/app/id\(id)") else {
                return result(FlutterError(code: "configuration", message: "The App Store listing is not configured.", details: nil))
            }
            UIApplication.shared.open(url, options: [:]) { opened in
                result(opened ? nil : FlutterError(code: "store", message: "Could not open the App Store.", details: nil))
            }
        case "reconcile": result([:])
        default: result(FlutterMethodNotImplemented)
        }
    }
}
