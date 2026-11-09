#!/usr/bin/env bash
# Index planning, package assembly, and the IME vs GNOME GTK target.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for script in "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh; do
  bash -n "$script"
done

# Package directories and the build order are the same set.
find "$ROOT/packages" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort > "$tmp/pkgs"
grep -v '^#' "$ROOT/build-order.txt" | grep -v '^$' | LC_ALL=C sort > "$tmp/order"
diff -u "$tmp/pkgs" "$tmp/order"

# shellcheck source=../scripts/pixie-common.sh
source "$ROOT/scripts/pixie-common.sh"
[ "$(sysroot_map "$ROOT/cross/abi" aarch64)" = arm64-v8a ]
[ "$(sysroot_map "$ROOT/cross/abi" x86_64)" = x86_64 ]
if sysroot_map "$ROOT/cross/abi" mips >/dev/null; then
  echo "unknown arch was accepted" >&2
  exit 1
fi
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if ! awk -v name="$name" '$1 !~ /^#/ && $1 == name { found = 1 } END { exit !found }' "$ROOT/packages/probes"; then
    echo "packages/probes is missing $name" >&2
    exit 1
  fi
done < "$tmp/order"
openssl_probe="$(awk '$1 == "openssl" { $1 = ""; sub(/^ /, ""); print }' "$ROOT/packages/probes")"
[ "$openssl_probe" = "openssl libssl libcrypto" ]
networking_probe="$(awk '$1 == "glib-networking" { $1 = ""; sub(/^ /, ""); print }' "$ROOT/packages/probes")"
[ "$networking_probe" = "+subproject gioopenssl" ]

repo="$(mktemp -d)"
git -C "$repo" init -q -b main
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
echo one > "$repo/file"
git -C "$repo" add file
git -C "$repo" commit -q -m one
first="$(git -C "$repo" rev-parse HEAD)"

mkdir -p "$tmp/packages/demo" "$tmp/packages/filepkg" "$tmp/packages/pinned"
cat > "$tmp/packages/demo/demo.wrap" << EOF
[wrap-git]
directory = demo
url = $repo
revision = main
EOF
cat > "$tmp/packages/filepkg/filepkg.wrap" << 'EOF'
[wrap-file]
directory = filepkg-1
source_url = https://example.invalid/filepkg-1.tar.gz
source_filename = filepkg-1.tar.gz
source_hash = aaaa
EOF
# A pinned sha must not contact the remote.
cat > "$tmp/packages/pinned/pinned.wrap" << 'EOF'
[wrap-git]
directory = pinned
url = https://example.invalid/nope.git
revision = 0123456789abcdef0123456789abcdef01234567
EOF

"$ROOT/scripts/upstream-index.sh" resolve --packages "$tmp/packages" --gtk gnome --out "$tmp/resolved.tsv"
awk -F '\t' '$1 == "demo" { print $4 }' "$tmp/resolved.tsv" | grep -qx "$first"
awk -F '\t' '$1 == "filepkg" { print $4 }' "$tmp/resolved.tsv" | grep -qx aaaa
awk -F '\t' '$1 == "pinned" { print $4 }' "$tmp/resolved.tsv" | grep -qx 0123456789abcdef0123456789abcdef01234567

echo two > "$repo/file"
git -C "$repo" add file
git -C "$repo" commit -q -m two
second="$(git -C "$repo" rev-parse HEAD)"
"$ROOT/scripts/upstream-index.sh" resolve --packages "$tmp/packages" --gtk gnome --out "$tmp/resolved2.tsv"
awk -F '\t' '$1 == "demo" { print $4 }' "$tmp/resolved2.tsv" | grep -qx "$second"
# Editing the wrap changes inputs, not only the resolved commit.
inputs1="$(awk -F '\t' '$1 == "demo" { print $5 }' "$tmp/resolved.tsv")"
echo '# edited' >> "$tmp/packages/demo/demo.wrap"
"$ROOT/scripts/upstream-index.sh" resolve --packages "$tmp/packages" --gtk gnome --out "$tmp/resolved3.tsv"
inputs3="$(awk -F '\t' '$1 == "demo" { print $5 }' "$tmp/resolved3.tsv")"
[ "$inputs1" != "$inputs3" ]

