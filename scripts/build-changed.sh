#!/usr/bin/env bash
# Build only the packages a plan marks as changed, against the kept tarballs.
# A kept file is reused only while it still downloads. A deleted release means
# that file is gone, so the package is built.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=upstream-index.sh
source "$ROOT/scripts/upstream-index.sh"
# shellcheck source=pixie-common.sh
source "$ROOT/scripts/pixie-common.sh"
# shellcheck source=require-pixie.sh
source "$ROOT/scripts/require-pixie.sh"

plan=""
arch="${ARCH:-aarch64}"
gtk="${GTK_TARGET:-gnome}"
tarball_dir=""
cache=""
dry=0
missing_only=0
skip_missing=0

usage() {
  echo "Usage: $0 --plan FILE [--arch aarch64|x86_64] [--gtk TARGET] --tarball-dir DIR [--cache DIR] [--dry-run] [--missing-only] [--skip-missing-check]" >&2
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
    --missing-only) missing_only=1; shift ;;
    --skip-missing-check) skip_missing=1; shift ;;
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

# A published URL is not proof the file is still there.
published_present() {
  local got=$1 code attempt tries
  case "$got" in
    http://*|https://*)
      # 404 means the release file was removed. A 5xx or a network error does not.
      tries="${PUBLISHED_CHECK_TRIES:-5}"
      code=000
      for ((attempt = 1; attempt <= tries; attempt++)); do
        code="$(curl -sS -o /dev/null -w '%{http_code}' -L -r 0-0 "$got" || true)"
        case "$code" in
          200|206) return 0 ;;
          404|410) return 1 ;;
        esac
        if [ "$attempt" -lt "$tries" ]; then
          sleep 2
        fi
      done
      echo "Could not check $got (HTTP $code); leaving the published file in place" >&2
      return 0
      ;;
    file://*)
      [ -s "${got#file://}" ]
      ;;
    /*)
      [ -s "$got" ]
      ;;
    *)
      return 1
      ;;
  esac
}

if [ "$dry" -eq 0 ] && [ "$skip_missing" -eq 0 ]; then
  declare -A gone=()
  flipped=0
  for name in "${order[@]}"; do
    [ "${status[$name]}" = keep ] || continue
    if ! published_present "${url[$name]:-}"; then
      echo "Published file for $name is gone; building it" >&2
      gone[$name]=1
      flipped=1
    fi
  done
  if [ "$flipped" -eq 1 ]; then
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        '# build='*) printf '# build=1\n' >> "$tmp"; continue ;;
        '# publish='*) printf '# publish=1\n' >> "$tmp"; continue ;;
        '#'*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        '') continue ;;
      esac
      IFS=$'\t' read -r st nm kd tr rs inn u <<< "$line"
      if [ -n "${gone[$nm]:-}" ]; then
        status[$nm]=build
        url[$nm]='-'
        printf 'build\t%s\t%s\t%s\t%s\t%s\t-\n' "$nm" "$kd" "$tr" "$rs" "$inn" >> "$tmp"
      else
        printf '%s\n' "$line" >> "$tmp"
      fi
    done < "$plan"
    mv "$tmp" "$plan"
  fi
fi
if [ "$missing_only" -eq 1 ]; then
  exit 0
fi

mkdir -p "$tarball_dir"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for name in "${order[@]}"; do
  [ "${status[$name]}" = build ] || continue
  list="$work/deps.tsv"
  : > "$list"
  dep_count=0
  for other in "${order[@]}"; do
    [ "$other" = "$name" ] && break
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
    require_pixie
    pixie-pkg fetch --dest "$deps" --pins "$index" --abi "$abi"
    args+=(--deps-sysroot "$deps")
  fi
  "$ROOT/scripts/build-pixie.sh" "${args[@]}"
  built[$name]="$tarball_dir/${name}-${abi}.tar.xz"
  if [ -n "$cache" ]; then
    mkdir -p "$cache/$abi"
    cp -a "${built[$name]}" "$cache/$abi/$name.tar.xz"
    printf '%s\n' "${inputs[$name]}" > "$cache/$abi/$name.inputs"
  fi
done
