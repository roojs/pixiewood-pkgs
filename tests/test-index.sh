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

# shellcheck source=../scripts/sysroot-common.sh
source "$ROOT/scripts/sysroot-common.sh"
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
[ "$openssl_probe" = "libssl libcrypto" ]
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

"$ROOT/scripts/upstream-index.sh" resolve --packages "$tmp/packages" --gtk Knowles.android-ime --out "$tmp/resolved.tsv"
awk -F '\t' '$1 == "demo" { print $4 }' "$tmp/resolved.tsv" | grep -qx "$first"
awk -F '\t' '$1 == "filepkg" { print $4 }' "$tmp/resolved.tsv" | grep -qx aaaa
awk -F '\t' '$1 == "pinned" { print $4 }' "$tmp/resolved.tsv" | grep -qx 0123456789abcdef0123456789abcdef01234567

echo two > "$repo/file"
git -C "$repo" add file
git -C "$repo" commit -q -m two
second="$(git -C "$repo" rev-parse HEAD)"
"$ROOT/scripts/upstream-index.sh" resolve --packages "$tmp/packages" --gtk Knowles.android-ime --out "$tmp/resolved2.tsv"
awk -F '\t' '$1 == "demo" { print $4 }' "$tmp/resolved2.tsv" | grep -qx "$second"
# Editing the wrap changes inputs, not only the resolved commit.
inputs1="$(awk -F '\t' '$1 == "demo" { print $5 }' "$tmp/resolved.tsv")"
echo '# edited' >> "$tmp/packages/demo/demo.wrap"
"$ROOT/scripts/upstream-index.sh" resolve --packages "$tmp/packages" --gtk Knowles.android-ime --out "$tmp/resolved3.tsv"
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
  --abi arm64-v8a --arch aarch64 --gtk Knowles.android-ime --created 2026-11-01T00:00:00Z --out "$prev"

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
  --abi arm64-v8a --arch aarch64 --gtk Knowles.android-ime \
  --created 2026-11-07T00:00:00Z \
  --out "$tmp/index.json"
grep -q 'https://example.invalid/old/openssl.tar.xz' "$tmp/index.json"
grep -q 'https://example.invalid/new/gtk.tar.xz' "$tmp/index.json"
grep -q '"gtk_target": "Knowles.android-ime"' "$tmp/index.json"
grep -q 'Knowles/gtk.git' "$tmp/index.json"
grep -q '"gtk_track": "android-ime"' "$tmp/index.json"
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
"$ROOT/scripts/sysroot-tree.sh" pack-fragment --destdir "$pkg" --abi "$abi" --tarball "$tmp/glib.tar.xz"
rm -rf "$pkg"
mkdir -p "$pkg/lib/$abi/pkgconfig"
printf '%s\n' 'prefix=/' 'Name: gtk4' 'Version: 4.0.0' > "$pkg/lib/$abi/pkgconfig/gtk4.pc"
"$ROOT/scripts/sysroot-tree.sh" pack-fragment \
  --destdir "$pkg" --abi "$abi" --tarball "$tmp/gtk.tar.xz" --java-glue "$tmp/java"

"$ROOT/scripts/upstream-index.sh" write \
  --list <(printf '%s\n' \
    "glib"$'\t'"2.90.0"$'\t'"hashg"$'\t'"inputsg"$'\t'"$tmp/glib.tar.xz" \
    "gtk"$'\t'"android-ime"$'\t'"hashi"$'\t'"inputsi"$'\t'"$tmp/gtk.tar.xz") \
  --abi "$abi" --arch aarch64 --gtk Knowles.android-ime --created 2026-11-07T00:00:00Z \
  --out "$tmp/local-index.json"

"$ROOT/scripts/integrate-sysroot.sh" pin "$tmp/local-index.json" --dest "$tmp/sysroot"
grep -q "^prefix=$tmp/sysroot$" "$tmp/sysroot/lib/$abi/pkgconfig/glib-2.0.pc"
grep -q "^prefix=$tmp/sysroot$" "$tmp/sysroot/lib/$abi/pkgconfig/gtk4.pc"
grep -q '"gtk_target": "Knowles.android-ime"' "$tmp/sysroot/share/pixiewood/MANIFEST.json"
test -f "$tmp/sysroot/share/pixiewood/INDEX.json"
test -f "$tmp/sysroot/share/pixiewood/gtk-android-java/org/gtk/android/ToplevelActivity.java"

