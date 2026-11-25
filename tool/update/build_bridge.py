#!/usr/bin/env python3
"""Build/embed the native bridge in an already-built Flutter desktop bundle.
Run BEFORE application signing and Velopack packaging. Requires an explicit
non-synced cache root, shared with other variants for this checkout.
"""
import argparse
import os
from pathlib import Path
import platform
import shutil
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--bundle', required=True)
p.add_argument('--build-root', required=True)
p.add_argument('--target', help='Rust target matching the Flutter bundle architecture')
a = p.parse_args()
root = Path(a.build_root).resolve()
bundle = Path(a.bundle).resolve(strict=True)
for forbidden in ('Desktop', 'Documents', 'Mobile Documents', 'CloudStorage', 'Dropbox', 'OneDrive'):
    if forbidden in root.parts:
        p.error('Build root must be a non-synced cache')
root.mkdir(parents=True, exist_ok=True)
disk = shutil.disk_usage(root)
# The Rust build needs well under 1 GiB; keep 5 GiB for it and at least
# 10 GiB free afterwards, so a release build never fills the disk.
if disk.free - 5 * 1024**3 < 10 * 1024**3:
    p.error('Need 15 GiB free: 5 GiB for the build and 10 GiB left over')
env = dict(os.environ, CARGO_TARGET_DIR=str(root / 'rust'))
repo = Path(__file__).resolve().parents[2]
command = ['cargo', 'build', '--locked', '--release', '--manifest-path', str(repo / 'native/updater/Cargo.toml')]
if a.target:
    command += ['--target', a.target]
subprocess.run(command, env=env, check=True)
compiled = root / 'rust'
if a.target:
    compiled /= a.target
compiled /= 'release'
system = platform.system()
name = {'Darwin': 'libshifter_updater.dylib', 'Windows': 'shifter_updater.dll', 'Linux': 'libshifter_updater.so'}[system]
destination = bundle / ('Contents/Frameworks' if system == 'Darwin' else 'lib' if system == 'Linux' else '')
destination.mkdir(parents=True, exist_ok=True)
shutil.copy2(compiled / name, destination / name)
print('Embedded updater bridge; sign the entire bundle before packaging.')
