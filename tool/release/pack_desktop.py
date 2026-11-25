#!/usr/bin/env python3
"""Build the matching updater bridge and package a Flutter macOS or Linux release."""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
VELOPACK = "1.2.161"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--build-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--vpk", default="vpk")
    parser.add_argument("--mac-application")
    parser.add_argument("--mac-installer")
    parser.add_argument("--mac-notary-profile")
    parser.add_argument("--qa", action="store_true", help="Allow local macOS test packages without notarization")
    parser.add_argument("--arch", choices=("arm64", "x64"),
                        help="macOS: package this architecture of the universal bundle (default: this Mac's)")
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version):
        parser.error("Expected a three-part release version")
    system = platform.system()
    arch = {"aarch64": "arm64", "arm64": "arm64", "x86_64": "x64"}.get(platform.machine())
    if not arch or system not in {"Darwin", "Linux"}:
        parser.error("Run on the matching macOS or Linux build host")
    if args.arch and args.arch != arch:
        # The Flutter macOS bundle is universal; only the updater bridge and the
        # Velopack runtime are per architecture, and both cross-build on a Mac.
        if system != "Darwin":
            parser.error("Cross-architecture packages are only supported on macOS")
        arch = args.arch
    args.bundle = args.bundle.resolve(strict=True)
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        parser.error("Use an empty output directory")
    version = subprocess.check_output([args.vpk, "--help"], text=True)
    if not re.search(rf"\b{re.escape(VELOPACK)}\b", version):
        parser.error(f"Use Velopack CLI {VELOPACK}")
    command = [args.vpk, "pack", "--packId", "Shifter.ProxyApp", "--packTitle", "Shifter",
               "--packVersion", args.version, "--packDir", str(args.bundle),
               "--outputDir", str(args.output.resolve()), "--channel", "stable", "--delta", "None"]
    target_arch = {"arm64": "aarch64", "x64": "x86_64"}[arch]
    if system == "Darwin":
        with (args.bundle / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        if info["CFBundleShortVersionString"] != args.version:
            parser.error("The Flutter bundle version must match the Velopack package")
        if not args.qa and not all((args.mac_application, args.mac_installer, args.mac_notary_profile)):
            parser.error("Set Developer ID Application, Developer ID Installer, and notary profile")
        command += ["--bundleId", info["CFBundleIdentifier"], "--mainExe", info["CFBundleExecutable"],
                    "--runtime", f"osx-{arch}"]
        if args.mac_application:
            command += ["--signAppIdentity", args.mac_application, "--signEntitlements",
                        str(REPO / "macos/Runner/Release.entitlements")]
        if args.mac_installer:
            command += ["--signInstallIdentity", args.mac_installer]
        if args.mac_notary_profile:
            command += ["--notaryProfile", args.mac_notary_profile]
        target = f"{target_arch}-apple-darwin"
    else:
        if not (args.bundle / "shifter_app").is_file():
            parser.error("Expected a Flutter Linux release bundle")
        command += ["--runtime", f"linux-{arch}", "--mainExe", "shifter_app",
                    "--icon", str(REPO / "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png"),
                    "--categories", "Network"]
        target = f"{target_arch}-unknown-linux-gnu"

    subprocess.run([sys.executable, str(REPO / "tool/update/build_bridge.py"),
                    "--bundle", str(args.bundle), "--build-root", str(args.build_root),
                    "--target", target], check=True)
    subprocess.run(command, check=True)
    artifact_ext = ".pkg" if system == "Darwin" else ".AppImage"
    installers = sorted(args.output.glob(f"*{artifact_ext}"))
    packages = sorted(args.output.glob("*-full.nupkg"))
    if len(installers) != 1 or len(packages) != 1:
        raise SystemExit("Expected one installer and one full Velopack package")
    if system == "Darwin" and not args.qa:
        subprocess.run(["pkgutil", "--check-signature", str(installers[0])], check=True)
        subprocess.run(["xcrun", "stapler", "validate", str(installers[0])], check=True)
    receipt = {
        "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
        "version": args.version,
        "velopack": VELOPACK,
        "runtime": f"{system.lower()}-{arch}",
        "qa": args.qa,
        "artifacts": {path.name: sha256(path) for path in installers + packages},
    }
    (args.output / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
