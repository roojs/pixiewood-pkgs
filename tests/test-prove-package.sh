#!/usr/bin/env bash
# The proof workflow's planner. It does not cross-compile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/upstream-index.sh
source "$ROOT/scripts/upstream-index.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
abi=arm64-v8a
gtk=gnome

obtain_kind() {
  local name=$1 pins=${2:-$ROOT/release.pins} cache=${3:-}
  local args=(--name "$name" --abi "$abi" --gtk "$gtk" --pins "$pins")
  if [ -n "$cache" ]; then
    args+=(--cache "$cache")
  fi
  "$ROOT/scripts/obtain-package.sh" "${args[@]}" | cut -f1
}

expect_line() {
  local file=$1 kind=$2 name=$3
  shift 3
  if [ "$#" -eq 0 ]; then
    grep -qx "$kind $name alone" "$file"
  else
    grep -qx "$kind $name on $*" "$file"
  fi
}

bash -n "$ROOT/scripts/prove-package.sh"

"$ROOT/scripts/prove-package.sh" --dry-run > "$tmp/default.out"
expect_line "$tmp/default.out" "$(obtain_kind openssl)" openssl
for name in glib pango gtk; do
  if ! jq -e --arg name "$name" '.packages[] | select(.name == $name)' "$ROOT/release.pins" >/dev/null; then
    grep -q "^build $name on " "$tmp/default.out"
    continue
  fi
  deps="$(sed -n "/^\\(pin\\|cache\\|build\\) $name on /s/^[^ ]* [^ ]* on //p" "$tmp/default.out" | head -n1)"
  read -r -a dep_array <<< "${deps:-}"
  expect_line "$tmp/default.out" "$(obtain_kind "$name")" "$name" "${dep_array[@]}"
done
if grep -q webkitgtk-android "$tmp/default.out"; then
  echo "default proof continued past gtk" >&2
  exit 1
fi
awk '
  /^pin / || /^cache / || /^build / {
    if ($2 == "cairo") cairo = NR
    if ($2 == "pango") pango = NR
    if ($2 == "gtk") gtk = NR
  }
  END {
    if (!(cairo && pango && gtk && cairo < pango && pango < gtk)) exit 1
  }
' "$tmp/default.out"

"$ROOT/scripts/prove-package.sh" --dry-run --packages sqlite3 > "$tmp/one.out"
expect_line "$tmp/one.out" "$(obtain_kind sqlite3)" sqlite3

"$ROOT/scripts/prove-package.sh" --dry-run --packages 'sqlite3, nghttp2,libpsl' > "$tmp/stack.out"
expect_line "$tmp/stack.out" "$(obtain_kind sqlite3)" sqlite3
expect_line "$tmp/stack.out" "$(obtain_kind nghttp2)" nghttp2 sqlite3
expect_line "$tmp/stack.out" "$(obtain_kind libpsl)" libpsl sqlite3 nghttp2

: > "$tmp/empty.pins"
mkdir -p "$tmp/cache/arm64-v8a"
touch "$tmp/cache/arm64-v8a/openssl.tar.xz" "$tmp/cache/arm64-v8a/libxml2.tar.xz"
"$ROOT/scripts/prove-package.sh" --dry-run --through gtk --pins "$tmp/empty.pins" --cache "$tmp/cache" > "$tmp/cache.out"
grep -qx 'cache openssl alone' "$tmp/cache.out"
grep -qx 'cache libxml2 on openssl' "$tmp/cache.out"
grep -qx 'build sqlite3 on openssl libxml2' "$tmp/cache.out"

"$ROOT/scripts/prove-package.sh" --dry-run --through libxml2 --cache "$tmp/cache" > "$tmp/pinwins.out"
expect_line "$tmp/pinwins.out" "$(obtain_kind openssl "$ROOT/release.pins" "$tmp/cache")" openssl
expect_line "$tmp/pinwins.out" "$(obtain_kind libxml2 "$ROOT/release.pins" "$tmp/cache")" libxml2 openssl

