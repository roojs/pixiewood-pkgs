#!/usr/bin/env bash
# Check a finalized (not necessarily activated) sysroot tree.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 SYSROOT" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pixie-common.sh
source "$ROOT/pixie-common.sh"

sysroot="$(cd "$1" && pwd)"
manifest="$sysroot/share/pixiewood/MANIFEST.json"
if [ ! -f "$manifest" ]; then
  echo "missing $manifest" >&2
  exit 1
fi

abi="$(sysroot_json_get abi "$manifest")"
gtk_target="$(sysroot_json_get gtk_target "$manifest")"
version="$(sysroot_json_get version "$manifest")"
pkgconfig="$sysroot/$(sysroot_json_get pkgconfig_dir "$manifest")"
java_glue="$sysroot/$(sysroot_json_get java_glue "$manifest")/org/gtk/android"

required=(
  gtk4.pc
  glib-2.0.pc
  libadwaita-1.pc
  libsoup-3.0.pc
  gioopenssl.pc
  gee-0.8.pc
  gtksourceview-5.pc
)
missing=()
for name in "${required[@]}"; do
  if [ ! -f "$pkgconfig/$name" ]; then
    missing+=("$name")
  fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "missing pkg-config files: ${missing[*]}" >&2
  exit 1
fi
if [ ! -d "$java_glue" ] || ! find "$java_glue" -name '*.java' -type f -print -quit | grep -q .; then
  echo "GTK Android Java glue missing under $java_glue" >&2
  exit 1
fi
while IFS= read -r -d '' pc; do
  if grep -q '^prefix=/$' "$pc"; then
    echo "$pc still has prefix=/ (finalize did not rewrite it)" >&2
    exit 1
  fi
done < <(find "$pkgconfig" -name '*.pc' -type f -print0)
count="$(find "$pkgconfig" -name '*.pc' -type f | wc -l)"
echo "sysroot ok: gtk_target=$gtk_target version=$version abi=$abi pcs=$count"
