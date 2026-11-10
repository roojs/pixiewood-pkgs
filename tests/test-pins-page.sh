#!/usr/bin/env bash
# The pin lists are published on the project GitHub Pages site.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bash -n "$ROOT/scripts/pins-page.sh"

row() {
  local name=$1 track=$2
  jq -n --arg name "$name" --arg track "$track" '{
    packages: [{
      abi: "arm64-v8a",
      repo: "https://gitlab.gnome.org/GNOME/gtk.git",
      name: $name,
      track: $track,
      resolved: $track,
      inputs: "inputs",
      url: ("https://example.invalid/" + $name + ".pixie")
    }]
  }'
}

site="$tmp/site"
work="$tmp/work"
mkdir -p "$site" "$work"
row openssl old > "$site/release.pins"
row fontconfig old-snap > "$site/snapshot.pins"
row openssl git > "$work/release.pins"
row fontconfig git-snap > "$work/snapshot.pins"

"$ROOT/scripts/pins-page.sh" fetch --dest "$work" --url "file://${site}"
jq -e '.packages[0].track == "old"' "$work/release.pins" >/dev/null
jq -e '.packages[0].track == "old-snap"' "$work/snapshot.pins" >/dev/null
jq -e '.packages[0].track == "old"' "$work/.pins-page-base/release.pins" >/dev/null

kept="$tmp/kept"
mkdir -p "$kept"
row openssl stay > "$kept/release.pins"
row fontconfig stay-snap > "$kept/snapshot.pins"
if "$ROOT/scripts/pins-page.sh" fetch --dest "$kept" --url "file://${tmp}/missing" >/dev/null 2>"$tmp/missing.err"; then
  :
fi
jq -e '.packages[0].track == "stay"' "$kept/release.pins" >/dev/null
jq -e '.packages[0].track == "stay-snap"' "$kept/snapshot.pins" >/dev/null

# This run changed openssl. The site has a newer fontconfig and a package this run does not have.
base="$tmp/merge"
localpins="$tmp/local"
remote="$tmp/remote"
mkdir -p "$base" "$localpins" "$remote" "$base/.pins-page-base"
jq -n '{packages: [
  {abi:"arm64-v8a", repo:"https://gitlab.gnome.org/GNOME/gtk.git", name:"openssl", track:"1", resolved:"1", inputs:"i", url:"https://example.invalid/openssl.pixie"},
  {abi:"arm64-v8a", repo:"https://gitlab.gnome.org/GNOME/gtk.git", name:"fontconfig", track:"1", resolved:"1", inputs:"i", url:"https://example.invalid/fontconfig.pixie"}
]}' > "$base/.pins-page-base/release.pins"
cp "$base/.pins-page-base/release.pins" "$base/release.pins"
jq -n '{packages: [
  {abi:"arm64-v8a", repo:"https://gitlab.gnome.org/GNOME/gtk.git", name:"openssl", track:"2", resolved:"2", inputs:"i", url:"https://example.invalid/openssl-2.pixie"},
  {abi:"arm64-v8a", repo:"https://gitlab.gnome.org/GNOME/gtk.git", name:"fontconfig", track:"1", resolved:"1", inputs:"i", url:"https://example.invalid/fontconfig.pixie"}
]}' > "$base/release.pins"
jq -n '{packages: [
  {abi:"arm64-v8a", repo:"https://gitlab.gnome.org/GNOME/gtk.git", name:"openssl", track:"1", resolved:"1", inputs:"i", url:"https://example.invalid/openssl.pixie"},
  {abi:"arm64-v8a", repo:"https://gitlab.gnome.org/GNOME/gtk.git", name:"fontconfig", track:"9", resolved:"9", inputs:"i", url:"https://example.invalid/fontconfig-9.pixie"},
  {abi:"arm64-v8a", repo:"https://gitlab.gnome.org/GNOME/gtk.git", name:"glib", track:"9", resolved:"9", inputs:"i", url:"https://example.invalid/glib.pixie"}
]}' > "$remote/release.pins"
cp "$site/snapshot.pins" "$base/snapshot.pins"
cp "$site/snapshot.pins" "$base/.pins-page-base/snapshot.pins"
cp "$site/snapshot.pins" "$remote/snapshot.pins"

