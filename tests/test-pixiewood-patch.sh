#!/usr/bin/env bash
# The sysroot patch applies to the Pixiewood revision OLLMchat pins.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REV="$(tr -d '[:space:]' < "$ROOT/stack/cross/PIXIEWOOD_REVISION")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL \
  "https://raw.githubusercontent.com/sp1ritCS/gtk-android-builder/${REV}/pixiewood" \
  -o "$tmp/pixiewood"
patch -p1 -d "$tmp" < "$ROOT/integration/0001-sysroot-prebuilt-dependencies.patch"
grep -q 'sysroot=s' "$tmp/pixiewood"
grep -q 'provided by sysroot' "$tmp/pixiewood"
grep -q 'gtk-android-java' "$tmp/pixiewood"
grep -q 'Failed to stage sysroot libraries' "$tmp/pixiewood"
echo "pixiewood patch applies on $REV"
