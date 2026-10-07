import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let launchColor = NSColor(srgbRed: 11 / 255, green: 14 / 255, blue: 23 / 255, alpha: 1)
    self.backgroundColor = launchColor
    let flutterViewController = FlutterViewController()
    flutterViewController.backgroundColor = launchColor
    self.contentViewController = flutterViewController

    // Open large and centred (the device preview needs room); allow shrinking
    // to phone width so the desktop app's compact layout can be tried too.
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = NSSize(width: min(1560, screen.width - 40), height: min(1000, screen.height - 40))
    self.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: true)
    self.minSize = NSSize(width: 320, height: 560)
    self.title = "Shifter"
    self.titlebarAppearsTransparent = true
    self.appearance = NSAppearance(named: .darkAqua)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