"$ROOT/scripts/pins-page.sh" stage --dest "$base" --out "$localpins" --url "file://${remote}"
jq -e '.packages[] | select(.name == "openssl" and .track == "2")' "$localpins/release.pins" >/dev/null
jq -e '.packages[] | select(.name == "fontconfig" and .track == "9")' "$localpins/release.pins" >/dev/null
jq -e '.packages[] | select(.name == "glib" and .track == "9")' "$localpins/release.pins" >/dev/null
grep -q 'href="release.pins"' "$localpins/index.html"
grep -q 'href="snapshot.pins"' "$localpins/index.html"
grep -q 'released versions' "$localpins/index.html"
grep -q 'GTK HEAD' "$localpins/index.html"
grep -q '<th scope="col">Release</th>' "$localpins/index.html"
grep -q '<th scope="col">Snapshot</th>' "$localpins/index.html"
grep -q '<th scope="row">openssl</th><td><a href="https://example.invalid/openssl-2.pixie">2</a></td><td class="none">—</td>' "$localpins/index.html"
grep -q '<th scope="row">fontconfig</th>' "$localpins/index.html"
grep -q '>snapshot</a>' "$localpins/index.html"

offline="$tmp/offline"
mkdir -p "$offline"
row openssl local-only > "$work/release.pins"
"$ROOT/scripts/pins-page.sh" stage --dest "$work" --out "$offline" --url "file://${tmp}/missing"
jq -e '.packages[0].track == "local-only"' "$offline/release.pins" >/dev/null
[ -f "$offline/index.html" ]

named="$tmp/named"
named_out="$tmp/named-out"
mkdir -p "$named" "$named_out"
jq -n '{packages: [{
  abi:"arm64-v8a",
  repo:"https://gitlab.gnome.org/GNOME/gtk.git",
  name:"gtk",
  track:"ae709f962a51f9108a1e6381bcfbd05bbaecc840",
  resolved:"ae709f962a51f9108a1e6381bcfbd05bbaecc840",
  inputs:"i",
  url:"https://github.com/roojs/pixiewood-pkgs/releases/download/1.261109/gtk-arm-v31-4.24.1.pixie"
}]}' > "$named/release.pins"
jq -n '{packages:[]}' > "$named/snapshot.pins"
"$ROOT/scripts/pins-page.sh" stage --dest "$named" --out "$named_out" --url "file://${tmp}/missing"
grep -q '<th scope="row">gtk</th><td><a href="https://github.com/roojs/pixiewood-pkgs/releases/download/1.261109/gtk-arm-v31-4.24.1.pixie">4.24.1</a></td>' "$named_out/index.html"
grep -q 'newest release on that same version line' "$named_out/index.html"

if grep -q 'git add release.pins' "$ROOT/.github/workflows/prove-package.yml"; then
  echo "prove still commits the pin lists" >&2
  exit 1
fi
if grep -q -- '--commit' \
  "$ROOT/scripts/prove-package.sh" \
  "$ROOT/scripts/publish-package.sh" \
  "$ROOT/.github/workflows/monitor-upstreams.yml" \
  "$ROOT/.github/workflows/prove-package.yml"; then
  echo "a workflow still commits pin lists" >&2
  exit 1
fi
grep -q 'pins-page.sh fetch' "$ROOT/.github/workflows/prove-package.yml"
grep -q 'pins-page.sh stage' "$ROOT/.github/workflows/prove-package.yml"
grep -q 'deploy-pages' "$ROOT/.github/workflows/prove-package.yml"
grep -q 'pins-page.sh fetch' "$ROOT/.github/workflows/monitor-upstreams.yml"
grep -q 'pins-page.sh stage' "$ROOT/.github/workflows/monitor-upstreams.yml"
grep -q 'deploy-pages' "$ROOT/.github/workflows/monitor-upstreams.yml"

echo "pins page: ok"
