# Bunny release uploads through Gate

Use the existing Shifter Bunny Gate API for Windows and Linux uploads. The
Storage password and Bunny account key remain on the gateway. Do not retrieve
those credentials or use browser uploads when this API is available.

## Configured operator workstation

- Gateway: `https://bunny.gate.mime.io`.
- Storage zone: `1478008`, `shifter-storage`.
- Client: `/Users/cristian/.local/bin/shifter-bunny`.
- Private config: `/Users/cristian/.config/shifter-release/bunny-gate.json`
  (0600, containing the scoped token; never print or commit it).
- Token ID: `shifter-desktop-releases-mac`, expiry 2027-11-26 UTC.
- Source IP: explicit current workstation public IPv4 `/32`, recorded privately
  in the config. An ISP/VPN address change requires updating that token's ACL.
- Access: GET/PUT under `apps/windows/` and `apps/linux/`, maximum 2 GiB per file.
  macOS, `desktop/`, other storage zones, listing, deletion and CDN administration
  are denied. Existing fleet/DB-IP credentials are unrelated and unchanged.

Client source and gateway behavior are maintained in
[Bunny Gate PR 22](https://github.com/ccycv/bunny-gate/pull/22) and
[the gateway Storage runbook](https://github.com/ccycv/bunny-gate/blob/main/docs/storage.md).
The installed client uses Python 3's standard library and streams data without
creating temporary package copies. It sends a SHA-256 header on upload and then
re-downloads the object through Gate to compare checksum and length.

## Upload a release

Use the actual version and build number. Preserve original `.nupkg` names.
Examples for a future release (substitute real local files and version):

```sh
~/.local/bin/shifter-bunny put /path/Shifter-Setup-win-x64.exe apps/windows/x64/1.0.2-4/shifter.exe
~/.local/bin/shifter-bunny put /path/Shifter.ProxyApp-1.0.2-stable-full.nupkg apps/windows/x64/1.0.2-4/Shifter.ProxyApp-1.0.2-stable-full.nupkg
~/.local/bin/shifter-bunny put /path/build-receipt.json apps/windows/x64/1.0.2-4/build-receipt.json

~/.local/bin/shifter-bunny put /path/shifter.AppImage apps/linux/x64/1.0.2-4/shifter.AppImage
~/.local/bin/shifter-bunny put /path/Shifter.ProxyApp-1.0.2-stable-full.nupkg apps/linux/x64/1.0.2-4/Shifter.ProxyApp-1.0.2-stable-full.nupkg
~/.local/bin/shifter-bunny put /path/build-receipt.json apps/linux/x64/1.0.2-4/build-receipt.json
```

`verify` in place of `put` compares an existing Storage object without writing.
An uncertain upload is not retried automatically. Check with `verify` before
retrying. Do not replace immutable published version objects with different bytes.

Uploads do not advance public download redirects or publish signed update feeds.
At setup, the canonical Windows/Linux URLs redirect to versioned `1.0.1-3`
installers. Uploading a new root-level file alone does not change those redirects.
Verify public CDN bytes independently, then use the separately authorized CDN
administration/signing workflow to promote a release. Do not manually alter a
signed `stable.json`, and do not modify Robert's macOS files/rules.

## Credential maintenance

Use the existing Bunny Gate CLI over verified SSH to inspect or update the exact
token, preserving its hash and unrelated grants. Follow the gateway deployment
runbook for access. Never overwrite the complete policy file or broaden the
allowlist to all IPs to work around a changed workstation address.

## Verified setup, 2026-11-26

Gateway change merged and deployed at `f666cee1d2cd6657cd8a5da9dcdf886af639806f`.
Gateway tests: 271 passed; client tests: 5 passed; TypeScript checks/build passed.
Existing policy, encrypted account connection, runtime environment and ingress
configuration matched their pre-deployment hashes before adding the new token.
Both gateway and the separate DigitalOcean proxy were healthy afterward.

Live GET/PUT verification re-uploaded the existing Linux and Windows build receipts
with identical bytes, then downloaded and compared their SHA-256 and length.
Both versioned installers and both `.nupkg` packages were downloaded through Gate
and matched the local release hashes and byte counts.
Requests for macOS, desktop feeds, another zone, a neighboring prefix and CDN
administration returned 403. The public release version was not changed.
