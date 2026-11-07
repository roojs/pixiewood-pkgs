#!/usr/bin/env bash
# Release pins win, then the package cache, then a source build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bash -n "$ROOT/scripts/obtain-package.sh"

decision="$("$ROOT/scripts/obtain-package.sh" --name openssl --abi arm64-v8a --gtk gnome)"
case "$decision" in
  pin$'\t'https://*) ;;
  *) echo "openssl should come from the release pins: $decision" >&2; exit 1 ;;
esac

# A cache entry does not replace a current pin.
mkdir -p "$tmp/cache/arm64-v8a"
echo cached > "$tmp/cache/arm64-v8a/openssl.tar.xz"
decision="$("$ROOT/scripts/obtain-package.sh" --name openssl --abi arm64-v8a --gtk gnome --cache "$tmp/cache")"
case "$decision" in
  pin$'\t'*) ;;
  *) echo "cache replaced a current openssl pin: $decision" >&2; exit 1 ;;
esac

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
cat > "$tmp/pins" << 'EOF'
# abi gtk release name track resolved inputs url
arm64-v8a	gnome	1.261107	demo	track	resolved-a	inputs-a	https://example.invalid/demo.tar.xz
EOF
decision="$("$ROOT/scripts/obtain-package.sh" --name demo --abi arm64-v8a --gtk gnome --pins "$tmp/pins" --resolved resolved-a --inputs inputs-a)"
[ "$decision" = "pin"$'\t'"https://example.invalid/demo.tar.xz" ]
decision="$("$ROOT/scripts/obtain-package.sh" --name demo --abi arm64-v8a --gtk gnome --pins "$tmp/pins" --resolved resolved-b --inputs inputs-a)"
[ "$decision" = build ]

# glib's wrap patch is applied by build-sysroot.sh, so a script change
# since the pin is a source build rather than the published tarball.
pins_commit="$(git -C "$ROOT" log -1 --format=%H -- current.pins)"
glib="$("$ROOT/scripts/obtain-package.sh" --name glib --abi arm64-v8a --gtk gnome)"
glib="${glib%%$'\t'*}"
if git -C "$ROOT" diff --quiet "$pins_commit" HEAD -- scripts/build-sysroot.sh; then
  [ "$glib" = pin ]
else
  [ "$glib" = build ]
fi

echo "obtain package: ok"
