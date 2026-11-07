#!/usr/bin/env bash
# Install the Android command-line SDK and NDK used to build the sysroot.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ROOT/.cache/android-sdk}"
CMDLINE_TOOLS_URL="${CMDLINE_TOOLS_URL:-https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip}"
ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION:-28.2.13676358}"
ANDROID_BUILD_TOOLS_VERSION="${ANDROID_BUILD_TOOLS_VERSION:-36.0.0}"

need_tool() {
  if command -v "$1" >/dev/null 2>&1; then
    return
  fi
  echo "Missing required tool: $1" >&2
  exit 1
}

need_tool curl
need_tool unzip

mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools"

if [ ! -x "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" ]; then
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  curl -fsSL "$CMDLINE_TOOLS_URL" -o "$tmpdir/commandlinetools.zip"
  unzip -q "$tmpdir/commandlinetools.zip" -d "$tmpdir"
  rm -rf "$ANDROID_SDK_ROOT/cmdline-tools/latest"
  mv "$tmpdir/cmdline-tools" "$ANDROID_SDK_ROOT/cmdline-tools/latest"
  trap - EXIT
  rm -rf "$tmpdir"
fi

export ANDROID_HOME="$ANDROID_SDK_ROOT"
export ANDROID_SDK_ROOT

set +o pipefail
yes | "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null
set -o pipefail
"$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" \
  "platform-tools" \
  "platforms;android-36" \
  "build-tools;$ANDROID_BUILD_TOOLS_VERSION" \
  "ndk;$ANDROID_NDK_VERSION"

echo "ANDROID_SDK_ROOT=$ANDROID_SDK_ROOT"
echo "ANDROID_NDK_HOME=$ANDROID_SDK_ROOT/ndk/$ANDROID_NDK_VERSION"
