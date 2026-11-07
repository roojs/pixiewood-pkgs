#!/usr/bin/env bash
# A stored checkout is copied again. A moved branch is fetched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bash -n "$ROOT/scripts/checkout-cache.sh"

remote="$tmp/remote"
mkdir -p "$remote"
git -C "$remote" init -q -b main
git -C "$remote" config user.email test@example.com
git -C "$remote" config user.name test
echo one > "$remote/file"
git -C "$remote" add file
git -C "$remote" commit -q -m one

export PIXIEWOOD_CHECKOUT_CACHE="$tmp/cache"
"$ROOT/scripts/checkout-cache.sh" ensure "$tmp/first" "$remote" main > "$tmp/first.out"
grep -q '^Fetching checkout first at main$' "$tmp/first.out"
first="$(git -C "$tmp/first" rev-parse HEAD)"

echo patched >> "$tmp/first/file"
"$ROOT/scripts/checkout-cache.sh" ensure "$tmp/first" "$remote" main > "$tmp/again.out"
grep -q '^Reusing checkout first at main$' "$tmp/again.out"
grep -q patched "$tmp/first/file"

"$ROOT/scripts/checkout-cache.sh" ensure "$tmp/second" "$remote" main > "$tmp/second.out"
grep -q '^Reusing checkout second at main$' "$tmp/second.out"
[ "$(git -C "$tmp/second" rev-parse HEAD)" = "$first" ]
if grep -q patched "$tmp/second/file"; then
  echo "stored checkout picked up a local patch" >&2
  exit 1
fi

echo two > "$remote/file"
git -C "$remote" add file
git -C "$remote" commit -q -m two
"$ROOT/scripts/checkout-cache.sh" ensure "$tmp/third" "$remote" main > "$tmp/third.out"
grep -q '^Fetching checkout third at main$' "$tmp/third.out"
third="$(git -C "$tmp/third" rev-parse HEAD)"
[ "$third" != "$first" ]

"$ROOT/scripts/checkout-cache.sh" ensure "$tmp/fourth" "$remote" "$third" > "$tmp/fourth.out"
grep -q "^Reusing checkout fourth at $third$" "$tmp/fourth.out"
[ "$(git -C "$tmp/fourth" rev-parse HEAD)" = "$third" ]

echo "checkout cache: ok"
