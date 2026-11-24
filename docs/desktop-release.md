# Shifter desktop releases

Start with a clean release checkout and use the same version and build number across the Flutter bundle, installer, and signed update metadata. Use a matching Rust target and Velopack CLI 1.2.161. Keep outputs and native caches outside synced folders. Publish artifacts before the feed using the procedure in [Application updates](app-updates.md).

## Windows

Build the Windows x64 Flutter app and the native SCM service on the signing PC.

```powershell
flutter build windows --release --build-name 0.2.0 --build-number 2
.\tool\release\windows\pack.ps1 -Bundle .\build\windows\x64\runner\Release `
  -ServiceBinary .\build\windows\x64\service\Release\ShifterService.exe `
  -BuildRoot C:\BuildCache\Shifter -Output C:\BuildCache\Shifter\release-0.2.0 `
  -Version 0.2.0 -AzureMetadata <local-metadata.json> -SignTool <signtool.exe> `
  -AzureDlib <Azure.CodeSigning.Dlib.dll> -Publisher '<expected-publisher>' `
  -InnoCompiler <ISCC.exe> -Vpk <vpk.exe>
```

Use the existing Azure Artifact Signing account and profile on the PC. If the available Azure signing profile uses Key Vault rather than Artifact Signing, qualify that provider with a Velopack signing template before switching the script. The Windows loader, .NET runtime, and Azure Dlib must match the SignTool architecture. The pack script verifies signatures and timestamps on the service, inner Setup, installed application payload, and public Setup before recording artifact SHA-256. Keep signing credentials off the checkout. [Velopack signing](https://docs.velopack.io/packaging/signing) · [Azure Artifact Signing](https://learn.microsoft.com/en-us/azure/artifact-signing/how-to-signing-integrations)

Run public Setup from the interactive desktop and accept the service installation prompt. The public signed installer places the LocalService background executable in Program Files and installs the Velopack app as the original user. Task Scheduler starts the tray agent at logon and retries after unexpected failures. **Close window** hides Shifter to the notification area. **Quit Shifter** asks the app to restore the user's proxy settings and exits the tray process. The machine service handles its SCM lifecycle separately. Use the public Setup's removal entry to deregister the machine service. The Velopack per-user removal entry owns the app files. When changing the service binary, qualify and distribute a new public signed Setup.

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

On Linux, pass the native Flutter Linux bundle as `--bundle` and omit the macOS arguments. Use the generated AppImage on a supported desktop as a regular user. Publish it before the signed feed entry that refers to it. Validate automatic replacement without elevation before changing the current manual replacement policy.

## Analytics staging

Set `SHIFTER_ANALYTICS_ORIGIN` to an HTTPS origin in the desktop and Android direct QA builds. Run the collector on a local interface behind a TLS reverse proxy. Disable access logging for analytics endpoints and apply request limits at the edge. Keep the database on a private, persistent volume.

```sh
python3 tool/analytics/collector.py --state /private/shifter-analytics \
  --windows-installer x64 0.2.0 /path/to/signed/Shifter-Setup-win-x64.exe
```

For a Shifter OpenPanel project, configure `SHIFTER_OPENPANEL_TRACK_URL`, `SHIFTER_OPENPANEL_CLIENT_ID`, and `SHIFTER_OPENPANEL_CLIENT_SECRET` on the collector. Use a write-only client. The collector stores an event once per install and ID and retries forwarding. OpenPanel reporting can use the event ID to deduplicate an ambiguous provider retry. Align project retention with the collector retention before enabling production. [OpenPanel Track API](https://openpanel.dev/docs/api/track)

The **Share app analytics** setting is off until the user enables it. App events queue while Shifter is connected and resume after a confirmed disconnect. The download endpoint `/download/windows/x64` optionally accepts a coarse source and campaign code. It uses an expiring token in the filename and streams unchanged installer bytes. Keep the name through install to link a consented initial launch. Test existing installs, repeated launches, and one-use token claiming before enabling attribution in the landing page.
