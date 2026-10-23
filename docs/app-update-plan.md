# Shifter application updates: implementation and release plan

## Summary

Implement **one update experience** with a permanent **Settings → App updates** section and an app-wide update modal. Use:

| Distribution | Update mechanism |
|---|---|
| Windows, macOS, Linux | Velopack |
| Android installed through Google Play | Google Play’s native flexible update flow |
| Android installed directly from an APK | Verified APK download, followed by Android’s system installer |
| iOS | Confirm store availability and open the App Store |

The shared code will handle update discovery, release authentication, scheduling, presentation, download policy, and recovery. Platform adapters will handle installation and store-specific behavior.

**Approved by the user on 2026-10-14 with “Implement it.” Recovered from the interrupted implementation thread.**

## 1. Findings that affect implementation

Research and repository inspection identified these requirements:

- Settings currently displays a hardcoded application version. It must use the actual installed version and build.
- No existing updater or production release pipeline was found.
- Android release builds currently use the **debug signing configuration**. Production APK upgrades require a stable production signing identity.
- Android has no Play/direct distribution flavors. These must be separated so the Play build cannot invoke the direct APK updater.
- Desktop disconnection can suppress errors while restoring proxy settings. Some restoration paths delete their saved backup despite failure. An updater must not exit under those conditions.
- Android retains a Flutter engine while its VPN service is active. Permission and installer callbacks must survive Activity recreation.
- iOS currently reports completion of a stop request before confirming that the tunnel disconnected.
- Authentication and layout changes can pop navigation routes. The update modal must live outside that route lifecycle.
- Velopack’s inspected stable implementation checks package hashes, but those checks alone do not authenticate our release publisher.

The existing application IDs, account storage, and user preferences will remain unchanged. Existing unrelated working-tree changes will be preserved.

## 2. Proposed product defaults

These choices are part of the plan being approved:

| Area | First-release behavior |
|---|---|
| Update requirement | Optional; no forced-update lockout |
| Release channel | Stable only |
| Automatic checks | After startup settles; on foreground return when the last automatic attempt was at least six hours ago |
| Manual checks | Available anytime; join an existing check rather than starting another |
| Automatic prompts | Only while disconnected and no other critical modal is open |
| Prompt frequency | At most once per rolling 24 hours |
| “Later” | Suppress unsolicited update prompts for seven days; Settings remains actionable |
| Downloads | Require explicit user action |
| Installation/restart | Require explicit user action |
| Reconnection afterward | No automatic reconnect |
| Package format | Full packages; no delta updates in v1 |
| Telemetry | No new remote telemetry; bounded, redacted local diagnostics |
| Channel migration | No Play↔APK or stable↔beta migration interface |

An update-check failure must never block normal application use or be displayed as “You are up to date.”

## 3. Settings and update modal

### Settings → App updates

Show:

- Installed version and build, obtained from native package information.
- Update status and last successful check.
- **Check for updates**.
- Available version, download size where known, and plain-text release notes.
- The action appropriate to the installation channel.
- Recoverable errors with useful next steps.

Also add **About / App updates** access from the signed-out interface. Users must be able to update when authentication or subscription access is unavailable.

### Modal behavior

Use a shared adaptive dialog with platform-specific actions:

| State | Desktop | Direct APK | Google Play | iOS |
|---|---|---|---|---|
| Available | Download update | Download update | Update | Open App Store |
| Downloading | Progress; cancel | Progress; cancel | Native download status where available | No simulated progress |
| Ready | Restart and install | Install update | Restart to finish | Store controls installation |
| Connected at installation | Disconnect and restart | Disconnect and install | Disconnect and restart | Disconnect and open App Store |
| Failure/cancellation | Explain and retry | Explain and retry | Retry or open Play | Retry store handoff |

Closing the modal does not discard a completed download. On desktop, downloads may continue with the modal closed. Direct APK downloads continue while the app remains foregrounded; suspension cancels an incomplete transfer, which restarts from zero on explicit retry.

Do not show a cancellation control for a native store operation unless its API actually supports cancellation.

The presentation layer will sit above the application Navigator in `MaterialApp.builder`. Account changes, resizing, and navigation must not destroy the update operation.

