#!/usr/bin/env bash
# Installs a pinned CI toolchain into the CI pool runner's cache and exports it
# to the following steps of the job (through $GITHUB_ENV and $GITHUB_PATH).
#
#   .github/ci/setup.sh flutter|python|android|rust
#
# Everything lives under $CI_CACHE_DIR/proxy-app, never another project's
# folder. Downloads are checked against pinned SHA-256 sums, installed into a
# staging directory and kept across runs; nothing needs root. HOME moves into
# the cache too, so the pub cache, the Android debug keystore and the files
# tests write under $HOME stay inside this repository's folder.
set -euo pipefail

: "${CI_CACHE_DIR:?the CI pool runner exports CI_CACHE_DIR}"
ROOT="$CI_CACHE_DIR/proxy-app"
TOOLS="$ROOT/tools"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

FLUTTER_VERSION=3.47.5
FLUTTER_SHA256=2132e990f236f8d22e7c6314b29a191a95b10d7cbcfec9b4e2e303d996652cbb
JDK_RELEASE="jdk-17.0.21+9"
JDK_FILE=OpenJDK17U-jdk_x64_linux_hotspot_17.0.21_9.tar.gz
JDK_SHA256=8b9b611d917e3dfd8419d3566b5949226f69b052fed7e109c1368add1dfe8711
ANDROID_TOOLS_BUILD=15859902 # cmdline-tools 22.0
ANDROID_TOOLS_SHA256=4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583
# Flutter 3.47.5 defaults: compileSdk 36, NDK 28.2.13676358.
ANDROID_PACKAGES=("platform-tools" "platforms;android-36" "build-tools;36.0.0" "ndk;28.2.13676358")
RUST_DEFAULT=1.99.0

env_set() { export "$1=$2"; echo "$1=$2" >> "$GITHUB_ENV"; }
path_add() { export PATH="$1:$PATH"; echo "$1" >> "$GITHUB_PATH"; }

# fetch <url> <sha256> <file>: download and verify.
fetch() {
  curl -fsSL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c --quiet -
}

# A fresh staging directory next to <dir>; install() moves it into place.
stage() { rm -rf "$1.part"; mkdir -p "$1.part"; echo "$1.part"; }
install() { rm -rf "$1"; mv "$1.part" "$1"; }

base() {
  mkdir -p "$ROOT/home" "$TOOLS"
  # rustup and its toolchains stay where the runner installed them.
  env_set RUSTUP_HOME "${RUSTUP_HOME:-$HOME/.rustup}"
  env_set HOME "$ROOT/home"
  env_set PUB_CACHE "$ROOT/pub-cache"
  env_set CARGO_HOME "$ROOT/cargo"
}

flutter_sdk() {
  local dir="$TOOLS/flutter-$FLUTTER_VERSION" tmp
  if [ ! -x "$dir/bin/flutter" ]; then
    tmp=$(stage "$dir")
    fetch "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_$FLUTTER_VERSION-stable.tar.xz" \
      "$FLUTTER_SHA256" "$tmp/flutter.tar.xz"
    tar -xJf "$tmp/flutter.tar.xz" -C "$tmp" --strip-components=1
    rm "$tmp/flutter.tar.xz"
    install "$dir"
  fi
  git config --global --get-all safe.directory | grep -qxF "$dir" ||
    git config --global --add safe.directory "$dir"
  path_add "$dir/bin"
  flutter --disable-analytics >/dev/null
  dart --disable-analytics >/dev/null
  # Toolchain check against the pin.
  local actual
  actual=$(flutter --version --machine | jq -r .frameworkVersion)
  [ "$actual" = "$FLUTTER_VERSION" ] || { echo "Flutter $actual, pinned $FLUTTER_VERSION" >&2; exit 1; }
  flutter --version
}

python_tools() {
  local dir
  dir="$TOOLS/python-$(sha256sum "$REPO/.github/ci/requirements.txt" | cut -c1-12)"
  # A virtual environment cannot move, so it is built in place and marked complete.
  if [ ! -f "$dir/.complete" ]; then
    rm -rf "$dir"
    python3 -m venv "$dir"
    "$dir/bin/pip" install --quiet --disable-pip-version-check --require-hashes --only-binary :all: \
      -r "$REPO/.github/ci/requirements.txt"
    touch "$dir/.complete"
  fi
  path_add "$dir/bin"
}

android_sdk() {
  local jdk="$TOOLS/$JDK_RELEASE" sdk="$TOOLS/android-sdk" tmp
  if [ ! -x "$jdk/bin/java" ]; then
    tmp=$(stage "$jdk")
    fetch "https://github.com/adoptium/temurin17-binaries/releases/download/${JDK_RELEASE/+/%2B}/$JDK_FILE" \
      "$JDK_SHA256" "$tmp/jdk.tar.gz"
    tar -xzf "$tmp/jdk.tar.gz" -C "$tmp" --strip-components=1
    rm "$tmp/jdk.tar.gz"
    install "$jdk"
  fi
  env_set JAVA_HOME "$jdk"
  path_add "$jdk/bin"
  local tools="$sdk/cmdline-tools/$ANDROID_TOOLS_BUILD"
  if [ ! -x "$tools/bin/sdkmanager" ]; then
    tmp=$(stage "$tools")
    fetch "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_TOOLS_BUILD}_latest.zip" \
      "$ANDROID_TOOLS_SHA256" "$tmp/tools.zip"
    unzip -q "$tmp/tools.zip" -d "$tmp"
    mv "$tmp/cmdline-tools"/* "$tmp/" && rmdir "$tmp/cmdline-tools" && rm "$tmp/tools.zip"
    install "$tools"
  fi
  env_set ANDROID_HOME "$sdk"
  env_set ANDROID_SDK_ROOT "$sdk"
  # sdkmanager verifies each package against the checksum in Google's repository index.
  local stamp
  stamp="$sdk/.packages-$(printf '%s\n' "${ANDROID_PACKAGES[@]}" | sha256sum | cut -c1-12)"
  if [ ! -f "$stamp" ]; then
    { yes || true; } | "$tools/bin/sdkmanager" --sdk_root="$sdk" --licenses >/dev/null
    "$tools/bin/sdkmanager" --sdk_root="$sdk" "${ANDROID_PACKAGES[@]}" >/dev/null
    touch "$stamp"
  fi
  # Overrides the project's 8 GB Gradle heap: ci-4cpu runners have 8 GB in total.
  env_set GRADLE_USER_HOME "$ROOT/gradle"
  mkdir -p "$ROOT/gradle"
  printf '%s\n' 'org.gradle.jvmargs=-Xmx3g -XX:MaxMetaspaceSize=1g' 'org.gradle.daemon=false' \
    'kotlin.compiler.execution.strategy=in-process' > "$ROOT/gradle/gradle.properties"
}

rust_toolchain() {
  env_set CARGO_TARGET_DIR "$ROOT/target/updater"
  env_set CARGO_PROFILE_DEV_DEBUG line-tables-only
  if [ -f "$REPO/native/updater/rust-toolchain.toml" ]; then
    (cd "$REPO/native/updater" && { rustup show active-toolchain || rustup toolchain install; })
  else
    rustup toolchain install "$RUST_DEFAULT" --profile minimal -c rustfmt -c clippy
    env_set RUSTUP_TOOLCHAIN "$RUST_DEFAULT"
  fi
}

base
case "${1:?usage: setup.sh flutter|python|android|rust}" in
  flutter) flutter_sdk ;;
  python) python_tools ;;
  android) android_sdk ;;
  rust) rust_toolchain ;;
  *) echo "unknown tool: $1" >&2; exit 2 ;;
esac