if "$ROOT/scripts/prove-package.sh" --dry-run --packages 'nghttp2,sqlite3' > "$tmp/order.out" 2> "$tmp/order.err"; then
  echo "out-of-order packages were accepted" >&2
  exit 1
fi
grep -q 'earlier in build-order.txt' "$tmp/order.err"

if "$ROOT/scripts/prove-package.sh" --dry-run --packages 'not-a-package' > "$tmp/unknown.out" 2> "$tmp/unknown.err"; then
  echo "unknown package was accepted" >&2
  exit 1
fi
grep -q 'Unknown package: not-a-package' "$tmp/unknown.err"

pkg="$tmp/frag"
mkdir -p "$pkg/lib/$abi/pkgconfig" "$pkg/lib/$abi"
printf '%s\n' 'prefix=/' 'Name: sqlite3' 'Version: 3.53.2' > "$pkg/lib/$abi/pkgconfig/sqlite3.pc"
printf 'sqlite\n' > "$pkg/lib/$abi/libsqlite3.so"
tar -C "$pkg" -cJf "$tmp/sqlite3-${abi}.tar.xz" .
"$ROOT/scripts/prove-package.sh" --check "$tmp/sqlite3-${abi}.tar.xz" --package sqlite3 --arch aarch64 > "$tmp/check.out"
grep -q 'proved sqlite3: sqlite3 3.53.2 (lib/arm64-v8a/libsqlite3.so)' "$tmp/check.out"

rm -rf "$pkg"
mkdir -p "$pkg/lib/$abi"
printf 'empty\n' > "$pkg/lib/$abi/README"
tar -C "$pkg" -cJf "$tmp/bare.tar.xz" .
if "$ROOT/scripts/prove-package.sh" --check "$tmp/bare.tar.xz" --package sqlite3 --arch aarch64 > "$tmp/bare.out" 2> "$tmp/bare.err"; then
  echo "tarball without the sqlite library was accepted" >&2
  exit 1
fi
grep -q 'no pkg-config file or library for sqlite3' "$tmp/bare.err"

ssl="$tmp/ssl"
mkdir -p "$ssl/lib/$abi/pkgconfig"
printf '%s\n' 'prefix=/' 'Name: OpenSSL' 'Version: 3.0.8' > "$ssl/lib/$abi/pkgconfig/openssl.pc"
printf '%s\n' 'prefix=/' 'Name: OpenSSL-libssl' 'Version: 3.0.8' > "$ssl/lib/$abi/pkgconfig/libssl.pc"
printf '%s\n' 'prefix=/' 'Name: OpenSSL-libcrypto' 'Version: 3.0.8' > "$ssl/lib/$abi/pkgconfig/libcrypto.pc"
printf 'ssl\n' > "$ssl/lib/$abi/libssl.so"
printf 'crypto\n' > "$ssl/lib/$abi/libcrypto.so"
tar -C "$ssl" -cJf "$tmp/openssl-${abi}.tar.xz" .
"$ROOT/scripts/prove-package.sh" --check "$tmp/openssl-${abi}.tar.xz" --package openssl --arch aarch64 > "$tmp/ssl.out"
grep -qE 'proved openssl: OpenSSL 3.0.8 \(lib/arm64-v8a/lib(ssl|crypto)\.so\)' "$tmp/ssl.out"

net="$tmp/net"
mkdir -p "$net/lib/$abi/pkgconfig" "$net/lib/$abi/gio/modules"
printf '%s\n' 'prefix=/' 'Name: gioopenssl' 'Version: 2.80.1' > "$net/lib/$abi/pkgconfig/gioopenssl.pc"
printf 'module\n' > "$net/lib/$abi/gio/modules/libgioopenssl.a"
tar -C "$net" -cJf "$tmp/glib-networking-${abi}.tar.xz" .
"$ROOT/scripts/prove-package.sh" --check "$tmp/glib-networking-${abi}.tar.xz" --package glib-networking --arch aarch64 > "$tmp/net.out"
grep -q 'proved glib-networking: gioopenssl 2.80.1 (lib/arm64-v8a/gio/modules/libgioopenssl.a)' "$tmp/net.out"

echo "prove package: ok"
