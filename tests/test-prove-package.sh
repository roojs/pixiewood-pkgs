#!/usr/bin/env bash
# The proof workflow's planner. It does not cross-compile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bash -n "$ROOT/scripts/prove-package.sh"

"$ROOT/scripts/prove-package.sh" --dry-run --packages sqlite3 > "$tmp/one.out"
grep -qx 'prove sqlite3 alone' "$tmp/one.out"

"$ROOT/scripts/prove-package.sh" --dry-run --packages 'sqlite3, nghttp2,libpsl' > "$tmp/stack.out"
grep -qx 'prove sqlite3 alone' "$tmp/stack.out"
grep -qx 'prove nghttp2 on sqlite3' "$tmp/stack.out"
grep -qx 'prove libpsl on sqlite3 nghttp2' "$tmp/stack.out"

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
"$ROOT/scripts/prove-package.sh" --check "$tmp/sqlite3-${abi}.tar.xz" --arch aarch64 > "$tmp/check.out"
grep -q 'proved sqlite3-arm64-v8a: sqlite3 3.53.2 (lib/arm64-v8a/libsqlite3.so)' "$tmp/check.out"

rm -f "$pkg/lib/$abi/pkgconfig/sqlite3.pc"
tar -C "$pkg" -cJf "$tmp/bare.tar.xz" .
if "$ROOT/scripts/prove-package.sh" --check "$tmp/bare.tar.xz" --arch aarch64 > "$tmp/bare.out" 2> "$tmp/bare.err"; then
  echo "tarball without pkg-config was accepted" >&2
  exit 1
fi
grep -q 'No pkg-config file' "$tmp/bare.err"

echo "prove package: ok"
