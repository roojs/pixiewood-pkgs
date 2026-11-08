#!/usr/bin/env bash
# The proof workflow's planner. It does not cross-compile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bash -n "$ROOT/scripts/prove-package.sh"

"$ROOT/scripts/prove-package.sh" --dry-run > "$tmp/default.out"
pins_commit="$(git -C "$ROOT" log -1 --format=%H -- current.pins)"
if git -C "$ROOT" diff --quiet "$pins_commit" HEAD -- "$ROOT/packages/openssl" "$ROOT/cross" "$ROOT/android-distro.conf"; then
  grep -qx 'pin openssl alone' "$tmp/default.out"
else
  grep -qx 'build openssl alone' "$tmp/default.out"
fi
grep -q '^build glib on ' "$tmp/default.out"
grep -q '^build pango on ' "$tmp/default.out"
grep -q '^build gdk on ' "$tmp/default.out"
grep -q '^build gtk on ' "$tmp/default.out"
if grep -q webkitgtk-android "$tmp/default.out"; then
  echo "default proof continued past gtk" >&2
  exit 1
fi
awk '
  /^pin / || /^cache / || /^build / {
    if ($2 == "cairo") cairo = NR
    if ($2 == "pango") pango = NR
    if ($2 == "gdk") gdk = NR
    if ($2 == "gtk") gtk = NR
  }
  END {
    if (!(cairo && pango && gdk && gtk && cairo < pango && pango < gdk && gdk < gtk)) exit 1
  }
' "$tmp/default.out"

"$ROOT/scripts/prove-package.sh" --dry-run --packages sqlite3 > "$tmp/one.out"
if git -C "$ROOT" diff --quiet "$pins_commit" HEAD -- "$ROOT/packages/sqlite3" "$ROOT/cross" "$ROOT/android-distro.conf"; then
  grep -qx 'pin sqlite3 alone' "$tmp/one.out"
else
  grep -qx 'build sqlite3 alone' "$tmp/one.out"
fi

"$ROOT/scripts/prove-package.sh" --dry-run --packages 'sqlite3, nghttp2,libpsl' > "$tmp/stack.out"
if git -C "$ROOT" diff --quiet "$pins_commit" HEAD -- "$ROOT/packages/sqlite3" "$ROOT/cross" "$ROOT/android-distro.conf"; then
  grep -qx 'pin sqlite3 alone' "$tmp/stack.out"
else
  grep -qx 'build sqlite3 alone' "$tmp/stack.out"
fi
if git -C "$ROOT" diff --quiet "$pins_commit" HEAD -- "$ROOT/packages/nghttp2" "$ROOT/cross" "$ROOT/android-distro.conf"; then
  grep -qx 'pin nghttp2 on sqlite3' "$tmp/stack.out"
else
  grep -qx 'build nghttp2 on sqlite3' "$tmp/stack.out"
fi
if git -C "$ROOT" diff --quiet "$pins_commit" HEAD -- "$ROOT/packages/libpsl" "$ROOT/cross" "$ROOT/android-distro.conf"; then
  grep -qx 'pin libpsl on sqlite3 nghttp2' "$tmp/stack.out"
else
  grep -qx 'build libpsl on sqlite3 nghttp2' "$tmp/stack.out"
fi

: > "$tmp/empty.pins"
mkdir -p "$tmp/cache/arm64-v8a"
touch "$tmp/cache/arm64-v8a/openssl.tar.xz" "$tmp/cache/arm64-v8a/libxml2.tar.xz"
"$ROOT/scripts/prove-package.sh" --dry-run --through gtk --pins "$tmp/empty.pins" --cache "$tmp/cache" > "$tmp/cache.out"
grep -qx 'cache openssl alone' "$tmp/cache.out"
grep -qx 'cache libxml2 on openssl' "$tmp/cache.out"
grep -qx 'build sqlite3 on openssl libxml2' "$tmp/cache.out"

"$ROOT/scripts/prove-package.sh" --dry-run --through libxml2 --cache "$tmp/cache" > "$tmp/pinwins.out"
if git -C "$ROOT" diff --quiet "$pins_commit" HEAD -- "$ROOT/packages/openssl" "$ROOT/cross" "$ROOT/android-distro.conf"; then
  grep -qx 'pin openssl alone' "$tmp/pinwins.out"
else
  grep -qx 'cache openssl alone' "$tmp/pinwins.out"
fi
if git -C "$ROOT" diff --quiet "$pins_commit" HEAD -- "$ROOT/packages/libxml2" "$ROOT/cross" "$ROOT/android-distro.conf"; then
  grep -qx 'pin libxml2 on openssl' "$tmp/pinwins.out"
else
  grep -qx 'cache libxml2 on openssl' "$tmp/pinwins.out"
fi

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

abi=arm64-v8a
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
mkdir -p "$ssl/lib/$abi"
printf 'ssl\n' > "$ssl/lib/$abi/libssl.so"
printf 'crypto\n' > "$ssl/lib/$abi/libcrypto.so"
tar -C "$ssl" -cJf "$tmp/openssl-${abi}.tar.xz" .
"$ROOT/scripts/prove-package.sh" --check "$tmp/openssl-${abi}.tar.xz" --package openssl --arch aarch64 > "$tmp/ssl.out"
grep -q 'proved openssl: (lib/arm64-v8a/libssl.so)' "$tmp/ssl.out"

mkdir -p "$pkg/lib/$abi/pkgconfig" "$pkg/bin/$abi"
printf '%s\n' 'prefix=/' 'Name: pixiewood-gdk' 'Version: 4' > "$pkg/lib/$abi/pkgconfig/pixiewood-gdk.pc"
printf '%s\n' 'prefix=/' 'Name: glib' 'Version: 2.80.0' > "$pkg/lib/$abi/pkgconfig/glib-2.0.pc"
printf 'gdk\n' > "$pkg/lib/$abi/libgdk.a"
printf '#!/bin/sh\n' > "$pkg/bin/$abi/gdbus-codegen"
tar -C "$pkg" -cJf "$tmp/polluted-gdk.tar.xz" .
if "$ROOT/scripts/prove-package.sh" --check "$tmp/polluted-gdk.tar.xz" --package gdk --arch aarch64 > "$tmp/polluted.out" 2> "$tmp/polluted.err"; then
  echo "gdk tarball containing glib was accepted" >&2
  exit 1
fi
grep -q 'contains glib-2.0.pc from glib' "$tmp/polluted.err"

echo "prove package: ok"
