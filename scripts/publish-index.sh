#!/usr/bin/env bash
# Publish changed package tarballs and an index.
# If the plan says nothing changed, this exits without creating a release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=upstream-index.sh
source "$ROOT/scripts/upstream-index.sh"

plan=""
tarball_dir=""
arch=""
gtk=""
repo="${GITHUB_REPOSITORY:-roojs/pixiewood-pkgs}"
created=""
out=""

usage() {
  echo "Usage: $0 --plan FILE --tarball-dir DIR --arch ARCH --gtk TARGET [--repo OWNER/NAME] [--created STAMP] [--out INDEX]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan) plan=$2; shift 2 ;;
    --tarball-dir) tarball_dir=$2; shift 2 ;;
    --arch) arch=$2; shift 2 ;;
    --gtk) gtk=$2; shift 2 ;;
    --repo) repo=$2; shift 2 ;;
    --created) created=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

if [ -z "$plan" ] || [ -z "$tarball_dir" ] || [ -z "$arch" ] || [ -z "$gtk" ]; then
  usage
fi

publish="$(sed -n 's/^# publish=//p' "$plan" | head -n1)"
if [ "$publish" != 1 ]; then
  echo "Nothing changed; not publishing."
  exit 0
fi

case "$arch" in
  aarch64) abi=arm64-v8a ;;
  x86_64) abi=x86_64 ;;
  *)
    echo "Unsupported arch: $arch" >&2
    exit 2
    ;;
esac

created="${created:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
stamp="$(printf '%s' "$created" | tr -d ':-')"
tag="index-${gtk}-${stamp}"
asset="index-${abi}-${gtk}.json"
out="${out:-$tarball_dir/$asset}"

built="$(mktemp)"
: > "$built"
notes="Android sysroot index for GTK target ${gtk}."
changed=""
while IFS=$'\t' read -r status name _kind _track _resolved _inputs _url; do
  [ -n "${status:-}" ] || continue
  case "$status" in \#*) continue ;; esac
  [ "$status" = build ] || continue
  tarball="$tarball_dir/${name}-${abi}.tar.xz"
  if [ ! -f "$tarball" ]; then
    echo "Missing tarball: $tarball" >&2
    exit 1
  fi
  printf '%s\thttps://github.com/%s/releases/download/%s/%s-%s.tar.xz\n' \
    "$name" "$repo" "$tag" "$name" "$abi" >> "$built"
  changed="${changed} ${name}"
done < "$plan"
if [ -n "$changed" ]; then
  notes="${notes} New packages:${changed}."
else
  notes="${notes} Package set changed; no new tarballs."
fi

"$ROOT/scripts/upstream-index.sh" assemble \
  --plan "$plan" \
  --built "$built" \
  --abi "$abi" \
  --arch "$arch" \
  --gtk "$gtk" \
  --created "$created" \
  --out "$out"

stage="$(mktemp -d)"
cp "$out" "$stage/$asset"
while IFS=$'\t' read -r name _url; do
  [ -n "$name" ] || continue
  cp "$tarball_dir/${name}-${abi}.tar.xz" "$stage/${name}-${abi}.tar.xz"
done < "$built"

args=(release create "$tag" "$stage/$asset")
while IFS=$'\t' read -r name _url; do
  [ -n "$name" ] || continue
  args+=("$stage/${name}-${abi}.tar.xz")
done < "$built"
args+=(--repo "$repo" --title "Android sysroot index ${gtk} ${created}" --notes "$notes" --latest=false)
if [ -n "${GITHUB_SHA:-}" ]; then
  args+=(--target "$GITHUB_SHA")
fi
gh "${args[@]}"

if gh release view latest --repo "$repo" >/dev/null 2>&1; then
  gh release upload latest "$stage/$asset" --repo "$repo" --clobber
else
  gh release create latest "$stage/$asset" --repo "$repo" \
    --title "Latest Android sysroot indexes" \
    --notes "Current indexes. Unchanged packages point at earlier releases." \
    --latest
fi
gh release edit latest --repo "$repo" --latest >/dev/null 2>&1 || true
echo "Published $tag"
