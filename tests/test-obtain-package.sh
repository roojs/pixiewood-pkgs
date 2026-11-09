#!/usr/bin/env bash
# Release pins win, then the package cache, then a source build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bash -n "$ROOT/scripts/obtain-package.sh"

pins_commit="$(git -C "$ROOT" log -1 --format=%H -- release.pins || true)"
if [ -z "$pins_commit" ]; then
  pins_commit="$(git -C "$ROOT" log -1 --format=%H -- current.pins)"
fi
openssl_recipe_current=0
if git -C "$ROOT" diff --quiet "$pins_commit" HEAD -- "$ROOT/packages/openssl" "$ROOT/cross" "$ROOT/android-distro.conf"; then
  openssl_recipe_current=1
fi

decision="$("$ROOT/scripts/obtain-package.sh" --name openssl --abi arm64-v8a --gtk gnome)"
if [ "$openssl_recipe_current" -eq 1 ]; then
  case "$decision" in
    pin$'\t'https://*) ;;
    *) echo "openssl should come from the release pins: $decision" >&2; exit 1 ;;
  esac
else
  [ "$decision" = build ]
fi

# A cache entry does not replace a current pin. A stale pin falls through to the cache.
mkdir -p "$tmp/cache/arm64-v8a"
echo cached > "$tmp/cache/arm64-v8a/openssl.tar.xz"
decision="$("$ROOT/scripts/obtain-package.sh" --name openssl --abi arm64-v8a --gtk gnome --cache "$tmp/cache")"
if [ "$openssl_recipe_current" -eq 1 ]; then
  case "$decision" in
    pin$'\t'*) ;;
    *) echo "cache replaced a current openssl pin: $decision" >&2; exit 1 ;;
  esac
else
  [ "$decision" = "cache"$'\t'"$tmp/cache/arm64-v8a/openssl.tar.xz" ]
fi

# No pin: the cache is the package.
decision="$("$ROOT/scripts/obtain-package.sh" --name openssl --abi arm64-v8a --gtk gnome --cache "$tmp/cache" --pins "$tmp/missing.pins")"
[ "$decision" = "cache"$'\t'"$tmp/cache/arm64-v8a/openssl.tar.xz" ]

# A cache stamp that is not this resolve is not the package.
printf 'other\n' > "$tmp/cache/arm64-v8a/openssl.inputs"
decision="$("$ROOT/scripts/obtain-package.sh" --name openssl --abi arm64-v8a --gtk gnome --cache "$tmp/cache" --pins "$tmp/missing.pins" --inputs this)"
[ "$decision" = build ]
printf 'this\n' > "$tmp/cache/arm64-v8a/openssl.inputs"
decision="$("$ROOT/scripts/obtain-package.sh" --name openssl --abi arm64-v8a --gtk gnome --cache "$tmp/cache" --pins "$tmp/missing.pins" --inputs this)"
[ "$decision" = "cache"$'\t'"$tmp/cache/arm64-v8a/openssl.tar.xz" ]

# A fixture pin is used when its inputs match, and skipped when they do not.
jq -n '{packages: [{abi:"arm64-v8a", repo:"https://gitlab.gnome.org/GNOME/gtk.git", name:"demo", track:"track", resolved:"resolved-a", inputs:"inputs-a", url:"https://example.invalid/demo.tar.xz"}]}' > "$tmp/pins"
decision="$("$ROOT/scripts/obtain-package.sh" --name demo --abi arm64-v8a --gtk gnome --pins "$tmp/pins" --resolved resolved-a --inputs inputs-a)"
[ "$decision" = "pin"$'\t'"https://example.invalid/demo.tar.xz" ]
decision="$("$ROOT/scripts/obtain-package.sh" --name demo --abi arm64-v8a --gtk gnome --pins "$tmp/pins" --resolved resolved-b --inputs inputs-a)"
[ "$decision" = build ]

# glib 2.90.1 is already published. A later recipe change does not build it again.
glib="$("$ROOT/scripts/obtain-package.sh" --name glib --abi arm64-v8a --gtk gnome --inputs other-inputs)"
[ "$glib" = "pin"$'\t'"$(jq -r '.packages[] | select(.abi=="arm64-v8a" and .name=="glib") | .url' "$ROOT/release.pins")" ]

# A different release version is not that published file.
jq -n '{packages: [{abi:"arm64-v8a", repo:"https://gitlab.gnome.org/GNOME/gtk.git", name:"openssl", track:"openssl-3.0.8.tar.gz", resolved:"hash-o", inputs:"inputs-o", url:"https://example.invalid/openssl-3.0.8.pixie"}]}' > "$tmp/old-openssl.pins"
decision="$("$ROOT/scripts/obtain-package.sh" --name openssl --abi arm64-v8a --gtk gnome --pins "$tmp/old-openssl.pins" --inputs other)"
[ "$decision" = "pin"$'\t'"https://example.invalid/openssl-3.0.8.pixie" ]

# A newer version that already failed this recipe uses the published file.
pango_track="$(sed -n 's/^revision[[:space:]]*=[[:space:]]*//p' "$ROOT/packages/pango/pango.wrap" | head -n1 | tr -d '[:space:]')"
printf '%s\n' "arm64-v8a"$'\t'"pango"$'\t'"${pango_track}"$'\t'"inputs-failed" > "$tmp/failures.tsv"
jq -n '{packages: [{abi:"arm64-v8a", repo:"https://gitlab.gnome.org/GNOME/gtk.git", name:"pango", track:"1.58.2", resolved:"hash-p", inputs:"inputs-old", url:"https://example.invalid/pango-1.58.2.pixie"}]}' > "$tmp/pango.pins"
decision="$(FAILURES_FILE="$tmp/failures.tsv" "$ROOT/scripts/obtain-package.sh" --name pango --abi arm64-v8a --gtk gnome --pins "$tmp/pango.pins" --inputs inputs-failed)"
[ "$decision" = "pin"$'\t'"https://example.invalid/pango-1.58.2.pixie" ]
decision="$("$ROOT/scripts/obtain-package.sh" --name pango --abi arm64-v8a --gtk gnome --pins "$tmp/pango.pins" --inputs inputs-failed)"
[ "$decision" = build ]

echo "obtain package: ok"
