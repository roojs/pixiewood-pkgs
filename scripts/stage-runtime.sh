#!/usr/bin/env bash
# Copy sysroot libraries and GSettings schemas into a Pixiewood install root.
#
# Pixiewood's meson install only packages the application. Shared libraries
# that came from pkg-config are not copied unless this step (or the
# --pixie patch) puts them in .pixiewood/root before Gradle runs.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 SYSROOT PIXIEWOOD_ROOT" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sysroot-common.sh
source "$ROOT/sysroot-common.sh"

sysroot="$(cd "$1" && pwd)"
mkdir -p "$2"
root="$(cd "$2" && pwd)"
manifest="$sysroot/share/pixiewood/MANIFEST.json"

if [ ! -f "$manifest" ]; then
  echo "Sysroot manifest missing: $manifest" >&2
  echo "Extract a pixiewood-pkgs tarball and run scripts/activate-sysroot.sh." >&2
  exit 1
fi

abi="$(sysroot_json_get abi "$manifest")"
src_lib="$sysroot/lib/$abi"
if [ ! -d "$src_lib" ]; then
  echo "Sysroot library directory missing: $src_lib" >&2
  exit 1
fi

dest_lib="$root/lib/$abi"
mkdir -p "$dest_lib"
cp -a "$src_lib/." "$dest_lib/"

src_schemas="$sysroot/share/glib-2.0/schemas"
if [ -d "$src_schemas" ]; then
  dest_schemas="$root/share/glib-2.0/schemas"
  mkdir -p "$dest_schemas"
  cp -a "$src_schemas/." "$dest_schemas/"
fi

echo "Staged $abi runtime into $root"