"$ROOT/scripts/integrate-sysroot.sh" pin "$tmp/local-index.json" --dest "$tmp/sysroot-glib" --exclude gtk
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
GH_LOG="$tmp/gh.log" PATH="$tmp/bin:$PATH" \
  "$ROOT/scripts/publish-index.sh" \
  --plan "$tmp/plan.tsv" \
  --tarball-dir "$tmp/tb" \
  --arch aarch64 \
  --gtk Knowles.android-ime \
  --repo roojs/pixiewood-pkgs \
  --created 2026-11-07T00:00:00Z \
  --out "$tmp/published.json"
grep -q 'release create 1.261107' "$tmp/gh.log"
grep -q '1.261107.tgz' "$tmp/gh.log"
grep -q 'gtk-arm64-v8a-Knowles.android-ime.tar.xz' "$tmp/gh.log"
tar -tzf "$tmp/1.261107.tgz" > "$tmp/release-list.txt"
grep -qx 'index-arm64-v8a-Knowles.android-ime.json' "$tmp/release-list.txt"
if grep -q '\.tar\.xz$' "$tmp/release-list.txt"; then
  echo "release file contains a package tarball" >&2
  exit 1
fi
grep -q 'release create latest' "$tmp/gh.log"
if grep -q 'openssl-arm64-v8a.tar.xz' "$tmp/gh.log"; then
  echo "unchanged openssl was uploaded" >&2
  exit 1
fi
grep -q 'https://github.com/roojs/pixiewood-pkgs/releases/download/1.261107/gtk-arm64-v8a-Knowles.android-ime.tar.xz' "$tmp/published.json"
grep -q '"version": "1.261107"' "$tmp/published.json"
grep -q 'https://example.invalid/old/openssl.tar.xz' "$tmp/published.json"

# current.pins is the download list, and the source archive contains only that file.
gnome_url="$("$ROOT/scripts/current-pins.sh" url --abi arm64-v8a --gtk gnome)"
ime_url="$("$ROOT/scripts/current-pins.sh" url --abi arm64-v8a --gtk Knowles.android-ime)"
grep -qx "arm64-v8a gnome 1.261107 $gnome_url" "$ROOT/current.pins"
grep -qx "arm64-v8a Knowles.android-ime 1.261107 $ime_url" "$ROOT/current.pins"
if grep -q 'tgz' "$ROOT/.gitattributes"; then
  echo "gitattributes names a generated release archive" >&2
  exit 1
fi
grep -qx '/current.pins !export-ignore' "$ROOT/.gitattributes"
"$ROOT/scripts/current-pins.sh" write \
  --file "$tmp/pins" \
  --arch aarch64 \
  --created 2026-11-08T00:00:00Z \
  --repo roojs/pixiewood-pkgs \
  --gtk gnome
printf '%s\n' 'x86_64 x86_64 1.261107 https://example.invalid/x86_64.json' >> "$tmp/pins"
"$ROOT/scripts/current-pins.sh" write \
  --file "$tmp/pins" \
  --arch aarch64 \
  --created 2026-11-08T00:00:00Z \
  --repo roojs/pixiewood-pkgs \
  --gtk gnome
grep -qx 'arm64-v8a gnome 1.261108 https://github.com/roojs/pixiewood-pkgs/releases/download/1.261108/index-arm64-v8a-gnome.json' "$tmp/pins"
grep -qx 'x86_64 x86_64 1.261107 https://example.invalid/x86_64.json' "$tmp/pins"
[ "$("$ROOT/scripts/current-pins.sh" url --file "$tmp/pins" --abi x86_64 --gtk x86_64)" = "https://example.invalid/x86_64.json" ]

attr_work="$(mktemp -d)"
attr_index="$(mktemp)"
cp "$ROOT/.gitattributes" "$attr_work/.gitattributes"
cp "$ROOT/current.pins" "$attr_work/current.pins"
printf 'no\n' > "$attr_work/README.md"
GIT_INDEX_FILE="$attr_index" git -C "$ROOT" read-tree --empty
GIT_INDEX_FILE="$attr_index" git -C "$ROOT" --work-tree="$attr_work" add -- .gitattributes current.pins README.md
attr_tree="$(GIT_INDEX_FILE="$attr_index" git -C "$ROOT" write-tree)"
rm -f "$attr_index"
git -C "$ROOT" archive "$attr_tree" | tar -t > "$tmp/source-archive.txt"
grep -qx 'current.pins' "$tmp/source-archive.txt"
if grep -q 'README.md\|.gitattributes' "$tmp/source-archive.txt"; then
  echo "source archive kept more than current.pins" >&2
  cat "$tmp/source-archive.txt" >&2
  exit 1
fi

echo "index: ok"
