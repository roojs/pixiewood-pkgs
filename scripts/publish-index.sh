#!/usr/bin/env bash
# Publish changed package tarballs.
# If the plan says nothing changed, this exits without creating a release.
# The pin files in the worktree are the package lists. This does not upload an index.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=upstream-index.sh
source "$ROOT/scripts/upstream-index.sh"
# shellcheck source=pixie-common.sh
source "$ROOT/scripts/pixie-common.sh"

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

if ! abi="$(sysroot_map "$ROOT/cross/abi" "$arch")"; then
  exit 2
fi

created="${created:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
tag="$(release_version "$created")" || exit 1
asset="index-${abi}-${gtk}.json"
out="${out:-$tarball_dir/$asset}"

built="$(mktemp)"
: > "$built"
notes="Index for ${gtk}."
changed=""
while IFS=$'\t' read -r status name _kind track _resolved _inputs _url; do
  [ -n "${status:-}" ] || continue
  case "$status" in \#*) continue ;; esac
  [ "$status" = build ] || continue
  tarball="$tarball_dir/${name}-${abi}.tar.xz"
  if [ ! -f "$tarball" ]; then
    echo "Skipping $name; its tarball is not built yet" >&2
    continue
  fi
  pkg_asset="$(package_asset_name "$name" "$abi" "$(package_release_label "$track" "$tarball" "$abi" "$name")")"
  printf '%s\thttps://github.com/%s/releases/download/%s/%s\n' \
    "$name" "$repo" "$tag" "$pkg_asset" >> "$built"
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

pkgs="$(mktemp -d)"
args=()
while IFS=$'\t' read -r name built_url; do
  [ -n "$name" ] || continue
  asset_name="$(basename "$built_url")"
  cp "$tarball_dir/${name}-${abi}.tar.xz" "$pkgs/$asset_name"
  args+=("$pkgs/$asset_name")
done < "$built"
if [ "${#args[@]}" -eq 0 ]; then
  echo "No packages to upload."
  exit 0
fi
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  gh release upload "$tag" "${args[@]}" --repo "$repo" --clobber
else
  create=(release create "$tag" "${args[@]}" --repo "$repo" --title "$tag" --notes "$notes" --latest=false)
  target="${RELEASE_SHA:-${GITHUB_SHA:-}}"
  if [ -n "$target" ]; then
    create+=(--target "$target")
  fi
  gh "${create[@]}"
fi

echo "Published $tag"
