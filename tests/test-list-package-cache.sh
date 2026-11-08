#!/usr/bin/env bash
# A cache restore is validated by listing the tarballs and the libraries inside them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bash -n "$ROOT/scripts/list-package-cache.sh"

"$ROOT/scripts/list-package-cache.sh" --cache "$tmp/empty" --checkouts "$tmp/empty-checkouts" > "$tmp/empty.out"
grep -qx 'restored packages: 0' "$tmp/empty.out"
grep -qx 'restored checkouts: 0' "$tmp/empty.out"

mkdir -p "$tmp/cache/arm64-v8a/pkg/lib/arm64-v8a/pkgconfig" "$tmp/checkouts/urlkey/abc123"
printf 'libssl\n' > "$tmp/cache/arm64-v8a/pkg/lib/arm64-v8a/libssl.so"
printf 'Name: OpenSSL\n' > "$tmp/cache/arm64-v8a/pkg/lib/arm64-v8a/pkgconfig/libssl.pc"
tar -C "$tmp/cache/arm64-v8a/pkg" -cJf "$tmp/cache/arm64-v8a/openssl.tar.xz" lib
printf 'inputs-openssl\n' > "$tmp/cache/arm64-v8a/openssl.inputs"
rm -rf "$tmp/cache/arm64-v8a/pkg"
git -C "$tmp/checkouts/urlkey/abc123" init -q

"$ROOT/scripts/list-package-cache.sh" --cache "$tmp/cache" --checkouts "$tmp/checkouts" > "$tmp/list.out"
grep -qx $'restored\tarm64-v8a\topenssl\t'"$(stat -c %s "$tmp/cache/arm64-v8a/openssl.tar.xz")"$'\tinputs-openssl' "$tmp/list.out"
grep -qx '  lib/arm64-v8a/libssl.so' "$tmp/list.out"
grep -qx '  lib/arm64-v8a/pkgconfig/libssl.pc' "$tmp/list.out"
grep -qx 'restored packages: 1' "$tmp/list.out"
grep -qx $'restored checkout\turlkey/abc123' "$tmp/list.out"
grep -qx 'restored checkouts: 1' "$tmp/list.out"

echo "list package cache: ok"
