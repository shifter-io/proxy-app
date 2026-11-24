# Shifter desktop releases

Start with a clean release checkout and use the same version and build number across the Flutter bundle, installer, and signed update metadata. Use a matching Rust target and Velopack CLI 1.2.161. Keep outputs and native caches outside synced folders. Publish artifacts before the feed using the procedure in [Application updates](app-updates.md).

## Windows

Build the Windows x64 Flutter app on the signing PC.

```powershell
flutter build windows --release --build-name 0.2.0 --build-number 2
.\tool\release\windows\pack.ps1 -Bundle .\build\windows\x64\runner\Release `
  -BuildRoot C:\BuildCache\Shifter -Output C:\BuildCache\Shifter\release-0.2.0 `
  -Version 0.2.0 -AzureMetadata <local-metadata.json> -SignTool <signtool.exe> `
  -AzureDlib <Azure.CodeSigning.Dlib.dll> -Publisher '<expected-publisher>' `
  -InnoCompiler <ISCC.exe> -Vpk <vpk.exe>
```

Use the existing Azure Artifact Signing account and profile on the PC. If the available Azure signing profile uses Key Vault rather than Artifact Signing, qualify that provider with a Velopack signing template before switching the script. The Windows loader, .NET runtime, and Azure Dlib must match the SignTool architecture. The pack script verifies signatures and timestamps on the inner Setup, packaged application binaries, and public Setup before recording artifact SHA-256. Keep signing credentials off the checkout. [Velopack signing](https://docs.velopack.io/packaging/signing) · [Azure Artifact Signing](https://learn.microsoft.com/en-us/azure/artifact-signing/how-to-signing-integrations)

Run the signed **Shifter Proxy App** Setup from a normal Windows desktop. It installs the app for the current user and offers to launch Shifter when Setup finishes. Velopack owns the installed app and its Windows removal entry. **Close window** hides Shifter to the notification area. **Quit Shifter** restores the previous proxy configuration and exits Shifter. For a lab machine with the earlier QA service install, use that build's machine uninstaller to remove its service and logon task before testing this package.

## macOS and Linux

Build the release bundle natively with Flutter, then use `tool/release/pack_desktop.py` to embed the bridge and call Velopack.

```sh
python3 tool/release/pack_desktop.py \
  --bundle build/macos/Build/Products/Release/Shifter.app \
  --build-root /path/to/cache --output /path/to/empty/release --version 0.2.0 \
  --mac-application 'Developer ID Application: …' \
  --mac-installer 'Developer ID Installer: …' --mac-notary-profile '…'
```

macOS uses direct `.pkg` distribution. Apple silicon acceptance uses the actual downloaded, signed and notarized installer, with Gatekeeper enabled. Keep `--qa` packages in the lab. The menu-bar item can reopen Shifter and preserves the current proxy connection when its window closes. On macOS 13+, **Start at Login** registers the app with Service Management. Disable the login item before removing the app. [Apple Developer ID](https://developer.apple.com/developer-id/) · [Service Management](https://developer.apple.com/documentation/servicemanagement/)

On Linux, pass the native Flutter Linux bundle as `--bundle` and omit the macOS arguments. Use the generated AppImage on a supported desktop as a regular user. Publish the full package and the standalone AppImage before the feed. Shifter can replace a writable AppImage in place with the verified Velopack payload. Test as a regular user on each supported architecture. Provide the standalone image as a fallback for read-only locations.