Include keyboard focus, Escape/back handling, focus restoration, screen-reader labels, large-text layouts, and meaningful progress announcements.

## 4. Shared application architecture

Add these modules under `lib/update/`:

- `update_models.dart`: identities, offers, states, progress, capabilities, errors.
- `update_coordinator.dart`: scheduling, policy, concurrency, lifecycle reconciliation.
- `update_repository.dart`: metadata retrieval, signature validation, release selection.
- `update_store.dart`: account-independent persisted update state.
- `adapters/desktop_velopack.dart`.
- `adapters/android_play.dart`.
- `adapters/android_direct.dart`.
- `adapters/ios_app_store.dart`.
- An unsupported/development adapter.

Add the presentation components under `lib/ui/update/`, with Settings and signed-out entry points.

### Interfaces

The platform interface will expose:

- `getInstalledIdentity()`
- `getCapabilities()`
- `checkEligibility(release)`
- `download(release)`
- `cancelDownload()`
- `prepareInstall(release)`
- `install(preparedArtifact)`
- `openStore()`
- `reconcilePendingOperation()`

`InstalledIdentity` includes application ID, platform, architecture, compiled distribution, marketing version, native build, and OS version.

Capabilities explicitly identify whether downloading, cancellation, restart, store handoff, or installation is supported. UI code must not infer capabilities from platform name alone.

Use typed native channels, with work performed off the UI thread. Native events carry an operation ID so stale callbacks cannot change a newer operation.

### State and persistence

Represent these states explicitly:

`idle → checking → current / available / unavailable / error`

For downloadable updates:

`available → downloading → verifying → ready → preparingInstall → awaitingSystemConsent / handingOff`

Persist:

- Last automatic attempt and successful check.
- Prompt suppression.
- Local rollout cohort.
- Highest accepted metadata sequence and payload digest.
- Selected release and authenticated envelope.
- Completed staged artifact.
- Pending installation target and Android session ID.

Store this separately from account data. Signing out must not erase update state or interrupt installation preparation.

Only one check, download, or installation transaction may run at a time. Add a desktop process lock to prevent two application instances from installing concurrently.

## 5. Release identity and authenticated metadata

### Version rules

Use one generated release identity across packaging and UI:

- **Desktop:** Velopack package version is an increasing stable semantic version. Every desktop release, including a rebuild intended for distribution, receives a new package version.
- **Android:** compare numeric `versionCode`; production builds increase monotonically across distribution builds.
- **iOS:** compare the public marketing version against the App Store version. Do not compare it with `CFBundleVersion`.

The installed native identity is the authority for whether an installation succeeded.

### Signed release envelope

Use a company-controlled HTTPS origin with immutable artifacts and signed metadata. No new application backend is required.

The envelope contains:

```text
keyId
payloadBase64
signatureBase64
```

Verify an Ed25519 signature over the exact decoded payload bytes before interpreting the payload.

The payload contains:

```text
schemaVersion, environment, feedSequence, generatedAt, expiresAt
distribution, channel, platform, architecture
releases[]:
  releaseId, applicationId, displayVersion, nativeVersion/build
  minimumOs, notes, enabled, rolloutPercentage
  artifact: relativePath, byteLength, sha256, format, expectedSigner
  store: configuredProductId, approvedVersion, broadlyAvailable
```

Implementation rules:

- Embed approved public keys and HTTPS origins in production builds.
- Bound metadata to 256 KiB and release notes to 8 KiB.
- Reject unknown schemas, duplicate fields, invalid versions, unsafe paths, unexpected origins, and mismatched application/distribution identities.
- Validate redirect destinations; never forward to arbitrary artifact hosts.
- Reject lower feed sequences and conflicting payloads at the same sequence.
- Reject package downgrades independently of metadata sequence.
- Verify exact artifact length and SHA-256.
- Retain high-water marks independently of sign-in.

Refresh release metadata every 12 hours, with a maximum validity of 48 hours. Expiration disables update actions, not application use. This limits the useful lifetime of replayed metadata while avoiding a permanent trust decision based on a cached feed.

