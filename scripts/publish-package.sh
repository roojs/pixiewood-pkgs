#!/usr/bin/env bash
# Upload one finished package and record its pin.
# The next package can fail. This package stays on the release, and the next
# run downloads it instead of building it again.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=upstream-index.sh
source "$ROOT/scripts/upstream-index.sh"
# shellcheck source=sysroot-common.sh
source "$ROOT/scripts/sysroot-common.sh"

name=""
tarball=""
arch=""
gtk=""
track=""
resolved=""
inputs=""
created=""
repo="${GITHUB_REPOSITORY:-roojs/pixiewood-pkgs}"
file=""
upload=1
commit=0

usage() {
  echo "Usage: $0 --name NAME --tarball FILE --arch ARCH --gtk TARGET --track TRACK --resolved REV --inputs HASH [--created STAMP] [--repo OWNER/NAME] [--file PATH] [--no-upload] [--commit]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name) name=$2; shift 2 ;;
    --tarball) tarball=$2; shift 2 ;;
    --arch) arch=$2; shift 2 ;;
    --gtk) gtk=$2; shift 2 ;;
    --track) track=$2; shift 2 ;;
    --resolved) resolved=$2; shift 2 ;;
    --inputs) inputs=$2; shift 2 ;;
    --created) created=$2; shift 2 ;;
    --repo) repo=$2; shift 2 ;;
    --file) file=$2; shift 2 ;;
    --no-upload) upload=0; shift ;;
    --commit) commit=1; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

if [ -z "$name" ] || [ -z "$tarball" ] || [ -z "$arch" ] || [ -z "$gtk" ] || [ -z "$track" ] || [ -z "$resolved" ] || [ -z "$inputs" ]; then
  usage
fi
if [ ! -f "$tarball" ]; then
  echo "Package tarball missing: $tarball" >&2
  exit 1
fi
if ! abi="$(sysroot_map "$ROOT/cross/abi" "$arch")"; then
  exit 2
fi
file="${file:-$ROOT/current.pins}"
created="${created:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
tag="$(release_version "$created")" || exit 1
label="$(package_pin_label "$name" "$gtk" "$repo")"
asset="${name}-${abi}-${label}.pixie"
url="https://github.com/${repo}/releases/download/${tag}/${asset}"

if [ "$upload" -eq 1 ]; then
  stage="$(mktemp -d)"
  cp -a "$tarball" "$stage/$asset"
  if gh release view "$tag" --repo "$repo" >/dev/null 2>&1 </dev/null; then
    gh release upload "$tag" "$stage/$asset" --repo "$repo" --clobber </dev/null
  else
    create=(release create "$tag" "$stage/$asset" --repo "$repo" --title "$tag" --notes "Packages completed in this run." --latest=false)
    target="${RELEASE_SHA:-${GITHUB_SHA:-}}"
    if [ -n "$target" ]; then
      create+=(--target "$target")
    fi
    gh "${create[@]}" </dev/null
  fi
  rm -rf "$stage"
fi

tmp="$(mktemp)"
if [ ! -f "$file" ]; then
  printf '%s\n' '# abi gtk release name track resolved inputs url' > "$file"
fi
awk -F '\t' -v OFS='\t' \
  -v abi="$abi" -v label="$label" -v name="$name" \
  -v release="$tag" -v track="$track" -v resolved="$resolved" \
  -v inputs="$inputs" -v url="$url" '
  $1 == abi && $2 == label && $4 == name {
    print abi, label, release, name, track, resolved, inputs, url
    found = 1
    next
  }
  { print }
  END {
    if (!found) print abi, label, release, name, track, resolved, inputs, url
  }
' "$file" > "$tmp"
mv "$tmp" "$file"

if [ "$commit" -eq 1 ] && [ "$file" = "$ROOT/current.pins" ]; then
  git -C "$ROOT" add -- current.pins
  if ! git -C "$ROOT" diff --cached --quiet -- current.pins; then
    git -C "$ROOT" commit -m "Publish ${name} to ${tag}" </dev/null
    ref="${GITHUB_REF_NAME:-}"
    if [ -n "$ref" ]; then
      if ! git -C "$ROOT" push origin "HEAD:${ref}" </dev/null; then
        git -C "$ROOT" pull --rebase origin "$ref" </dev/null
        git -C "$ROOT" push origin "HEAD:${ref}" </dev/null
      fi
    fi
  fi
fi

echo "Published $name $tag"
echo "$url"
