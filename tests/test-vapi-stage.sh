#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

activate_pkg() {
  local destdir=$1
  mkdir -p "$destdir/share/pixiewood"
  mkdir -p "$destdir/lib/arm64-v8a/pkgconfig"
  "$ROOT/scripts/pixie-tree.sh" pack-fragment \
    --destdir "$destdir" \
    --abi arm64-v8a \
    --tarball "$tmp/pkg.tar.xz"
  rm -rf "$tmp/sysroot"
  mkdir -p "$tmp/sysroot"
  tar -xJf "$tmp/pkg.tar.xz" -C "$tmp/sysroot"
  printf '{\n  "format": 1,\n  "abi": "arm64-v8a",\n  "prefix_token": "@PIXIEWOOD_SYSROOT@",\n  "activated_prefix": null\n}\n' \
    > "$tmp/sysroot/share/pixiewood/MANIFEST.json"
  "$ROOT/scripts/pixie-tree.sh" activate "$tmp/sysroot"
}

destdir="$tmp/destdir"
mkdir -p "$destdir"
"$ROOT/scripts/vapi-stage.sh" --package libadwaita --destdir "$destdir"
[ -f "$destdir/share/vala/vapi/libadwaita-1.vapi" ]
cmp -s "$ROOT/packages/libadwaita/vapi/libadwaita-1.vapi" "$destdir/share/vala/vapi/libadwaita-1.vapi"

activate_pkg "$destdir"
if ! grep -q "valac = \['valac', '--vapidir'" "$tmp/sysroot/share/pixiewood/pixie.cross"; then
  echo "pixie.cross should expose the Vala vapidir" >&2
  exit 1
fi

echo "vapi stage: ok"