Before installation, require an online revalidation of the signed release and confirm that it remains enabled. If unavailable, retain a verified package for retry rather than installing without that check. Static signed metadata still has a bounded replay window; it does not provide instantaneous revocation against a hostile delivery server.

Key rotation will ship overlapping trusted public keys in an application release before changing the publication signer. A feed cannot authorize its own new trust root.

## 6. Desktop implementation with Velopack

Use **Velopack 1.2.161 as the initial pinned qualification baseline**, keeping packaging tooling and runtime components aligned. Re-review behavior before adopting another version.

### Native integration

Add a small shared Rust static library exposing a narrow C interface. This allows use of Velopack’s public locator and source APIs without duplicating substantial updater logic in three runners.

Bootstrap before Flutter starts:

- Windows: native runner entry point.
- Linux: native runner entry point.
- macOS: explicit native entry point before application startup.

The bridge exposes bootstrap, capabilities, prepared-package validation, installation handoff, and pending-operation reconciliation.

### Authentication boundary

The pinned source shows that a cached final package can bypass download-time checksum verification and that Windows can extract updater code during package preparation. Therefore, verifying only after Velopack downloads a package is insufficient for the intended trust boundary. [Pinned package-processing implementation](https://github.com/velopack/velopack/blob/1.2.161/src/lib-rust/src/manager.rs)

The flow will be:

1. Authenticate Shifter’s release metadata.
2. Download the full package into private staging.
3. Verify its length and hash before giving it to Velopack.
4. Generate a local feed containing only that approved package.
5. Use Velopack’s local file source.
6. Check the actual destination cache before reuse and after staging.
7. Recheck the package immediately before installation.
8. Disable startup auto-application of pending updates.

Validate or quarantine pending cache entries before bootstrap can inspect them. Do not use “a pending package exists” as sufficient authorization. [Velopack bootstrap behavior](https://github.com/velopack/velopack/blob/1.2.161/src/lib-rust/src/app.rs)

This protects the release-delivery boundary; it does not claim protection against arbitrary malware already executing as the same user.

### Platform-specific packaging

- **Windows:** per-user installation; trusted Authenticode signing and timestamps for owned executables, updater, and installer.
- **macOS:** existing bundle identity and entitlements; Developer ID signing, notarization, and applicable stapling through the Velopack packaging flow. Handle authentication cancellation and read-only/translocated locations. [macOS support](https://docs.velopack.io/packaging/operating-systems/macos)
- **Linux:** writable per-user AppImage installation, with user-level launcher integration. Default location: `~/Applications/Shifter.AppImage`. Use private, same-filesystem staging; do not use a shared temporary package directory.

Linux automatic updates must not invoke privilege escalation. Root-owned, system-directory, or otherwise unsupported installations receive manual update instructions. If the pinned updater cannot reliably enforce the no-elevation requirement under failure tests, Linux release remains blocked pending a reviewed upstream solution. [Pinned Linux replacement implementation](https://github.com/velopack/velopack/blob/1.2.161/src/bins/src/commands/apply_linux_impl.rs)

## 7. Android Play and direct APK updates

### Separate distribution builds

Introduce `play` and `direct` Gradle flavors.

The compiled flavor determines the update provider. The presence of Google Play, or installer-source metadata alone, must not switch an APK installation to another channel.

The Play artifact must exclude:

- Direct APK download/installation implementation.
- `REQUEST_INSTALL_PACKAGES`.
- Any fallback that bypasses Play updates.

Verify the merged manifest and built artifact. Google restricts this permission and its use to bypass Play’s update mechanism. [Google Play permission policy](https://support.google.com/googleplay/android-developer/answer/12085295?hl=en)

### Google Play

Use the native **flexible in-app update** flow:

- `AppUpdateInfo` determines actual account/device eligibility.
- Start only when an update is available and flexible updates are allowed.
- Obtain fresh update information for each retry.
- Track native installation state and reconcile on foreground.
- Call completion only after the user confirms and connection shutdown succeeds.

If unavailable, offer **Open Google Play** without asserting that a particular version is installable. Never fall back to the direct APK provider. [Google’s implementation guidance](https://developer.android.com/guide/playcore/in-app-updates/kotlin-java)

The native bridge must accommodate the existing cached Flutter engine and `FlutterActivity`. Attach and detach the current Activity, preserve the VPN permission callback, and use separate request identifiers.

### Direct APK

Use a signed universal APK for v1.

1. Validate the release envelope and compatibility.
2. Download to app-private staging with real progress and cancellation.
3. Verify size and hash.
4. Inspect package ID, `versionCode`, minimum SDK, ABI compatibility, and signing identity.
5. Reject mismatched or non-increasing targets before installation.
6. Request “install from this source” authorization only when needed.
7. Recheck permission after returning from system settings.
8. After user confirmation and safe disconnect, create and commit a `PackageInstaller` session.
9. Handle Android’s confirmation UI and structured installation status.
10. Reconcile the session and installed version after process death or restart.

Parsing APK signing information is a preliminary identity check; Android’s installer remains responsible for enforcing the APK’s signature and installation compatibility. [PackageInstaller API](https://developer.android.com/reference/android/content/pm/PackageInstaller)

Production releases must replace debug signing with a fail-closed production configuration. Preserve the existing package ID and direct-APK signing continuity. The Play upload key must not be confused with the actual app-signing key. [Android signing guidance](https://developer.android.com/studio/publish/app-signing)

Do not uninstall the existing app to resolve a certificate conflict. Debug-signed installations cannot silently become production-signed installations.

## 8. iOS store availability

iOS opens the configured App Store listing; it does not download executable updates.

Use StoreKit’s account storefront, not device language or IP location. Map storefront country identifiers explicitly to Apple lookup country identifiers.

To avoid every installation querying Apple independently:

- Add a publisher-side command that checks the configured app ID and supported storefronts.
- Run it every 30 minutes, throttled to at most 10 requests per minute.
- Publish signed availability observations containing bundle identity, marketing version, minimum OS, storefront, and observation time.
- Accept observations no older than 60 minutes for automatic prompts.
- Require a match between the observed store version and an approved release manifest.

Unknown storefront, stale observations, missing listings, or incompatible OS versions suppress automatic prompts. Manual Settings still offers **Open App Store** with an honest “availability could not be confirmed” status.

Store lookup is evidence of public availability, not a guarantee of installation eligibility for every account or device. [Apple lookup service](https://performance-partners.apple.com/search-api)

During phased release, require `broadlyAvailable=true` before unsolicited prompts. Manual checks may expose a verified available release. Apple permits manual updates during phased release, so prompting everybody would undermine the intended gradual rollout. [Apple phased releases](https://developer.apple.com/help/app-store-connect/update-your-app/release-a-version-update-in-phases)

## 9. Connection safety and interrupted updates

Add a serialized `prepareForUpdate()` operation.

It must:

1. Block new connection attempts and cancel pending ones.
2. Persist the intended update and recovery information.
3. Restore previous OS proxy settings **before** stopping the local proxy.
4. Confirm restoration and retain backups until confirmed.
5. Stop listeners and services.
6. On mobile, await confirmed native disconnection.
7. Revalidate the prepared artifact.
8. Only then launch or commit the updater.

If preparation fails or times out, do not launch the installer, erase restoration records, or exit. Release the operation lock and provide recovery/retry actions.

On iOS, load the existing tunnel manager by Shifter’s provider identity without rewriting unrelated profiles; then wait for disconnected status.

Velopack’s inspected helper can continue after its process-wait timeout. Cleanup must therefore finish **before** the helper is armed. [Pinned wait implementation](https://github.com/velopack/velopack/blob/1.2.161/src/bins/src/shared/util_common.rs)

App-managed update HTTP uses the active local proxy while connected and direct transport while disconnected. A proxy failure must not silently trigger direct fallback. Route changes cancel/restart the transfer under the new explicit connection state. Native store traffic remains OS-managed.

External store updates may terminate the application without this preparation flow. Startup must independently recover stale networking state and reconcile installation results.

Do not introduce destructive account-data migrations. New updater state gets its own versioned storage namespace. Confirm that upgrades preserve credentials, preferences, and selected configuration without copying secrets into update journals or backups.

## 10. Required tests and release qualification

### Automated tests

Cover:

- Version comparisons for each platform, including installed builds ahead of public releases.
- Check deduplication, prompt cooldowns, manual overrides, and clock changes.
- Invalid signatures, unknown keys, replay, conflicting sequences, expiry, wrong app/channel/architecture.
- Truncated or oversized downloads, corrupted caches, unsafe paths, symlinks, and hostile redirects.
- Authentication changes, resizing, modal dismissal, keyboard use, and accessibility.
- Network changes, cancellation, process restart, and stale installation journals.
- Proxy restoration failures and concurrent connect/install requests.

### Real installation tests

Use packaged version **A → B → C**, not only development runs.

| Scenario | Required result |
|---|---|
| Successful upgrade | New native version confirmed; user data preserved |
| Disk full or unwritable destination | Existing installation retained; actionable failure |
| User cancels permission or installation | App remains usable; no false success |
| Download or installer interrupted | Correct reconciliation and safe retry |
| Proxy restoration fails | No updater handoff or premature proxy termination |
| Wrong APK signer/package | Rejected without uninstalling |
| Play account/rollout ineligible | No misleading update offer or APK fallback |
| iOS listing/storefront unavailable | No unsolicited prompt |
| macOS authentication canceled | Existing app retained; retry available |
| Linux moved/read-only/system AppImage | Automatic install refused safely |
| Windows quarantined/locked component | Failure detected and explained |
| Release withdrawn after download | New authenticated metadata prevents normal installation |

Verify that the Play artifact contains neither the installation permission nor direct APK installer implementation. Test genuine Play updates through a supported internal testing path. [Google Play testing requirements](https://developer.android.com/guide/playcore/in-app-updates/test)

Initial qualification targets:

- Windows 11 x64.
- macOS 12+ on Intel and Apple Silicon.
- Ubuntu 22.04/24.04 GNOME x64.
- Android 10+ for Play and direct APK.
- iOS 15+.

These are proposed qualification targets, **not claims of completed support testing**. Other architectures and Linux desktops remain outside the initial release matrix.

## 11. Implementation sequence and operational release process

1. **Release identity and security foundation**
   - Confirm IDs, signing configurations, native version mapping, metadata schema, and trust roots.
   - Prove authenticated Velopack handoff and private cache behavior before broader integration.

2. **Shared coordinator and UI**
   - Implement Settings, signed-out access, modal, state machine, storage, and fake adapters.
   - Complete deterministic lifecycle and accessibility tests.

3. **Safe connection preparation**
   - Fix restoration error reporting and backup retention.
   - Add mobile disconnection acknowledgement and interruption recovery.

4. **Platform adapters**
   - Integrate desktop bootstrap and staging.
   - Add Android flavors, Play flow, and APK sessions.
   - Add iOS storefront and store handoff.

5. **Publishing tools**
   - Build and sign artifacts; verify signatures.
   - Publish immutable artifacts first and metadata last.
   - Add metadata refresh, storefront observation, release withdrawal, and key-rotation commands.
   - Keep store publication and infrastructure deployment gated on verified production configuration.

6. **Qualification and rollout**
   - Complete the signed upgrade matrix.
   - Promote company-managed releases through 5% → 25% → 100% by explicit operator action.
   - Compute rollout cohorts locally using a persisted random identifier; do not transmit it.
   - Manual checks may bypass our own percentage rollout, but never store eligibility.
   - Revert faulty behavior through a higher-version release, not an automatic binary downgrade.

Production inputs still required before shipping are the update-host origin, App Store numeric ID, supported storefront list, actual signing identities/enrollment, and any existing publicly shipped package identities. Implementation must fail safely when these are absent rather than inventing values.

All builds and testing remain local unless remote execution is separately authorized for this project. Follow the required disk preflight, external cache placement, ownership, and cleanup rules. Missing hardware or device evidence blocks release of that target.

Remove abandoned partial downloads and inactive staged packages within 24 hours; preserve files actively consumed by an installer until reconciliation confirms they are no longer needed.

After approval, save this plan and the eventual verification results as Markdown. Implementation begins only after approval.
