#!/usr/bin/env bash
# The pixie libraries patch applies to the Pixiewood revision in android-distro.conf.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REV="$(sed -n 's/^pixiewood=//p' "$ROOT/android-distro.conf" | head -n1 | tr -d '[:space:]')"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL \
  "https://raw.githubusercontent.com/sp1ritCS/gtk-android-builder/${REV}/pixiewood" \
  -o "$tmp/pixiewood"
patch -p1 -d "$tmp" < "$ROOT/integration/0001-pixie-libraries.patch"
grep -q 'pixie=s' "$tmp/pixiewood"
grep -q 'provided by pixie libraries' "$tmp/pixiewood"
grep -q 'gtk-android-java' "$tmp/pixiewood"
grep -q 'Failed to stage pixie libraries' "$tmp/pixiewood"
if grep -q sysroot "$ROOT/integration/0001-pixie-libraries.patch"; then
  echo "patch still says sysroot" >&2
  exit 1
fi
echo "pixiewood patch applies on $REV"