order="$tmp/build-order.txt"
printf '%s\n' openssl glib gtk > "$order"
cat > "$tmp/resolved-plan.tsv" << 'EOF'
openssl	file	openssl.tar.gz	hasho	inputso
glib	git	2.90.0	hashg	inputsg
gtk	git	android-ime	hashi	inputsi
EOF
prev="$tmp/prev.json"
"$ROOT/scripts/upstream-index.sh" write \
  --list <(printf '%s\n' \
    $'openssl\topenssl.tar.gz\thasho\tinputso\thttps://example.invalid/old/openssl.tar.xz' \
    $'glib\t2.90.0\thashg\tinputsg\thttps://example.invalid/old/glib.tar.xz' \
    $'gtk\tandroid-ime\thash-old\tinputsi\thttps://example.invalid/old/gtk.tar.xz') \
  --abi arm64-v8a --arch aarch64 --gtk gnome --created 2026-11-01T00:00:00Z --out "$prev"

"$ROOT/scripts/upstream-index.sh" plan \
  --resolved "$tmp/resolved-plan.tsv" \
  --previous "$prev" \
  --build-order "$order" \
  --gtk Knowles.android-ime \
  --out "$tmp/plan.tsv"
grep -q '^# publish=1$' "$tmp/plan.tsv"
grep -q '^# build=1$' "$tmp/plan.tsv"
grep -q '^# gtk_target=Knowles.android-ime$' "$tmp/plan.tsv"
awk -F '\t' '$2 == "openssl" && $1 == "keep" && $7 == "https://example.invalid/old/openssl.tar.xz"' "$tmp/plan.tsv" | grep -q .
awk -F '\t' '$2 == "gtk" && $1 == "build"' "$tmp/plan.tsv" | grep -q .

# Identical identities are not a release.
"$ROOT/scripts/upstream-index.sh" plan \
  --resolved <(printf '%s\n' \
    $'openssl\tfile\topenssl.tar.gz\thasho\tinputso' \
    $'glib\tgit\t2.90.0\thashg\tinputsg' \
    $'gtk\tgit\tandroid-ime\thash-old\tinputsi') \
  --previous "$prev" \
  --build-order "$order" \
  --gtk Knowles.android-ime \
  --out "$tmp/same.tsv"
grep -q '^# publish=0$' "$tmp/same.tsv"
grep -q '^# build=0$' "$tmp/same.tsv"

"$ROOT/scripts/upstream-index.sh" assemble \
  --plan "$tmp/plan.tsv" \
  --built <(printf '%s\n' $'gtk\thttps://example.invalid/new/gtk.tar.xz') \
  --abi arm64-v8a --arch aarch64 --gtk gnome \
  --created 2026-11-07T00:00:00Z \
  --out "$tmp/index.json"
grep -q 'https://example.invalid/old/openssl.tar.xz' "$tmp/index.json"
grep -q 'https://example.invalid/new/gtk.tar.xz' "$tmp/index.json"
grep -q '"gtk_target": "gnome"' "$tmp/index.json"
grep -q 'gitlab.gnome.org/GNOME/gtk.git' "$tmp/index.json"
grep -q '"gtk_track": "ae709f962a51f9108a1e6381bcfbd05bbaecc840"' "$tmp/index.json"
if grep -q 'https://example.invalid/old/gtk.tar.xz' "$tmp/index.json"; then
  echo "changed gtk kept the previous URL" >&2
  exit 1
fi

# Dropping a package publishes an index and no tarball.
printf '%s\n' openssl glib > "$tmp/shorter-order"
"$ROOT/scripts/upstream-index.sh" plan \
  --resolved <(printf '%s\n' \
    $'openssl\tfile\topenssl.tar.gz\thasho\tinputso' \
    $'glib\tgit\t2.90.0\thashg\tinputsg') \
  --previous "$prev" \
  --build-order "$tmp/shorter-order" \
  --gtk Knowles.android-ime \
  --out "$tmp/drop.tsv"
grep -q '^# publish=1$' "$tmp/drop.tsv"
grep -q '^# build=0$' "$tmp/drop.tsv"

