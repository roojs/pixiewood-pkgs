#!/usr/bin/env bash
# Build the libsoup wrap this repository ships and run the client checks
# in tests/libsoup-client-vulns.c against that library.
#
# The checks exit 0 only when multipart response parsing stays inside the
# response body and a cross-origin redirect drops Proxy-Authorization.
# They fail while packages/libsoup/libsoup.wrap still points at 3.6.5.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAP="$ROOT/packages/libsoup/libsoup.wrap"
SRC="$ROOT/tests/libsoup-client-vulns.c"

field() {
  sed -n "s/^${1}[[:space:]]*=[[:space:]]*//p" "$WRAP" | head -n1 | tr -d '[:space:]'
}

for tool in curl meson ninja gcc pkg-config sha256sum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
done
if ! pkg-config --exists glib-2.0 gio-2.0 gobject-2.0 libnghttp2 libpsl sqlite3 zlib; then
  echo "Missing a library libsoup links (glib, nghttp2, libpsl, sqlite, zlib)" >&2
  exit 1
fi

url="$(field source_url)"
hash="$(field source_hash)"
filename="$(field source_filename)"
[ -n "$url" ] && [ -n "$hash" ] && [ -n "$filename" ]

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -fsSL -o "$work/$filename" "$url"
echo "$hash  $work/$filename" | sha256sum -c -
tar -xJf "$work/$filename" -C "$work"
srcdir="$(find "$work" -mindepth 1 -maxdepth 1 -type d -name 'libsoup-*' | head -n1)"
[ -n "$srcdir" ]

# Same feature switches as cross/extra.cross [libsoup:project options].
# HTTP/2 stays compiled: libsoup requires libnghttp2 and this repo builds
# nghttp2 ahead of libsoup. AddressSanitizer is what makes the
# out-of-bounds reads fail the run.
CC=gcc CXX=g++ meson setup "$work/build" "$srcdir" \
  --buildtype=debug \
  -Db_sanitize=address \
  -Db_lundef=false \
  -Dtests=false \
  -Dinstalled_tests=false \
  -Dautobahn=disabled \
  -Dpkcs11_tests=disabled \
  -Dfuzzing=disabled \
  -Ddoc_tests=false \
  -Dintrospection=disabled \
  -Dvapi=disabled \
  -Ddocs=disabled \
  -Dbrotli=disabled \
  -Dgssapi=disabled \
  -Dntlm=disabled \
  -Dtls_check=false \
  -Dsysprof=disabled
ninja -C "$work/build" -j"$(nproc)"

export PKG_CONFIG_PATH="$work/build/meson-uninstalled${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
gcc -fsanitize=address -g -o "$work/client-vulns" "$SRC" \
  $(pkg-config --cflags --libs libsoup-3.0)

export LD_LIBRARY_PATH="$work/build/libsoup${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export ASAN_OPTIONS="${ASAN_OPTIONS:-halt_on_error=1:detect_leaks=0}"

fail=0
for case in multipart-underflow multipart-strstr proxy-redirect; do
  echo "=== $case ==="
  if "$work/client-vulns" "$case"; then
    echo "PASS $case"
  else
    echo "FAIL $case" >&2
    fail=1
  fi
done

exit "$fail"
