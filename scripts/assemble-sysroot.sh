#!/usr/bin/env bash
# Assemble one Android sysroot.
# Each package comes from release.pins, then the package cache, then source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=sysroot-common.sh
source "$ROOT/scripts/sysroot-common.sh"

arch="${ARCH:-aarch64}"
gtk="${GTK_TARGET:-gnome}"
jobs="${JOBS:-$(nproc)}"
cache="${PIXIEWOOD_PACKAGE_CACHE:-$ROOT/.cache/packages}"
pins="$ROOT/release.pins"
out=""

usage() {
  echo "Usage: $0 [--arch aarch64|x86_64] [--gtk TARGET] [--jobs N] [--cache DIR] [--pins FILE] [--out DIR]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --arch) arch=$2; shift 2 ;;
    --gtk) gtk=$2; shift 2 ;;
    --jobs) jobs=$2; shift 2 ;;
    --cache) cache=$2; shift 2 ;;
    --pins) pins=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

if ! abi="$(sysroot_map "$ROOT/cross/abi" "$arch")"; then
  exit 2
fi
if [ -z "$out" ]; then
  out="$ROOT/out/assemble-$gtk-$abi"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$out" "$cache/$abi"

"$ROOT/scripts/upstream-index.sh" resolve --gtk "$gtk" --out "$work/resolved.tsv"
declare -A kind_of=() resolved_of=() inputs_of=()
while IFS=$'\t' read -r name kind _track resolved inputs; do
  [ -n "$name" ] || continue
  kind_of[$name]=$kind
  resolved_of[$name]=$resolved
  inputs_of[$name]=$inputs
done < "$work/resolved.tsv"

list="$work/packages.tsv"
: > "$list"
deps=""

take_tarball() {
  local kind=$1 loc=$2 dest=$3
  case "$kind" in
    pin)
      curl -fsSL "$loc" -o "$dest" || return 1
      ;;
    cache)
      cp -a "$loc" "$dest"
      ;;
    *)
      return 1
      ;;
  esac
}

while IFS= read -r name || [ -n "$name" ]; do
  name=${name%%#*}
  name=${name#"${name%%[![:space:]]*}"}
  name=${name%"${name##*[![:space:]]}"}
  [ -n "$name" ] || continue
  tarball="$out/${name}-${abi}.tar.xz"
  decision="$("$ROOT/scripts/obtain-package.sh" \
    --name "$name" \
    --abi "$abi" \
    --gtk "$gtk" \
    --cache "$cache" \
    --pins "$pins" \
    --resolved "${resolved_of[$name]:-}" \
    --inputs "${inputs_of[$name]:-}")"
  IFS=$'\t' read -r kind loc <<< "$decision"
  echo "$kind $name"
  if [ "$kind" != build ]; then
    if ! take_tarball "$kind" "$loc" "$tarball"; then
      echo "Could not use the $kind tarball for $name" >&2
      rm -f "$tarball"
      fallback="$("$ROOT/scripts/obtain-package.sh" \
        --name "$name" \
        --abi "$abi" \
        --gtk "$gtk" \
        --cache "$cache" \
        --pins /dev/null \
        --resolved "${resolved_of[$name]:-}" \
        --inputs "${inputs_of[$name]:-}")"
      IFS=$'\t' read -r kind loc <<< "$fallback"
      echo "$kind $name"
      if [ "$kind" = cache ]; then
        cp -a "$loc" "$tarball"
      fi
    fi
  fi
  if [ "$kind" = build ]; then
    args=(--only "$name" --arch "$arch" --gtk "$gtk" --jobs "$jobs" --tarball "$tarball")
    if [ "${kind_of[$name]:-}" = git ] && [ -n "${resolved_of[$name]:-}" ]; then
      args+=(--resolved "${resolved_of[$name]}")
    fi
    if [ -n "$deps" ]; then
      args+=(--deps-sysroot "$deps")
    fi
    "$ROOT/scripts/build-sysroot.sh" "${args[@]}"
    cp -a "$tarball" "$cache/$abi/$name.tar.xz"
    printf '%s\n' "${inputs_of[$name]}" > "$cache/$abi/$name.inputs"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$name" "${resolved_of[$name]:-proof}" "${resolved_of[$name]:-proof}" "${inputs_of[$name]:-proof}" "$tarball" >> "$list"
  next="$work/deps-$name"
  rm -rf "$next"
  "$ROOT/scripts/upstream-index.sh" write \
    --list "$list" \
    --abi "$abi" \
    --arch "$arch" \
    --gtk "$gtk" \
    --created "assemble-$name" \
    --out "$work/deps-$name.json"
  "$ROOT/scripts/pixie.sh" pin "$work/deps-$name.json" --dest "$next"
  deps="$next"
done < "$ROOT/build-order.txt"

final="$out/sysroot"
rm -rf "$final"
"$ROOT/scripts/upstream-index.sh" write \
  --list "$list" \
  --abi "$abi" \
  --arch "$arch" \
  --gtk "$gtk" \
  --created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --out "$work/final.json"
"$ROOT/scripts/pixie.sh" pin "$work/final.json" --dest "$final"
"$ROOT/scripts/verify-sysroot.sh" "$final"
archive="$ROOT/out/pixiewood-android-${gtk}-${abi}.tar.xz"
mkdir -p "$ROOT/out"
tar -C "$final" -cJf "$archive" .
echo "Wrote $archive"
