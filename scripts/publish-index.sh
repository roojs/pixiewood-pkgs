#!/usr/bin/env bash
# Publish changed package tarballs and an index.
# If the plan says nothing changed, this exits without creating a release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=upstream-index.sh
source "$ROOT/scripts/upstream-index.sh"
# shellcheck source=sysroot-common.sh
source "$ROOT/scripts/sysroot-common.sh"

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
notes="Release file ${tag}.tgz is the package list for ${gtk}. Package tarballs are separate assets named in that list. GitHub also attaches a source archive of this repository; that is not the release."
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
  printf '%s\thttps://github.com/%s/releases/download/%s/%s-%s-%s.tar.xz\n' \
    "$name" "$repo" "$tag" "$name" "$abi" "$gtk" >> "$built"
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

list="$(mktemp -d)"
cp "$out" "$list/$asset"
pkgs="$(mktemp -d)"
while IFS=$'\t' read -r name _url; do
  [ -n "$name" ] || continue
  cp "$tarball_dir/${name}-${abi}.tar.xz" "$pkgs/${name}-${abi}-${gtk}.tar.xz"
done < "$built"

# A later target on the same day adds its list. The archive stays a list.
prev="$(mktemp -d)"
if gh release download "$tag" --repo "$repo" --pattern "${tag}.tgz" --dir "$prev" >/dev/null 2>&1 \
  && [ -f "$prev/${tag}.tgz" ]; then
  old="$prev/old"
  mkdir -p "$old"
  tar -C "$old" -xzf "$prev/${tag}.tgz"
  while IFS= read -r rel; do
    case "$rel" in
      *.json) ;;
      *) continue ;;
    esac
    if [ ! -e "$list/$rel" ]; then
      mkdir -p "$list/$(dirname "$rel")"
      cp "$old/$rel" "$list/$rel"
    fi
  done < <(cd "$old" && find . -type f -printf '%P\n')
fi
archive="$(dirname "$out")/${tag}.tgz"
(
  cd "$list"
  tar -czf "$archive" -- *
)
args=("$archive" "$list/$asset")
while IFS=$'\t' read -r name _url; do
  [ -n "$name" ] || continue
  args+=("$pkgs/${name}-${abi}-${gtk}.tar.xz")
done < "$built"
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  gh release upload "$tag" "${args[@]}" --repo "$repo" --clobber
else
  create=(release create "$tag" "${args[@]}" --repo "$repo" --title "$tag" --notes "$notes" --latest=false)
  if [ -n "${GITHUB_SHA:-}" ]; then
    create+=(--target "$GITHUB_SHA")
  fi
  gh "${create[@]}"
fi

if gh release view latest --repo "$repo" >/dev/null 2>&1; then
  gh release upload latest "$list/$asset" --repo "$repo" --clobber
else
  gh release create latest "$list/$asset" --repo "$repo" \
    --title "Latest Android sysroot indexes" \
    --notes "Current indexes. Unchanged packages point at earlier releases." \
    --latest
fi
gh release edit latest --repo "$repo" --latest >/dev/null 2>&1 || true
echo "Published $tag"
