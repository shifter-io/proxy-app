# Application updates

Shifter has one update coordinator and a modal above the application Navigator. Settings and the signed-out screen expose updates independently of account access. Update failures leave the application usable.

Production update discovery is **disabled by default**. Building the code does not create a production signing identity, publish a release, or qualify an actual installation upgrade.

## Build configuration

Provide these compile-time definitions to Flutter through a private, untracked `--dart-define-from-file` configuration:

- `SHIFTER_UPDATES_ENABLED`: `true` only for qualified releases.
- `SHIFTER_UPDATE_ORIGIN`: one HTTPS origin, without a path, query, credentials or fragment.
- `SHIFTER_UPDATE_PUBLIC_KEYS`: a JSON string mapping key IDs to Base64-encoded **raw 32-byte Ed25519 public keys**. These are public values; the private keys never enter the build.
- `SHIFTER_APP_STORE_ID`: Apple's numeric production listing ID, required for iOS store handoff.

Example configuration structure, with values deliberately left unconfigured:

```json
{
  "SHIFTER_UPDATES_ENABLED": false,
  "SHIFTER_UPDATE_ORIGIN": "",
  "SHIFTER_UPDATE_PUBLIC_KEYS": "{}",
  "SHIFTER_APP_STORE_ID": ""
}
```

The feed path is `/<distribution>/<platform>/<architecture>/stable.json`. Distributions are `desktop`, `direct`, `play`, and `appStore`; mobile architecture is `universal`. Desktop architectures are `arm64` and `x64`. The native application/package ID must match every release entry; record it from the actual installed build rather than assuming Flutter's project name is the package ID on every platform.

## User behavior

Automatic checks start after app startup and run on foreground return when six hours have elapsed. Manual checks share any active transaction. Automatic prompts require a disconnected app with no other Navigator dialog and appear at most once per 24 hours. **Later** suppresses automatic prompts for seven days.

Downloads and installer handoffs each require an explicit action. Direct APK downloads are canceled when the app is hidden; retries start from zero. Desktop downloads survive modal dismissal. Completed downloads persist separately from account data. The next startup checks the native version and reconciles native installation state.

Installation holds the connection gate, restores OS proxy settings before stopping the listener, re-fetches authenticated metadata, revalidates the artifact and then invokes the native updater. Restoration failures keep backups and prevent handoff. Restart suppression does not change the user's Connect on launch preference; native version/build changes also suppress reconnection after externally initiated store upgrades.

App-managed update traffic follows the active local proxy explicitly. An ambiguous connection state blocks the request. Routing changes cancel requests, and proxy failures do not fall back to a direct connection. Native store traffic remains OS-managed.

## Platform integration

### Desktop

`native/updater` pins Velopack to **1.2.161**, with a committed Cargo lockfile. A small dynamic library exposes a C ABI; Windows, macOS and Linux runners bootstrap it before Flutter. This uses a dynamic library instead of the approved plan's static-library proposal so embedding is explicit and does not require a Rust toolchain for ordinary development builds.

Build the Flutter desktop bundle, then embed the bridge **before signing**:

```sh
python3 tool/update/build_bridge.py \
  --bundle /absolute/path/to/Shifter.app \
  --build-root "$HOME/Library/Caches/shifter-vpn/build/release-checkout"
```

Use `--target` when cross-compiling the bridge; the target must match the Flutter bundle. Universal macOS distribution requires compiling both architectures and combining them before signing. The script checks free-space headroom and uses the explicit external Cargo target. Follow the project disk preflight and remove disposable outputs after archiving required evidence.

Install the matching `vpk` CLI version through .NET tooling. Use the platform's supported Velopack packaging/signing process with increasing package versions, full packages and the `stable` channel. The Flutter native version and Velopack package version must agree. Windows requires trusted Authenticode signing and timestamps; macOS requires Developer ID signing, notarization, applicable stapling, and preserved entitlements. Production packaging is not qualified by a debug build.

The native bridge receives only a locally authenticated package. It rehashes the source, generates a local feed, verifies cached destinations before reuse and after staging, and only then lets Velopack perform its handoff. Startup auto-apply is disabled; bootstrap uses a separate empty package directory. A Dart transaction lock and a native installer lock prevent concurrent desktop operations.

**Linux automatic installation is deliberately disabled.** Velopack 1.2.161 can invoke privilege escalation; the approved no-elevation release gate is unresolved. Its runner/bridge integration exists, but a reviewed no-elevation solution and real AppImage qualification are required before enabling Linux installation. The UI explains that the AppImage must be updated manually.

### Android

Build with `--flavor play` or `--flavor direct`. The compiled flavor determines the update mechanism; installer-source guessing never switches channels.

```sh
flutter build apk --debug --flavor direct
flutter build apk --debug --flavor play
```

Only the direct source set includes `REQUEST_INSTALL_PACKAGES`, APK validation and `PackageInstaller`. It checks hash, length, package identity, increasing `versionCode`, minimum SDK, ABI and signing certificate before requesting installation. Android's system installer performs final signature enforcement and user confirmation. Version 1 conservatively requires the same signing certificate; certificate rotation needs separate qualification.

If Android disallows installations from Shifter, the app opens the appropriate system settings and asks the user to retry installation afterward. It never uninstalls the existing app to work around a signing conflict. Session IDs and operation IDs persist across Activity/process recreation.

The Play source set depends on Google's in-app update library and uses flexible updates. Google Play eligibility is checked afresh before starting. Download state is polled/reconciled; explicit completion occurs only after safe disconnect. The Play build has no direct APK fallback.

Release signing fails closed unless all of these environment variables exist:

