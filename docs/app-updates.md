# Application updates

Windows, macOS and Linux read their required version from the same signed platform feed that lists available releases. A newer minimum blocks the app, including its connection controls, until the installed version meets it. The modal displays the installed and required versions and offers **Update now**. It stays open through Escape, Back, navigation, download and retry. The app safely disconnects an active proxy when the requirement takes effect.

Desktop releases also offer optional updates through Settings and the signed-out screen. Eligible releases can install automatically on disconnected startup when the user has enabled **Install eligible updates automatically** and the signed feed allows it. App Store and Google Play handle mobile updates. Mobile builds have no Shifter update checks or prompts. All builds ship without app analytics or installer attribution.

## Required desktop versions

To require a version, add `"minimumRequiredVersion": "1.0.1"` as a top-level field in the input for that platform and architecture's signed feed. The required version uses three numeric components. Omit the field for an optional rollout or to remove a requirement. To roll back to a lower minimum, publish it in a newly signed feed with a higher sequence.

The app checks on startup, on foreground return, and every five minutes. It keeps the most recent verified minimum when the feed is missing, offline, or invalid. New installations with no verified minimum remain usable. A valid newer feed without the field clears a previously verified minimum.

Upload the packages and verify installation on the supported systems for that feed before publishing a minimum. The feed must include an enabled release that meets the minimum. A required update is offered regardless of the staged rollout or the **Later** delay. Publish a separate signed feed for each affected architecture.

Older releases that used the shared website `app.json` require an app update before they can enforce a minimum from the signed feed.

## Build configuration

Use Flutter's `--dart-define-from-file` with the following desktop build settings.

- `SHIFTER_UPDATES_ENABLED` enables release discovery and the required-version policy. The default is `false`.
- `SHIFTER_UPDATE_ORIGIN` is the HTTPS origin for signed feeds and artifacts.
- `SHIFTER_UPDATE_PUBLIC_KEYS` is a JSON string mapping key IDs to Base64-encoded raw 32-byte Ed25519 public keys. The private keys stay outside the build.

Feeds live at `/desktop/<platform>/<architecture>/stable.json`. Use `windows`, `macos` or `linux` and `x64` or `arm64`. Each release's application ID must match the actual installed application.

## Package and install

See [Desktop release packaging](desktop-release.md) for the Azure-signed Windows installer, Developer ID macOS package, and Linux AppImage. The native bridge pins Velopack to 1.2.161. Build and embed it before signing. The Flutter native version and Velopack version must agree.

Shifter routes each app-managed request through the active local proxy or directly when disconnected. It cancels requests when that route changes. Installation holds the connection gate, restores OS proxy settings, re-fetches the signed feed, and validates the downloaded package again before invoking the native bridge. A routing restoration failure prevents handoff. Restart suppression preserves the user's Connect on launch preference.

Windows and macOS apply updates with Velopack. Linux uses the authenticated Velopack package to atomically replace the running AppImage in its writable directory and relaunch it as the current user. For protected locations, publish an AppImage at the feed's optional `manualDownloadPath` so the user can install it manually. Install and restart tests should cover both manual and automatic flows on each supported platform and architecture.

## Stage signed feeds

`tool/update/release.py` prepares a local CDN mirror. It requires OpenSSL 3. Set `SHIFTER_OPENSSL` if the system executable is incompatible. Keep the production signing key private with mode `0600` on Unix. Start with [the desktop feed example](../tool/update/feed.example.json).

```sh
python3 tool/update/release.py publish \
  --template /private/release/feed.json \
  --key /private/signing/update-ed25519.pem \
  --key-id production-2026 \
  --trusted-keys /private/release/public-keys.json \
  --sequence 1 \
  --artifact windows-0.2.0-2=/path/to/Shifter.ProxyApp-0.2.0-full.nupkg \
  --output /path/to/cdn-staging \
  --scratch /path/to/private/publisher-scratch
```

Use immutable artifact paths. Upload artifacts first and signed feeds second. Refresh each signed feed before the 48-hour expiration using a strictly greater sequence. For a refresh, omit `--artifact` to reuse the staged bytes. Withdraw a release by setting `enabled=false` in a new feed. If that release is the only one that meets the minimum, publish a compatible replacement or lower or remove the minimum in the same signed feed.

Each envelope contains `keyId`, `payloadBase64`, and `signatureBase64`. Shifter verifies the exact payload bytes and rejects duplicate fields, incompatible identities, unsafe paths, expiry, replay, conflicts and redirects. Package length and SHA-256 must match the authenticated feed. Before rotating signing keys, qualify adoption of a release with both embedded public keys.

## Mobile QA and handoff

Build locally with `flutter build apk --debug` and `flutter build ios --simulator`. Verify startup, account and tunnel behavior on the test devices. For the publishing handoff, Android's release app bundle uses `SHIFTER_ANDROID_KEYSTORE`, `SHIFTER_ANDROID_STORE_PASSWORD`, `SHIFTER_ANDROID_KEY_ALIAS` and `SHIFTER_ANDROID_KEY_PASSWORD` provided by the signing owner. The publishing team owns store signing, uploads and rollout.
