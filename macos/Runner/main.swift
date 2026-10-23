import Cocoa
import Darwin

// Run Velopack's fast hooks before Flutter or AppKit initialize. The bridge is
// embedded and signed by the release packaging command; development builds
// without it remain usable but cannot install updates.
if let frameworks = Bundle.main.privateFrameworksPath,
   let handle = dlopen(frameworks + "/libshifter_updater.dylib", RTLD_NOW | RTLD_LOCAL),
   let symbol = dlsym(handle, "shifter_update_bootstrap") {
    typealias Bootstrap = @convention(c) () -> Void
    unsafeBitCast(symbol, to: Bootstrap.self)()
}
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