- `SHIFTER_ANDROID_KEYSTORE`
- `SHIFTER_ANDROID_STORE_PASSWORD`
- `SHIFTER_ANDROID_KEY_ALIAS`
- `SHIFTER_ANDROID_KEY_PASSWORD`

Debug builds retain normal debug signing for local development. Production APKs cannot upgrade older debug-signed installations without a certificate conflict. Confirm actual publicly distributed identities and Play App Signing ownership before shipping.

### iOS

StoreKit supplies the account storefront. Only a fresh, signed observation matching that storefront, bundle ID and approved marketing version can produce an offer. Automatic prompts also require `broadlyAvailable=true`. The user opens the configured App Store listing; Shifter never downloads iOS executable code.

The tunnel bridge now selects only Shifter's provider profile and waits for confirmed disconnection. Recovery does not rewrite another VPN profile.

## Publishing the CDN JSON

`tool/update/release.py` uses Python's standard library and OpenSSL 3. Set `SHIFTER_OPENSSL` if the system executable is LibreSSL or an older OpenSSL. Keep the production private key outside the repository and CDN, with file mode `0600` on Unix.

Start with `tool/update/feed.example.json`; replace its placeholder signing identity and release details. Use a new immutable path for every artifact. The public trust-root file is a simple key-ID-to-Base64-public-key map matching the application's embedded keys.

```sh
python3 tool/update/release.py publish \
  --template /private/release/feed.json \
  --key /private/signing/update-ed25519.pem \
  --key-id production-2026 \
  --trusted-keys /private/release/public-keys.json \
  --sequence 1 \
  --artifact android-0.2.0-2=/absolute/path/to/signed.apk \
  --output /non-synced/cdn-staging \
  --scratch "$HOME/Library/Caches/shifter-vpn/build/publisher"
```

The command verifies the selected signing key against the production public-key map, computes artifact lengths and SHA-256 hashes, rejects changes to an existing immutable URL, and writes the signed feed atomically **after** staging artifacts. It uses an exclusive publication reservation to reject concurrent writers.

The output is a **local CDN staging mirror**, not an upload. Once production infrastructure is configured, the deployment job must upload immutable artifacts first and each signed `stable.json` last. Do not upload private keys, templates or scratch files. CDN credentials and uploading were not supplied or exercised by this implementation.

Each envelope contains `keyId`, `payloadBase64`, and `signatureBase64`. The app verifies Ed25519 over the exact decoded payload bytes before interpreting JSON. It rejects duplicate fields, unknown identities/schemas, unsafe paths, redirects, oversized metadata, expiry, lower sequences and conflicting payloads at the same sequence. Artifacts require exact length and SHA-256 verification.

Refresh and re-sign every 12 hours with a strictly greater sequence, even without a new binary. Metadata is valid for at most 48 hours. For refresh, omit `--artifact`; the tool uses immutable artifacts already present in the staging mirror. A failed refresh disables update actions when metadata expires, not normal app use.

Withdraw a release by setting `enabled=false` and republishing with a higher sequence. Change rollout from 5 to 25 to 100 in the template and republish explicitly. Manual checks bypass Shifter's own rollout percentage, but not native store eligibility. Recover faulty binaries with a higher-version release.

Before rotating the metadata signing key, ship a release containing both public keys, qualify adoption, then switch the publication key. A feed cannot add its own trust root.

### iOS availability observations

Maintain an explicit ISO alpha-3 StoreKit → alpha-2 Apple lookup mapping, for example `{"USA":"us","GBR":"gb"}`. Do not infer the storefront from device language or IP address.

```sh
python3 tool/update/release.py observe-ios \
  --product-id YOUR_NUMERIC_APP_ID \
  --application-id YOUR_EXISTING_BUNDLE_ID \
  --storefronts /private/release/storefronts.json \
  --output /non-synced/cdn-staging-observations.json
```

Run observation collection every 30 minutes; the command throttles requests below ten per minute. Include the result with `publish --observations <path>` and a new sequence. The client suppresses offers for observations older than 60 minutes. The iOS release's `store` object must contain `configuredProductId`, `broadlyAvailable`, and the generated `observations` list. Signed observations describe public availability; they do not guarantee installation eligibility for every account.

These jobs are release-infrastructure requirements. No recurring job, CDN deployment or store publication was created on the user's behalf.

## Qualification and outstanding release gates

Local tests cover metadata authentication, replay/conflict rejection, safe paths, file tampering, version checks, coordinator concurrency, prompt timing, withdrawal, disconnect failures and responsive modal navigation. Native compilation is recorded separately in the task's evidence report.

Before enabling production updates, supply and qualify:

1. The CDN origin, metadata trust roots and private signing-key custody.
2. Existing public application IDs/signing continuity and store enrollment.
3. The App Store ID and supported storefront mapping.
4. Packaged, signed A → B → C upgrades on each supported OS/architecture, including data preservation, disk exhaustion, permissions, cancellation, interruption and withdrawn releases.
5. Real Google Play account/rollout tests and Android APK installation/permission tests.
6. The Linux no-elevation gate, Windows runtime/signing checks and macOS notarization/authentication tests.

Local macOS/Android compilation and an iOS simulator build do not establish Windows support, real-device behavior or successful production upgrades.

## References

- [Pinned Velopack Rust API](https://docs.rs/velopack/1.2.161/velopack/)
- [Velopack macOS packaging](https://docs.velopack.io/packaging/operating-systems/macos)
- [Velopack Windows packaging](https://docs.velopack.io/packaging/operating-systems/windows)
- [Velopack Linux behavior](https://docs.velopack.io/packaging/operating-systems/linux)
- [Google Play flexible updates](https://developer.android.com/guide/playcore/in-app-updates/kotlin-java)
- [Android PackageInstaller](https://developer.android.com/reference/android/content/pm/PackageInstaller)
