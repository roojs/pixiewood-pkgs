#!/usr/bin/env bash
# Build the libxml2 wrap as the Android cross file leaves it (output enabled)
# and run the output-buffer overflow tests.
#
# These tests fail while packages/libxml2/libxml2.wrap points at 2.15.3.
# libxml2 2.15.4 rejects an output buffer whose used size is at least
# INT_MAX before calling the write callback, and that is what makes them pass.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAP="$ROOT/packages/libxml2/libxml2.wrap"
CACHE="${TMPDIR:-/tmp}/pixiewood-libxml2-overflow"

field() {
  local key=$1
  awk -F ' = ' -v key="$key" '$1 == key { print $2; exit }' "$WRAP"
}

url="$(field source_url)"
hash="$(field source_hash)"
filename="$(field source_filename)"
directory="$(field directory)"

if [[ -z "$url" || -z "$hash" || -z "$filename" || -z "$directory" ]]; then
  echo "libxml2.wrap is missing source fields" >&2
  exit 2
fi

mkdir -p "$CACHE"
tarball="$CACHE/$filename"
if [[ ! -f "$tarball" ]] || ! echo "$hash  $tarball" | sha256sum -c - >/dev/null; then
  curl -fsSL -o "$tarball.partial" "$url"
  mv "$tarball.partial" "$tarball"
fi
echo "$hash  $tarball" | sha256sum -c -

src="$CACHE/src"
if [[ ! -f "$src/$directory/meson.build" ]]; then
  rm -rf "$src"
  mkdir -p "$src"
  tar -xJf "$tarball" -C "$src"
fi

build="$CACHE/build-$hash"
if [[ ! -f "$build/build.ninja" ]]; then
  rm -rf "$build"
  meson setup "$build" "$src/$directory" \
    --default-library=static \
    -Ddocs=disabled \
    -Dpython=disabled \
    -Dreadline=disabled
fi
ninja -C "$build"

pc="$build/meson-uninstalled/libxml-2.0-uninstalled.pc"
if [[ ! -f "$pc" ]]; then
  echo "libxml-2.0-uninstalled.pc was not generated" >&2
  exit 2
fi

cflags="$(PKG_CONFIG_PATH="$(dirname "$pc")" pkg-config --cflags libxml-2.0-uninstalled)"
libs="$(PKG_CONFIG_PATH="$(dirname "$pc")" pkg-config --static --libs libxml-2.0-uninstalled)"
# shellcheck disable=SC2086
cc -O2 -Wall -Wextra $cflags \
  -o "$CACHE/output-overflow" "$ROOT/tests/libxml2-output-overflow.c" \
  -Wl,--wrap=fwrite -Wl,--wrap=write -Wl,--wrap=malloc -Wl,--wrap=realloc \
  $libs

"$CACHE/output-overflow"
