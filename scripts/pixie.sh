#!/usr/bin/env bash
# Download pixie libraries and unpack them into one directory.
# latest reads release.pins. --snapshot reads snapshot.pins. pin uses one index file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=pixie-common.sh
source "$ROOT/scripts/pixie-common.sh"
# shellcheck source=upstream-index.sh
source "$ROOT/scripts/upstream-index.sh"

usage() {
  echo "Usage: $0 latest --dest DIR [--gtk TARGET] [--abi ABI] [--arch aarch64|x86_64] [--repo OWNER/NAME] [--index-url URL] [--snapshot]" >&2
  echo "       $0 pin INDEX --dest DIR [--exclude PACKAGE ...]" >&2
  exit 2
}

fetch_url() {
  local url=$1 dest=$2
  case "$url" in
    http://*|https://*|file://*)
      curl -fsSL "$url" -o "$dest"
      ;;
    *)
      cp "$url" "$dest"
      ;;
  esac
}

mode=${1:-}
shift || usage

dest=""
gtk="${GTK_TARGET:-gnome}"
abi=""
arch=""
repo="${GITHUB_REPOSITORY:-roojs/pixiewood-pkgs}"
index_url=""
index_file=""
pins_file=""
declare -A skip=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dest) dest=$2; shift 2 ;;
    --gtk) gtk=$2; shift 2 ;;
    --abi) abi=$2; shift 2 ;;
    --arch) arch=$2; shift 2 ;;
    --repo) repo=$2; shift 2 ;;
    --index-url) index_url=$2; shift 2 ;;
    --snapshot) pins_file="$ROOT/snapshot.pins"; shift ;;
    --exclude) skip[$2]=1; shift 2 ;;
    *)
      if [ "$mode" = pin ] && [ -z "$index_file" ]; then
        index_file=$1
        shift
      else
        echo "Unknown argument: $1" >&2
        usage
      fi
      ;;
  esac
done

if [ -z "$dest" ]; then
  usage
fi
if [ -e "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null || true)" ]; then
  echo "Destination is not empty: $dest" >&2
  exit 1
fi
mkdir -p "$dest"
dest="$(cd "$dest" && pwd)"

case "$mode" in
  latest)
    if [ -n "$arch" ] && [ -z "$abi" ]; then
      abi="$(sysroot_map "$ROOT/cross/abi" "$arch")"
    fi
    abi="${abi:-arm64-v8a}"
    index_file="$(mktemp)"
    if [ -n "$index_url" ]; then
      fetch_url "$index_url" "$index_file"
    else
      index_args=(index --abi "$abi" --gtk "$gtk" --out "$index_file")
      if [ -n "$pins_file" ]; then
        index_args+=(--file "$pins_file")
      fi
      "$ROOT/scripts/current-pins.sh" "${index_args[@]}"
    fi
    ;;
  pin)
    if [ -z "$index_file" ]; then
      usage
    fi
    case "$index_file" in
      http://*|https://*|file://*)
        tmp="$(mktemp)"
        fetch_url "$index_file" "$tmp"
        index_file=$tmp
        ;;
    esac
    if [ ! -f "$index_file" ]; then
      echo "Index not found: $index_file" >&2
      exit 1
    fi
    ;;
  *)
    usage
    ;;
esac

index_gtk="$(sysroot_json_get gtk_target "$index_file")"
if [ "$mode" = latest ] && [ "$index_gtk" != "$gtk" ]; then
  echo "Index gtk_target is $index_gtk, expected $gtk" >&2
  exit 1
fi

count=0
while IFS=$'\t' read -r name track resolved inputs url; do
  [ -n "$name" ] || continue
  if [ -n "${skip[$name]:-}" ]; then
    continue
  fi
  archive="$(mktemp --suffix=.tar.xz)"
  fetch_url "$url" "$archive"
  tar -C "$dest" -xJf "$archive"
  rm -f "$archive"
  count=$((count + 1))
done < <(index_packages "$index_file")

if [ "$count" -eq 0 ]; then
  echo "Index has no packages to extract" >&2
  exit 1
fi

mkdir -p "$dest/share/pixiewood"
cp "$index_file" "$dest/share/pixiewood/INDEX.json"

provided="$(mktemp)"
index_packages "$index_file" | while IFS=$'\t' read -r name _rest; do
  if [ -z "${skip[$name]:-}" ]; then
    printf '%s\n' "$name"
  fi
done > "$provided"

gtk_revision="$(sysroot_json_get gtk_track "$index_file")"
pkg_resolved="$(index_packages "$index_file" | awk -F '\t' '$1 == "gtk" { print $3; exit }')"
if [ -n "$pkg_resolved" ]; then
  gtk_revision=$pkg_resolved
fi

"$ROOT/scripts/pixie-tree.sh" seal \
  --destdir "$dest" \
  --version "$(sysroot_json_get version "$index_file")" \
  --abi "$(sysroot_json_get abi "$index_file")" \
  --arch "$(sysroot_json_get arch "$index_file")" \
  --api "$(sysroot_json_get api "$index_file")" \
  --ndk "$(sysroot_json_get ndk "$index_file")" \
  --pixiewood-revision "$(sysroot_json_get pixiewood_revision "$index_file")" \
  --gtk-target "$index_gtk" \
  --gtk-url "$(sysroot_json_get gtk_url "$index_file")" \
  --gtk-revision "$gtk_revision" \
  --provided "$provided"

"$ROOT/scripts/pixie-tree.sh" activate "$dest"
echo "Unpacked $count packages into $dest"
