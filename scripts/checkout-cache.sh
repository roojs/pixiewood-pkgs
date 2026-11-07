#!/usr/bin/env bash
# Keep one git checkout per upstream revision and copy it into the build.
# A stored checkout is reused when its commit is still the revision we want.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

checkout_cache_root() {
  printf '%s\n' "${PIXIEWOOD_CHECKOUT_CACHE:-$ROOT/.cache/checkouts}"
}

checkout_cache_dir() {
  local url=$1 rev=$2 key safe
  key="$(printf '%s' "$url" | sha256sum | awk '{print $1}')"
  safe="${rev//\//_}"
  printf '%s/%s/%s\n' "$(checkout_cache_root)" "$key" "$safe"
}

# Print the commit a revision names. Tags and branches need the remote.
checkout_resolve_rev() {
  local url=$1 rev=$2 lines sha needle
  if [[ "$rev" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s\n' "$rev"
    return 0
  fi
  lines="$(git ls-remote "$url" "refs/tags/${rev}" "refs/tags/${rev}^{}" "refs/heads/${rev}")" || return 1
  needle="refs/tags/${rev}^{}"
  sha="$(printf '%s\n' "$lines" | awk -v needle="$needle" '$2 == needle { print $1; exit }')"
  if [ -z "$sha" ]; then
    needle="refs/heads/${rev}"
    sha="$(printf '%s\n' "$lines" | awk -v needle="$needle" '$2 == needle { print $1; exit }')"
  fi
  if [ -z "$sha" ]; then
    needle="refs/tags/${rev}"
    sha="$(printf '%s\n' "$lines" | awk -v needle="$needle" '$2 == needle { print $1; exit }')"
  fi
  if [ -z "$sha" ]; then
    echo "Could not resolve $rev from $url" >&2
    return 1
  fi
  printf '%s\n' "$sha"
}

checkout_head_is() {
  local dir=$1 sha=$2 actual
  [ -d "$dir/.git" ] || return 1
  actual="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$actual" ] && [ "$actual" = "$sha" ]
}

checkout_fetch() {
  local dir=$1 url=$2 rev=$3
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$url"
  git -C "$dir" fetch --quiet --depth 1 origin "$rev"
  git -C "$dir" checkout -q --detach FETCH_HEAD
}

# ensure DEST URL REV
# DEST receives a checkout of REV. The stored copy is fetched only when it
# is missing or names a different commit.
checkout_cache_ensure() {
  local dest=$1 url=$2 rev=$3 cache sha name
  name="$(basename "$dest")"
  sha="$(checkout_resolve_rev "$url" "$rev")" || return 1
  if checkout_head_is "$dest" "$sha"; then
    echo "Reusing checkout $name at $rev"
    return 0
  fi
  cache="$(checkout_cache_dir "$url" "$sha")"
  if checkout_head_is "$cache" "$sha"; then
    echo "Reusing checkout $name at $rev"
  else
    echo "Fetching checkout $name at $rev"
    checkout_fetch "$cache" "$url" "$rev"
    if ! checkout_head_is "$cache" "$sha"; then
      echo "Checkout $name is $(git -C "$cache" rev-parse HEAD), wanted $sha" >&2
      return 1
    fi
  fi
  if [ "$dest" = "$cache" ]; then
    return 0
  fi
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  cp -a "$cache" "$dest"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    ensure)
      shift
      [ "$#" -eq 3 ] || { echo "Usage: $0 ensure DEST URL REV" >&2; exit 2; }
      checkout_cache_ensure "$1" "$2" "$3"
      ;;
    *)
      echo "Usage: $0 ensure DEST URL REV" >&2
      exit 2
      ;;
  esac
fi
