#!/bin/bash
# Build android/app/src/main/jniLibs/<abi>/libhev-socks5-tunnel.so from a
# pinned hev-socks5-tunnel (MIT; bundles lwIP BSD, libyaml MIT,
# hev-task-system MIT), bound to io.shifter.shifter_app.HevTunnel. The VPN
# service uses it to send all device TCP and UDP through the gateway's SOCKS5.
#
#   ANDROID_NDK_HOME=<ndk> tool/android/build_hev_jni.sh
#
# The built libraries are committed, so normal builds don't run this.
set -euo pipefail

HEV_REPO="https://github.com/heiher/hev-socks5-tunnel.git"
HEV_COMMIT="fc3f90040b8d4b537341c96538669a9b2e35d514"
ABIS="arm64-v8a armeabi-v7a x86_64"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NDK="${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to the Android NDK}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone --quiet "$HEV_REPO" "$WORK/hev"
cd "$WORK/hev"
git checkout --quiet "$HEV_COMMIT"
git submodule update --quiet --init --recursive

# Default target (also builds the unused CLI); no parallel make, which
# fails in some shells ("fcntl(): Bad file descriptor").
env -u MAKEFLAGS -u MFLAGS "$NDK/ndk-build" \
  NDK_PROJECT_PATH=. APP_BUILD_SCRIPT=Android.mk NDK_APPLICATION_MK=Application.mk \
  APP_ABI="$ABIS" APP_PLATFORM=android-24 \
  APP_CFLAGS="-O3 -DPKGNAME=io/shifter/shifter_app -DCLSNAME=HevTunnel" \
  </dev/null >/dev/null

for abi in $ABIS; do
  mkdir -p "$ROOT/android/app/src/main/jniLibs/$abi"
  cp "libs/$abi/libhev-socks5-tunnel.so" "$ROOT/android/app/src/main/jniLibs/$abi/"
done
mkdir -p "$ROOT/android/app/src/main/jniLibs/licenses"
cp LICENSE "$ROOT/android/app/src/main/jniLibs/licenses/LICENSE-hev-socks5-tunnel"
cp third-part/lwip/LICENSE "$ROOT/android/app/src/main/jniLibs/licenses/LICENSE-lwip"
# The fork's LICENSE omits the original libyaml authors; keep their notice.
{ printf 'Copyright (c) 2017-2020 Ingy d\303\266t Net\nCopyright (c) 2006-2016 Kirill Simonov\n'; cat third-part/yaml/LICENSE; } > "$ROOT/android/app/src/main/jniLibs/licenses/LICENSE-libyaml"
cp third-part/hev-task-system/LICENSE "$ROOT/android/app/src/main/jniLibs/licenses/LICENSE-hev-task-system"
echo "Built hev-socks5-tunnel $HEV_COMMIT for $ABIS"