abi=arm64-v8a
pkg="$tmp/frag"
mkdir -p "$pkg/lib/$abi/pkgconfig" "$tmp/java/org/gtk/android"
printf '%s\n' 'prefix=/' 'Name: glib' 'Version: 2.90.0' > "$pkg/lib/$abi/pkgconfig/glib-2.0.pc"
printf 'class T {}\n' > "$tmp/java/org/gtk/android/ToplevelActivity.java"
"$ROOT/scripts/pixie-tree.sh" pack-fragment --destdir "$pkg" --abi "$abi" --tarball "$tmp/glib.tar.xz"
rm -rf "$pkg"
mkdir -p "$pkg/lib/$abi/pkgconfig"
printf '%s\n' 'prefix=/' 'Name: gtk4' 'Version: 4.0.0' > "$pkg/lib/$abi/pkgconfig/gtk4.pc"
"$ROOT/scripts/pixie-tree.sh" pack-fragment \
  --destdir "$pkg" --abi "$abi" --tarball "$tmp/gtk.tar.xz" --java-glue "$tmp/java"

"$ROOT/scripts/upstream-index.sh" write \
  --list <(printf '%s\n' \
    "glib"$'\t'"2.90.0"$'\t'"hashg"$'\t'"inputsg"$'\t'"$tmp/glib.tar.xz" \
    "gtk"$'\t'"android-ime"$'\t'"hashi"$'\t'"inputsi"$'\t'"$tmp/gtk.tar.xz") \
  --abi "$abi" --arch aarch64 --gtk gnome --created 2026-11-07T00:00:00Z \
  --out "$tmp/local-index.json"
grep -q '"version": "1.261107"' "$tmp/local-index.json"

"$ROOT/scripts/upstream-index.sh" write \
  --list <(printf '%s\n' \
    "openssl"$'\t'"3.0.8"$'\t'"hasho"$'\t'"inputso"$'\t'"$tmp/glib.tar.xz") \
  --abi "$abi" --arch aarch64 --gtk gnome --created deps-libxml2 \
  --out "$tmp/deps-index.json"
grep -q '"version": "deps-libxml2"' "$tmp/deps-index.json"
grep -q '"created": "deps-libxml2"' "$tmp/deps-index.json"

"$ROOT/scripts/pixie.sh" pin "$tmp/local-index.json" --dest "$tmp/sysroot"
grep -q "^prefix=$tmp/sysroot$" "$tmp/sysroot/lib/$abi/pkgconfig/glib-2.0.pc"
grep -q "^prefix=$tmp/sysroot$" "$tmp/sysroot/lib/$abi/pkgconfig/gtk4.pc"
grep -q '"gtk_target": "gnome"' "$tmp/sysroot/share/pixiewood/MANIFEST.json"
test -f "$tmp/sysroot/share/pixiewood/INDEX.json"
test -f "$tmp/sysroot/share/pixiewood/gtk-android-java/org/gtk/android/ToplevelActivity.java"

"$ROOT/scripts/pixie.sh" pin "$tmp/local-index.json" --dest "$tmp/sysroot-glib" --exclude gtk
test -f "$tmp/sysroot-glib/lib/$abi/pkgconfig/glib-2.0.pc"
if [ -f "$tmp/sysroot-glib/lib/$abi/pkgconfig/gtk4.pc" ]; then
  echo "exclude gtk still extracted gtk" >&2
  exit 1
fi

