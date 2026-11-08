#!/usr/bin/env bash
# Print the built packages and source checkouts a cache restore left behind.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache="${PIXIEWOOD_PACKAGE_CACHE:-$ROOT/.cache/packages}"
checkouts="${PIXIEWOOD_CHECKOUT_CACHE:-$ROOT/.cache/checkouts}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cache) cache=$2; shift 2 ;;
    --checkouts) checkouts=$2; shift 2 ;;
    *)
      echo "Usage: $0 [--cache DIR] [--checkouts DIR]" >&2
      exit 2
      ;;
  esac
done

package_count=0
if [ -d "$cache" ]; then
  while IFS= read -r tarball; do
    [ -n "$tarball" ] || continue
    abi="$(basename "$(dirname "$tarball")")"
    name="$(basename "$tarball" .tar.xz)"
    bytes="$(stat -c %s "$tarball")"
    stamp="$cache/$abi/$name.inputs"
    if [ -f "$stamp" ]; then
      inputs="$(tr -d '\n' < "$stamp")"
    else
      inputs="(no inputs stamp)"
    fi
    printf 'restored\t%s\t%s\t%s\t%s\n' "$abi" "$name" "$bytes" "$inputs"
    tar -tJf "$tarball" | awk '
      /\/pkgconfig\/[^\/]+\.pc$/ || /\/lib[^\/]+\.(so|a)$/ { print "  " $0 }
    '
    package_count=$((package_count + 1))
  done < <(find "$cache" -type f -name '*.tar.xz' | LC_ALL=C sort)
fi
printf 'restored packages: %s\n' "$package_count"

checkout_count=0
if [ -d "$checkouts" ]; then
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    rel="${dir#"$checkouts"/}"
    printf 'restored checkout\t%s\n' "$rel"
    checkout_count=$((checkout_count + 1))
  done < <(find "$checkouts" -mindepth 2 -maxdepth 2 -type d | LC_ALL=C sort)
fi
printf 'restored checkouts: %s\n' "$checkout_count"
