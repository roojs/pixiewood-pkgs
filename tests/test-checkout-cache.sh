#!/usr/bin/env bash
# A stored checkout is copied again. A new tag is fetched. A branch is refused.
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
git -C "$remote" tag -a 1.0 -m 1.0

export PIXIEWOOD_CHECKOUT_CACHE="$tmp/cache"
"$ROOT/scripts/checkout-cache.sh" ensure "$tmp/first" "$remote" 1.0 > "$tmp/first.out"
grep -q '^Fetching checkout first at 1.0$' "$tmp/first.out"
first="$(git -C "$tmp/first" rev-parse HEAD)"

echo patched >> "$tmp/first/file"
"$ROOT/scripts/checkout-cache.sh" ensure "$tmp/first" "$remote" 1.0 > "$tmp/again.out"
grep -q '^Reusing checkout first at 1.0$' "$tmp/again.out"
grep -q patched "$tmp/first/file"

"$ROOT/scripts/checkout-cache.sh" ensure "$tmp/second" "$remote" 1.0 > "$tmp/second.out"
grep -q '^Reusing checkout second at 1.0$' "$tmp/second.out"
[ "$(git -C "$tmp/second" rev-parse HEAD)" = "$first" ]
if grep -q patched "$tmp/second/file"; then
  echo "stored checkout picked up a local patch" >&2
  exit 1
fi

echo two > "$remote/file"
git -C "$remote" add file
git -C "$remote" commit -q -m two
git -C "$remote" tag -a 1.1 -m 1.1
"$ROOT/scripts/checkout-cache.sh" ensure "$tmp/third" "$remote" 1.1 > "$tmp/third.out"
grep -q '^Fetching checkout third at 1.1$' "$tmp/third.out"
third="$(git -C "$tmp/third" rev-parse HEAD)"
[ "$third" != "$first" ]

"$ROOT/scripts/checkout-cache.sh" ensure "$tmp/fourth" "$remote" "$third" > "$tmp/fourth.out"
grep -q "^Reusing checkout fourth at $third$" "$tmp/fourth.out"
[ "$(git -C "$tmp/fourth" rev-parse HEAD)" = "$third" ]

# A branch that shares the tag's name is not what gets checked out.
git -C "$remote" branch 1.0 HEAD
rm -rf "$tmp/cache"
"$ROOT/scripts/checkout-cache.sh" ensure "$tmp/fifth" "$remote" 1.0 > /dev/null
[ "$(git -C "$tmp/fifth" rev-parse HEAD)" = "$first" ]
git -C "$remote" branch -q -D 1.0

# A branch is refused before anything is fetched or written.
git -C "$remote" branch master HEAD
cached_before="$(find "$tmp/cache" | LC_ALL=C sort)"
for branch in main master HEAD head; do
  if "$ROOT/scripts/checkout-cache.sh" ensure "$tmp/branch-$branch" "$remote" "$branch" > /dev/null 2> "$tmp/branch.err"; then
    echo "branch $branch was checked out" >&2
    exit 1
  fi
  grep -q 'a branch is not checked out' "$tmp/branch.err"
  if [ -e "$tmp/branch-$branch" ]; then
    echo "refused branch $branch left a checkout" >&2
    exit 1
  fi
done
if [ "$(find "$tmp/cache" | LC_ALL=C sort)" != "$cached_before" ]; then
  echo "refused branches filled the checkout cache" >&2
  exit 1
fi

echo "checkout cache: ok"