{
  printf '%s\n' '# publish=1' '# build=1' '# gtk_target=Knowles.android-ime'
  while IFS= read -r name || [ -n "$name" ]; do
    name=${name%%#*}
    name=${name#"${name%%[![:space:]]*}"}
    name=${name%"${name##*[![:space:]]}"}
    [ -n "$name" ] || continue
    if [ "$name" = gtk ]; then
      printf 'build\tgtk\tgit\tandroid-ime\thashi\tinputsi\t-\n'
    else
      printf 'keep\t%s\tfile\t%s\thash\tinputs\thttps://example.invalid/old/%s.tar.xz\n' \
        "$name" "$name" "$name"
    fi
  done < "$ROOT/build-order.txt"
} > "$tmp/full-plan.tsv"
"$ROOT/scripts/build-changed.sh" \
  --plan "$tmp/full-plan.tsv" \
  --arch aarch64 \
  --gtk Knowles.android-ime \
  --tarball-dir "$tmp/out" \
  --dry-run > "$tmp/dry"
grep -qx 'build gtk' "$tmp/dry"
if grep -qx 'build openssl' "$tmp/dry"; then
  echo "dry-run built an unchanged package" >&2
  exit 1
fi
grep -qx 'dep gtk openssl https://example.invalid/old/openssl.tar.xz' "$tmp/dry"
if awk '$1 == "dep" && $2 == "gtk" && $3 == "gtk" { found = 1 } END { exit !found }' "$tmp/dry"; then
  echo "gtk listed itself as a dependency" >&2
  exit 1
fi

mkdir -p "$tmp/bin" "$tmp/tb"
cat > "$tmp/bin/gh" << 'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1" = release ] && [ "$2" = view ]; then
  exit 1
fi
exit 0
EOF
chmod +x "$tmp/bin/gh"
: > "$tmp/gh.log"
# Nothing to publish.
GH_LOG="$tmp/gh.log" PATH="$tmp/bin:$PATH" \
  "$ROOT/scripts/publish-index.sh" \
  --plan "$tmp/same.tsv" \
  --tarball-dir "$tmp/tb" \
  --arch aarch64 \
  --gtk Knowles.android-ime \
  --created 2026-11-07T00:00:00Z \
  --out "$tmp/unused.json"
if [ -s "$tmp/gh.log" ]; then
  echo "publish ran gh when nothing changed" >&2
  exit 1
fi

printf 'not a real package\n' > "$tmp/tb/gtk-arm64-v8a.tar.xz"
: > "$tmp/gh.log"
mkdir -p "$tmp/out"
(
  cd "$tmp"
  GH_LOG="$tmp/gh.log" PATH="$tmp/bin:$PATH" \
    "$ROOT/scripts/publish-index.sh" \
    --plan "$tmp/plan.tsv" \
    --tarball-dir "$tmp/tb" \
    --arch aarch64 \
    --gtk gnome \
    --repo roojs/pixiewood-pkgs \
    --created 2026-11-07T00:00:00Z \
    --out out/published.json
)
grep -q 'release create 1.261107' "$tmp/gh.log"
if grep -q '1.261107.tgz' "$tmp/gh.log"; then
  echo "publish wrote a release archive" >&2
  exit 1
fi
grep -q 'gtk-arm-v31-snapshot.pixie' "$tmp/gh.log"
grep -q 'out/published.json' "$tmp/gh.log"
grep -q 'release create latest' "$tmp/gh.log"
if grep -q 'openssl-arm64-v8a.tar.xz' "$tmp/gh.log"; then
  echo "unchanged openssl was uploaded" >&2
  exit 1
fi
grep -q 'https://github.com/roojs/pixiewood-pkgs/releases/download/1.261107/gtk-arm-v31-snapshot.pixie' "$tmp/out/published.json"
grep -q '"version": "1.261107"' "$tmp/out/published.json"
grep -q 'https://example.invalid/old/openssl.tar.xz' "$tmp/out/published.json"

# release.pins is the package list for the build that is publishing.
openssl_url="$(jq -r '.packages[] | select(.abi == "arm64-v8a" and .repo == "https://gitlab.gnome.org/GNOME/gtk.git" and .name == "openssl") | .url' "$ROOT/release.pins")"
openssl_release="$(printf '%s\n' "$openssl_url" | sed -n 's|.*/releases/download/\(1\.[0-9][0-9]*\)/.*|\1|p')"
[ -n "$openssl_release" ]
case "$openssl_url" in
  "https://github.com/roojs/pixiewood-pkgs/releases/download/${openssl_release}/openssl-arm-v31-3.0.8.pixie"|\
  "https://github.com/roojs/pixiewood-pkgs/releases/download/${openssl_release}/openssl-arm64-v8a-v31-3.0.8.pixie"|\
  "https://github.com/roojs/pixiewood-pkgs/releases/download/${openssl_release}/openssl-arm64-v8a-android31-3.0.8.pixie"|\
  "https://github.com/roojs/pixiewood-pkgs/releases/download/${openssl_release}/openssl-arm64-v8a-android31-gnome.pixie"|\
  "https://github.com/roojs/pixiewood-pkgs/releases/download/${openssl_release}/openssl-arm64-v8a-gnome.pixie"|\
  "https://github.com/roojs/pixiewood-pkgs/releases/download/${openssl_release}/openssl-arm64-v8a-gnome.tar.xz") ;;
  *) echo "openssl pin URL is $openssl_url" >&2; exit 1 ;;
