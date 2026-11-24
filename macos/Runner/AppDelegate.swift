import Cocoa
import FlutterMacOS
import ServiceManagement

class AppDelegate: FlutterAppDelegate, NSMenuDelegate {
  private var statusItem: NSStatusItem?
  private var channel: FlutterMethodChannel?
  private var connection = "Starting"
  private var canConnect = false

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else { return }

    let channel = FlutterMethodChannel(name: "io.shifter.desktop", binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, reply in
      guard call.method == "connection", let state = call.arguments as? [String: Any],
            let self else { reply(FlutterMethodNotImplemented); return }
      self.connection = state["status"] as? String ?? "Disconnected"
      self.canConnect = state["canConnect"] as? Bool ?? false
      self.statusItem?.button?.toolTip = "Shifter · " + self.connection
      reply(nil)
    }
    self.channel = channel

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(systemSymbolName: "shield", accessibilityDescription: "Shifter")
    item.button?.image?.isTemplate = true
    item.button?.toolTip = "Shifter"
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.delegate = self
    item.menu = menu
    statusItem = item
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    openWindow()
    return false
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    addItem("Open Shifter", action: #selector(openWindow), to: menu)
    addItem(connection, action: nil, to: menu).isEnabled = false
    addItem(connection == "Connected" ? "Disconnect" : "Connect",
            action: #selector(toggleConnection), to: menu).isEnabled = canConnect
    if #available(macOS 13.0, *) {
      let status = SMAppService.mainApp.status
      let item = addItem(status == .requiresApproval ? "Allow Start at Login…" : "Start at Login",
                         action: #selector(toggleLoginItem), to: menu)
      item.state = status == .enabled ? .on : .off
    }
    menu.addItem(.separator())
    addItem("Quit Shifter", action: #selector(quit), to: menu)
  }

  @discardableResult
  private func addItem(_ title: String, action: Selector?, to menu: NSMenu) -> NSMenuItem {
    let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  @objc private func openWindow() {
    NSApp.activate(ignoringOtherApps: true)
    mainFlutterWindow?.deminiaturize(nil)
    mainFlutterWindow?.makeKeyAndOrderFront(nil)
  }

  @objc private func toggleConnection() {
    channel?.invokeMethod("toggleConnection", arguments: nil)
  }

  @objc private func toggleLoginItem() {
    guard #available(macOS 13.0, *) else { return }
    let service = SMAppService.mainApp
    do {
      switch service.status {
      case .enabled: try service.unregister()
      case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
      default: try service.register()
      }
    } catch {
      SMAppService.openSystemSettingsLoginItems()
    }
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
