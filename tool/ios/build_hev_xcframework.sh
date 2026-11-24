#!/bin/bash
# Build ios/Frameworks/HevSocks5Tunnel.xcframework (iPhone + simulator) from a
# pinned hev-socks5-tunnel (MIT; bundles lwIP BSD, libyaml MIT,
# hev-task-system MIT). The packet tunnel uses it to send all device TCP and
# UDP through the Shifter gateway over SOCKS5.
#
#   tool/ios/build_hev_xcframework.sh     # needs Xcode with the iOS SDK
#
# The built framework is committed, so normal builds don't run this.
set -euo pipefail

HEV_REPO="https://github.com/heiher/hev-socks5-tunnel.git"
HEV_COMMIT="fc3f90040b8d4b537341c96538669a9b2e35d514"
MIN_IOS="15.0"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/ios/Frameworks/HevSocks5Tunnel.xcframework"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone --quiet "$HEV_REPO" "$WORK/hev"
cd "$WORK/hev"
git checkout --quiet "$HEV_COMMIT"
git submodule update --quiet --init --recursive

build() { # sdk arch
  make clean >/dev/null
  make PP="xcrun --sdk $1 clang" CC="xcrun --sdk $1 clang" \
       CFLAGS="-arch $2 -m$1-version-min=$MIN_IOS" \
       LFLAGS="-arch $2 -m$1-version-min=$MIN_IOS -Wl,-Bsymbolic-functions" static >/dev/null
  mkdir -p "$WORK/out/$1-$2"
  libtool -static -o "$WORK/out/$1-$2/libhev-socks5-tunnel.a" \
    bin/libhev-socks5-tunnel.a third-part/lwip/bin/liblwip.a \
    third-part/yaml/bin/libyaml.a third-part/hev-task-system/bin/libhev-task-system.a
}

build iphoneos arm64
build iphonesimulator arm64
build iphonesimulator x86_64
mkdir -p "$WORK/out/sim"
lipo -create "$WORK/out/iphonesimulator-arm64/libhev-socks5-tunnel.a" \
             "$WORK/out/iphonesimulator-x86_64/libhev-socks5-tunnel.a" \
             -output "$WORK/out/sim/libhev-socks5-tunnel.a"

mkdir -p "$WORK/include/HevSocks5Tunnel"
cp src/hev-main.h module.modulemap "$WORK/include/HevSocks5Tunnel/"
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework \
  -library "$WORK/out/iphoneos-arm64/libhev-socks5-tunnel.a" -headers "$WORK/include" \
  -library "$WORK/out/sim/libhev-socks5-tunnel.a" -headers "$WORK/include" \
  -output "$OUT" >/dev/null
cp LICENSE "$OUT/LICENSE-hev-socks5-tunnel"
cp third-part/lwip/LICENSE "$OUT/LICENSE-lwip"
# The fork's LICENSE omits the original libyaml authors; keep their notice.
{ printf 'Copyright (c) 2017-2020 Ingy d\303\266t Net\nCopyright (c) 2006-2016 Kirill Simonov\n'; cat third-part/yaml/LICENSE; } > "$OUT/LICENSE-libyaml"
cp third-part/hev-task-system/LICENSE "$OUT/LICENSE-hev-task-system"
echo "Built $OUT ($HEV_COMMIT)"