esac
if grep -q 'Knowles.android-ime' "$ROOT/release.pins" "$ROOT/snapshot.pins" "$ROOT/packages/gtk/targets" "$ROOT/build-order.txt"; then
  echo "the IME target is still in this distribution" >&2
  exit 1
fi
if grep -q 'webkitgtk-android' "$ROOT/release.pins" "$ROOT/snapshot.pins" "$ROOT/build-order.txt" "$ROOT/packages/probes"; then
  echo "webkitgtk-android is still in this distribution" >&2
  exit 1
fi
if grep -q 'index-.*\.json' "$ROOT/release.pins" "$ROOT/snapshot.pins"; then
  echo "a pin file points at an index instead of package tarballs" >&2
  exit 1
fi
"$ROOT/scripts/current-pins.sh" index --abi arm64-v8a --gtk gnome --out "$tmp/pins-index.json"
index_release="1.${openssl_release:2:6}"
grep -q "\"version\": \"$index_release\"" "$tmp/pins-index.json"
grep -q "$(basename "$openssl_url")" "$tmp/pins-index.json"
if grep -q 'webkitgtk-android' "$tmp/pins-index.json"; then
  echo "gnome index still lists webkitgtk-android" >&2
  exit 1
fi

{
  printf '%s\n' '# publish=1' '# gtk_target=gnome'
  printf '%s\n' $'build\tgtk\tgit\tgnome-rev\tgtkr\tgtk-in\t-'
} > "$tmp/gnome-webkit.tsv"
{
  printf '%s\n' '# publish=1' '# gtk_target=Knowles.android-ime'
  printf '%s\n' $'build\tgtk\tgit\tandroid-ime\time-gtk\tgtk-in\t-'
} > "$tmp/ime-gtk.tsv"
"$ROOT/scripts/current-pins.sh" write \
  --file "$tmp/owner-pins" \
  --arch aarch64 \
  --created 2026-11-08T00:00:00Z \
  --repo roojs/pixiewood-pkgs \
  --plan "$tmp/gnome-webkit.tsv" \
  --plan "$tmp/ime-gtk.tsv"
jq -e '.packages[] | select(.abi == "arm64-v8a" and .repo == "Knowles.android-ime" and .name == "gtk" and (.url | contains("/1.261108/")))' "$tmp/owner-pins" >/dev/null
if jq -e '.packages[] | select(.name == "gdk")' "$tmp/owner-pins" >/dev/null; then
  echo "written pins still name gdk" >&2
  exit 1
fi
if grep -q 'webkitgtk-android' "$tmp/owner-pins"; then
  echo "written pins still name webkitgtk-android" >&2
  exit 1
fi

hdr="$tmp/android-headers"
mkdir -p "$hdr/gdk/android"
printf '%s\n' "pixiewood_part = get_option('pixiewood-part')" > "$hdr/meson.build"
printf '%s\n' "option('x', type: 'boolean', value: false)" > "$hdr/meson.options"
cat > "$hdr/gdk/android/meson.build" << 'EOF'
gdk_android_public_headers = files([
  'gdkandroiddevice.h'
])
install_headers(gdk_android_public_headers, 'gdkandroid.h', subdir: 'gtk-4.0/gdk/android/')
EOF
printf '%s\n' \
  '#include <gdk/android/gdkandroiddevice.h>' \
  '#include <gdk/android/gdkandroidcontentfile.h>' \
  > "$hdr/gdk/android/gdkandroid.h"
printf '%s\n' 'header' > "$hdr/gdk/android/gdkandroidcontentfile.h"
"$ROOT/scripts/gtk-part.sh" patch "$hdr"
grep -q "'gdkandroiddevice.h'," "$hdr/gdk/android/meson.build"
grep -q "'gdkandroidcontentfile.h'" "$hdr/gdk/android/meson.build"
"$ROOT/scripts/gtk-part.sh" patch "$hdr"
if [ "$(grep -c gdkandroidcontentfile.h "$hdr/gdk/android/meson.build")" -ne 1 ]; then
  echo "android content file header was installed twice" >&2
  exit 1
