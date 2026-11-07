#!/usr/bin/env bash
# Build only the packages a plan marks as changed, against the kept tarballs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=upstream-index.sh
source "$ROOT/scripts/upstream-index.sh"
# shellcheck source=sysroot-common.sh
source "$ROOT/scripts/sysroot-common.sh"

plan=""
arch="${ARCH:-aarch64}"
gtk="${GTK_TARGET:-gnome}"
tarball_dir=""
cache=""
dry=0

usage() {
  echo "Usage: $0 --plan FILE [--arch aarch64|x86_64] [--gtk TARGET] --tarball-dir DIR [--cache DIR] [--dry-run]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan) plan=$2; shift 2 ;;
    --arch) arch=$2; shift 2 ;;
    --gtk) gtk=$2; shift 2 ;;
    --tarball-dir) tarball_dir=$2; shift 2 ;;
    --cache) cache=$2; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

if [ -z "$plan" ] || [ -z "$tarball_dir" ]; then
  usage
fi

if ! abi="$(sysroot_map "$ROOT/cross/abi" "$arch")"; then
  exit 2
fi

declare -A status=() kind=() track=() resolved=() inputs=() url=()
declare -A built=()
order=()
while IFS= read -r name || [ -n "$name" ]; do
  name=${name%%#*}
  name=${name#"${name%%[![:space:]]*}"}
  name=${name%"${name##*[![:space:]]}"}
  [ -n "$name" ] || continue
  order+=("$name")
done < "$ROOT/build-order.txt"

while IFS=$'\t' read -r st name kd tr rs inn u; do
  [ -n "${st:-}" ] || continue
  case "$st" in \#*) continue ;; esac
  status[$name]=$st
  kind[$name]=$kd
  track[$name]=$tr
  resolved[$name]=$rs
  inputs[$name]=$inn
  url[$name]=$u
done < "$plan"

for name in "${order[@]}"; do
  if [ -z "${status[$name]:-}" ]; then
    echo "Plan is missing $name" >&2
    exit 1
  fi
done

mkdir -p "$tarball_dir"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for name in "${order[@]}"; do
  [ "${status[$name]}" = build ] || continue
  list="$work/deps.tsv"
  : > "$list"
  dep_count=0
  for other in "${order[@]}"; do
    [ "$other" = "$name" ] && continue
    dep_url=""
    if [ -n "${built[$other]:-}" ]; then
      dep_url="${built[$other]}"
    elif [ "${status[$other]}" = keep ]; then
      dep_url="${url[$other]}"
    else
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$other" "${track[$other]}" "${resolved[$other]}" "${inputs[$other]}" "$dep_url" >> "$list"
    dep_count=$((dep_count + 1))
    if [ "$dry" -eq 1 ]; then
      if [ -n "${built[$other]:-}" ]; then
        echo "dep $name $other new"
      else
        echo "dep $name $other $dep_url"
      fi
    fi
  done
  if [ -n "$cache" ] && [ -f "$cache/$abi/$name.tar.xz" ] && [ -f "$cache/$abi/$name.inputs" ] \
    && [ "$(cat "$cache/$abi/$name.inputs")" = "${inputs[$name]}" ]; then
    echo "cache $name"
    if [ "$dry" -eq 1 ]; then
      built[$name]="$cache/$abi/$name.tar.xz"
      continue
    fi
    cp -a "$cache/$abi/$name.tar.xz" "$tarball_dir/${name}-${abi}.tar.xz"
    built[$name]="$tarball_dir/${name}-${abi}.tar.xz"
    continue
  fi
  echo "build $name"
  if [ "$dry" -eq 1 ]; then
    built[$name]="new"
    continue
  fi
  args=(--only "$name" --arch "$arch" --gtk "$gtk" --tarball "$tarball_dir/${name}-${abi}.tar.xz")
  if [ "${kind[$name]}" = git ]; then
    args+=(--resolved "${resolved[$name]}")
  fi
  if [ "$dep_count" -gt 0 ]; then
    deps="$work/deps-$name"
    rm -rf "$deps"
    mkdir -p "$deps"
    index="$work/deps-$name.json"
    "$ROOT/scripts/upstream-index.sh" write \
      --list "$list" \
      --abi "$abi" \
      --arch "$arch" \
      --gtk "$gtk" \
      --created "deps-$name" \
      --out "$index"
    "$ROOT/scripts/integrate-sysroot.sh" pin "$index" --dest "$deps"
    args+=(--deps-sysroot "$deps")
  fi
  "$ROOT/scripts/build-sysroot.sh" "${args[@]}"
  built[$name]="$tarball_dir/${name}-${abi}.tar.xz"
  if [ -n "$cache" ]; then
    mkdir -p "$cache/$abi"
    cp -a "${built[$name]}" "$cache/$abi/$name.tar.xz"
    printf '%s\n' "${inputs[$name]}" > "$cache/$abi/$name.inputs"
  fi
done
