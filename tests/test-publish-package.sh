#!/usr/bin/env bash
# A finished package is recorded on its own. A later package is not required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bash -n "$ROOT/scripts/publish-package.sh"
# shellcheck source=../scripts/current-pins.sh
source "$ROOT/scripts/current-pins.sh"
[ "$(release_stamp "1.261107")" = "2026-11-07T00:00:00Z" ]
[ "$(release_stamp "1.261108010203")" = "2026-11-08T01:02:03Z" ]
[ "$(release_version "2026-11-07T00:00:00Z")" = "1.261107000000" ]
[ "$(release_version "2026-11-08T01:02:03Z")" = "1.261108010203" ]
if release_version "2026-11-08" >/dev/null 2>"$tmp/date-only.err"; then
  echo "a date without a clock time was accepted" >&2
  exit 1
fi
grep -q 'YYYY-MM-DDTHH:MM:SS' "$tmp/date-only.err"

printf 'bytes\n' > "$tmp/openssl.tar.xz"
printf 'bytes\n' > "$tmp/gtk.tar.xz"
{
  printf '%s\n' '# abi gtk release name track resolved inputs url'
  printf '%s\n' $'arm64-v8a\tgnome\t1.261108\topenssl\told-track\told-res\told-in\thttps://example.invalid/openssl.tar.xz'
  printf '%s\n' $'arm64-v8a\tgnome\t1.261108\tglib\tgtrack\tgres\tgin\thttps://example.invalid/glib.tar.xz'
} > "$tmp/pins"

"$ROOT/scripts/publish-package.sh" \
  --name openssl \
  --tarball "$tmp/openssl.tar.xz" \
  --arch aarch64 \
  --gtk gnome \
  --track openssl-3.0.8.tar.gz \
  --resolved hash-o \
  --inputs inputs-o \
  --created 2026-11-08T01:02:03Z \
  --repo roojs/pixiewood-pkgs \
  --file "$tmp/pins" \
  --no-upload > "$tmp/openssl.out"
grep -q 'Published openssl 1.261108010203' "$tmp/openssl.out"
grep -q 'https://github.com/roojs/pixiewood-pkgs/releases/download/1.261108010203/openssl-arm-v31-3.0.8.pixie' "$tmp/pins"
grep -q $'arm64-v8a\tgnome\t1.261108010203\topenssl\topenssl-3.0.8.tar.gz\thash-o\tinputs-o\t' "$tmp/pins"
grep -q $'arm64-v8a\tgnome\t1.261108\tglib\tgtrack\tgres\tgin\thttps://example.invalid/glib.tar.xz' "$tmp/pins"
if grep -q 'example.invalid/openssl' "$tmp/pins"; then
  echo "the finished package kept its old URL" >&2
  exit 1
fi

"$ROOT/scripts/publish-package.sh" \
  --name gtk \
  --tarball "$tmp/gtk.tar.xz" \
  --arch aarch64 \
  --gtk gnome \
  --track ae709f96 \
  --resolved ae709f96 \
  --inputs inputs-gtk \
  --created 2026-11-08T01:02:03Z \
  --repo roojs/pixiewood-pkgs \
  --file "$tmp/pins" \
  --no-upload > "$tmp/gtk.out"
grep -q 'Published gtk 1.261108010203' "$tmp/gtk.out"
grep -q 'gtk-arm-v31-snapshot.pixie' "$tmp/pins"
grep -q $'arm64-v8a\tgnome\t1.261108\tglib\t' "$tmp/pins"

if "$ROOT/scripts/publish-package.sh" \
  --name openssl \
  --tarball "$tmp/missing.tar.xz" \
  --arch aarch64 \
  --gtk gnome \
  --track track \
  --resolved resolved \
  --inputs inputs \
  --created 2026-11-08T01:02:03Z \
  --file "$tmp/pins" \
  --no-upload > "$tmp/missing.out" 2> "$tmp/missing.err"; then
  echo "a missing tarball was published" >&2
  exit 1
fi

grep -q 'publish-package.sh' "$ROOT/scripts/prove-package.sh"
grep -q 'PROVE_PUBLISH' "$ROOT/scripts/prove-package.sh"
grep -q 'PROVE_PUBLISH' "$ROOT/.github/workflows/prove-package.yml"
grep -q 'contents: write' "$ROOT/.github/workflows/prove-package.yml"
grep -q 'publish-package.sh' "$ROOT/.github/workflows/monitor-upstreams.yml"
if grep -q 'Commit the package list before the build' "$ROOT/.github/workflows/monitor-upstreams.yml"; then
  echo "monitor still writes pins before a package is uploaded" >&2
  exit 1
fi

hdr="$tmp/headers"
mkdir -p "$hdr/generated" "$hdr/upstream" "$hdr/dest"
printf 'GENERATED\n' > "$hdr/generated/ssl.h"
printf 'CONFIG\n' > "$hdr/generated/configuration.h"
printf 'UPSTREAM\n' > "$hdr/upstream/ssl.h"
printf 'CONF\n' > "$hdr/upstream/opensslconf.h"
sh "$ROOT/packages/openssl/packagefiles/openssl/install-headers.sh" \
  "$hdr/generated" "$hdr/upstream" "$hdr/dest"
grep -qx GENERATED "$hdr/dest/ssl.h"
grep -qx CONFIG "$hdr/dest/configuration.h"
grep -qx CONF "$hdr/dest/opensslconf.h"

[ "$(package_track_label openssl-3.0.8.tar.gz)" = 3.0.8 ]
[ "$(package_track_label libjpeg-turbo-3.1.1.tar.gz)" = 3.1.1 ]
[ "$(package_track_label sqlite-amalgamation-3530200.zip)" = 3530200 ]
[ "$(package_track_label 2.90.0)" = 2.90.0 ]
[ "$(package_track_label v1.0.16)" = 1.0.16 ]
[ "$(package_track_label main)" = snapshot ]
[ "$(package_track_label HEAD)" = snapshot ]
[ "$(package_track_label ae709f962a51f9108a1e6381bcfbd05bbaecc840)" = snapshot ]
[ "$(package_track_label android-ime)" = snapshot ]
[ "$(package_abi_label arm64-v8a)" = arm ]
[ "$(package_abi_label x86_64)" = x86 ]
[ "$(package_asset_name openssl arm64-v8a 3.0.8)" = openssl-arm-v31-3.0.8.pixie ]
[ "$(package_asset_name openssl x86_64 3.0.8)" = openssl-x86-v31-3.0.8.pixie ]

echo "publish package: ok"