fi

{
  printf '%s\n' '# publish=1' '# gtk_target=gnome'
  printf 'keep\topenssl\tfile\t3.0.8\thasho\tinputso\thttps://example.invalid/old/openssl.tar.xz\n'
  printf 'build\tgtk\tgit\tandroid-ime\thashi\tinputsi\t-\n'
} > "$tmp/keep-plan.tsv"
"$ROOT/scripts/current-pins.sh" write \
  --file "$tmp/pins" \
  --arch aarch64 \
  --created 2026-11-08T00:00:00Z \
  --repo roojs/pixiewood-pkgs \
  --plan "$tmp/keep-plan.tsv"
jq '.packages += [{abi:"x86_64", repo:"x86_64", name:"glib", track:"2.90.0", resolved:"hashg", inputs:"inputsg", url:"https://example.invalid/glib.tar.xz"}]' "$tmp/pins" > "$tmp/pins.x86"
mv "$tmp/pins.x86" "$tmp/pins"
"$ROOT/scripts/current-pins.sh" write \
  --file "$tmp/pins" \
  --arch aarch64 \
  --created 2026-11-08T00:00:00Z \
  --repo roojs/pixiewood-pkgs \
  --plan "$tmp/keep-plan.tsv"
jq -e '.packages[] | select(.abi == "arm64-v8a" and .repo == "https://gitlab.gnome.org/GNOME/gtk.git" and .name == "openssl" and .track == "3.0.8" and .url == "https://example.invalid/old/openssl.tar.xz")' "$tmp/pins" >/dev/null
jq -e '.packages[] | select(.abi == "arm64-v8a" and .name == "gtk" and .track == "android-ime" and (.url | endswith("gtk-arm-v31-snapshot.pixie")))' "$tmp/pins" >/dev/null
jq -e '.packages[] | select(.abi == "x86_64" and .repo == "x86_64" and .name == "glib")' "$tmp/pins" >/dev/null

if grep -q 'tgz' "$ROOT/.gitattributes"; then
  echo "gitattributes names a generated release archive" >&2
  exit 1
fi
grep -qx '/release.pins !export-ignore' "$ROOT/.gitattributes"
grep -qx '/snapshot.pins !export-ignore' "$ROOT/.gitattributes"
if jq -e 'any(.packages[]; has("release"))' "$ROOT/release.pins" >/dev/null \
  || jq -e 'any(.packages[]; has("release"))' "$ROOT/snapshot.pins" >/dev/null; then
  echo "a pin still stores release" >&2
  exit 1
fi
if jq -e '.packages[] | select(.url | endswith("-snapshot.pixie"))' "$ROOT/release.pins" >/dev/null; then
  echo "release.pins names a snapshot" >&2
  exit 1
fi
if jq -e '.packages[] | select(.url | endswith("-snapshot.pixie") | not)' "$ROOT/snapshot.pins" >/dev/null; then
  echo "snapshot.pins names a release" >&2
  exit 1
fi

attr_work="$(mktemp -d)"
attr_index="$(mktemp)"
cp "$ROOT/.gitattributes" "$attr_work/.gitattributes"
printf 'list\n' > "$attr_work/release.pins"
printf 'list\n' > "$attr_work/snapshot.pins"
printf 'no\n' > "$attr_work/README.md"
GIT_INDEX_FILE="$attr_index" git -C "$ROOT" read-tree --empty
GIT_INDEX_FILE="$attr_index" git -C "$ROOT" --work-tree="$attr_work" add -- .gitattributes release.pins snapshot.pins README.md
attr_tree="$(GIT_INDEX_FILE="$attr_index" git -C "$ROOT" write-tree)"
rm -f "$attr_index"
git -C "$ROOT" archive "$attr_tree" | tar -t > "$tmp/source-archive.txt"
grep -qx 'release.pins' "$tmp/source-archive.txt"
grep -qx 'snapshot.pins' "$tmp/source-archive.txt"
if grep -q 'README.md\|.gitattributes' "$tmp/source-archive.txt"; then
  echo "source archive kept more than the pin files" >&2
  cat "$tmp/source-archive.txt" >&2
  exit 1
fi

echo "index: ok"
