#!/usr/bin/env bash
# Prove packages in build order.
# Each package is the release pin when that recipe is unchanged, otherwise
# a tarball in the package cache, and otherwise a source build.
# PROVE_PUBLISH=1 uploads each finished package before the next one starts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=sysroot-common.sh
source "$ROOT/scripts/sysroot-common.sh"
# shellcheck source=upstream-index.sh
source "$ROOT/scripts/upstream-index.sh"

arch="${ARCH:-aarch64}"
gtk="${GTK_TARGET:-gnome}"
packages=""
through=""
out=""
cache=""
pins=""
dry=0
check=""
package_name=""

usage() {
  echo "Usage: $0 [--arch aarch64|x86_64] [--gtk TARGET] [--through PACKAGE] [--packages NAMES] [--cache DIR] [--pins FILE] [--out DIR] [--dry-run]" >&2
  echo "       $0 --check TARBALL --package NAME [--arch aarch64|x86_64]" >&2
  echo "The default proves every package from the start of build-order.txt through gtk." >&2
  echo "A package is taken from the release pins, then the package cache, then source." >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --arch) arch=$2; shift 2 ;;
    --gtk) gtk=$2; shift 2 ;;
    --packages) packages=$2; shift 2 ;;
    --through) through=$2; shift 2 ;;
    --cache) cache=$2; shift 2 ;;
    --pins) pins=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --check) check=$2; shift 2 ;;
    --package) package_name=$2; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

if ! abi="$(sysroot_map "$ROOT/cross/abi" "$arch")"; then
  exit 2
fi

probe_fields() {
  local name=$1
  awk -v name="$name" '
    $1 !~ /^#/ && $1 == name {
      for (i = 2; i <= NF; i++) if ($i != "+subproject") print $i
      found = 1
    }
    END { exit !found }
  ' "$ROOT/packages/probes"
}

prove_tarball() {
  local tarball=$1 abi=$2 name=$3 listing pc lib meta want other foreign
  if [ ! -f "$tarball" ]; then
    echo "Package tarball missing: $tarball" >&2
    return 1
  fi
  listing="$(mktemp)"
  tar -tJf "$tarball" > "$listing"
  if ! want="$(probe_fields "$name")"; then
    echo "No probe for $name" >&2
    rm -f "$listing"
    return 1
  fi
  # A probe name is either a pkg-config file (glib-2.0.pc, openssl.pc)
  # or the installed library (libssl.so).
  pc=""
  lib=""
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    local found=""
    found="$(grep -E "^(\./)?lib/${abi}/pkgconfig/${token}\.pc$" "$listing" | head -n1 || true)"
    if [ -n "$found" ] && [ -z "$pc" ]; then
      pc="$found"
    fi
    if [ -z "$found" ]; then
      found="$(grep -E "^(\./)?lib/${abi}/${token}\.(so|a)(\.|$)" "$listing" | head -n1 || true)"
    fi
    if [ -z "$found" ]; then
      found="$(grep -E "^(\./)?lib/${abi}/lib${token}\.(so|a)(\.|$)" "$listing" | head -n1 || true)"
    fi
    if [ -z "$found" ]; then
      found="$(grep -E "^(\./)?lib/${abi}/gio/modules/lib${token}\.(so|a)(\.|$)" "$listing" | head -n1 || true)"
    fi
    if [ -z "$found" ]; then
      echo "$name tarball has no pkg-config file or library for ${token}" >&2
      grep -E "^(\./)?lib/${abi}/" "$listing" | sed 's|^\./||' | head -n 40 >&2 || true
      rm -f "$listing"
      return 1
    fi
    case "$found" in
      *.pc) ;;
      *) [ -z "$lib" ] && lib="$found" ;;
    esac
  done <<< "$want"
  while read -r other rest; do
    [ -n "${other:-}" ] || continue
    case "$other" in \#*) continue ;; esac
    [ "$other" = "$name" ] && continue
    for foreign in $rest; do
      [ "$foreign" = "+subproject" ] && continue
      if grep -E -q "^(\./)?lib/${abi}/pkgconfig/${foreign}\.pc$" "$listing"; then
        echo "$name tarball contains ${foreign}.pc from $other" >&2
        rm -f "$listing"
        return 1
      fi
    done
  done < "$ROOT/packages/probes"
  if [ "$name" != glib ] && grep -E -q '(^|/)gdbus-codegen$' "$listing"; then
    echo "$name tarball contains gdbus-codegen from a nested GLib" >&2
    rm -f "$listing"
    return 1
  fi
  if [ -z "$lib" ]; then
    lib="$(grep -E "^(\./)?lib/${abi}/(gio/modules/)?lib[^/]+\.(so|a)(\.|$)" "$listing" | head -n1 || true)"
  fi
  rm -f "$listing"
  if [ -z "$lib" ]; then
    echo "No library under lib/${abi} in $tarball" >&2
    return 1
  fi
  meta=""
  if [ -n "$pc" ]; then
    meta="$(tar -xJf "$tarball" -O "$pc" | awk -F ': ' '/^(Name|Version):/ { printf "%s ", $2 }')"
  fi
  lib="${lib#./}"
  echo "proved ${name}: ${meta}(${lib})"
}

if [ -n "$check" ]; then
  [ -n "$package_name" ] || { echo "--check needs --package" >&2; exit 2; }
  prove_tarball "$check" "$abi" "$package_name"
  exit 0
fi

if [ -n "$packages" ] && [ -n "$through" ]; then
  echo "Pass --packages or --through, not both" >&2
  exit 2
fi
if [ -z "$packages" ] && [ -z "$through" ]; then
  through=gtk
fi

if [ -z "$out" ]; then
  out="$ROOT/out/prove"
fi
if [ -z "$pins" ]; then
  pins="$ROOT/current.pins"
fi

declare -A order_at=()
order_names=()
position=0
while IFS= read -r name || [ -n "$name" ]; do
  name=${name%%#*}
  name=${name#"${name%%[![:space:]]*}"}
  name=${name%"${name##*[![:space:]]}"}
  [ -n "$name" ] || continue
  order_at[$name]=$position
  order_names+=("$name")
  position=$((position + 1))
done < "$ROOT/build-order.txt"

names=()
if [ -n "$through" ]; then
  if [ -z "${order_at[$through]+x}" ]; then
    echo "Unknown package: $through" >&2
    exit 1
  fi
  for name in "${order_names[@]}"; do
    names+=("$name")
    [ "$name" = "$through" ] && break
  done
else
  IFS=',' read -ra raw_names <<< "$packages"
  previous=-1
  for part in "${raw_names[@]}"; do
    part="${part#"${part%%[![:space:]]*}"}"
    part="${part%"${part##*[![:space:]]}"}"
    if [ -z "$part" ]; then
      echo "Empty package name in --packages" >&2
      exit 1
    fi
    if [ -z "${order_at[$part]+x}" ]; then
      echo "Unknown package: $part" >&2
      exit 1
    fi
    if [ "${order_at[$part]}" -le "$previous" ]; then
      echo "$part is earlier in build-order.txt than the package before it" >&2
      exit 1
    fi
    previous=${order_at[$part]}
    names+=("$part")
  done
fi
if [ "${#names[@]}" -eq 0 ]; then
  echo "No packages to prove" >&2
  exit 1
fi

mkdir -p "$out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

declare -A inputs_of=() resolved_of=() track_of=()
if [ "$dry" -eq 0 ]; then
  "$ROOT/scripts/upstream-index.sh" resolve --gtk "$gtk" --out "$work/resolved.tsv"
  while IFS=$'\t' read -r name _kind track resolved inputs; do
    [ -n "$name" ] || continue
    track_of[$name]=$track
    resolved_of[$name]=$resolved
    inputs_of[$name]=$inputs
  done < "$work/resolved.tsv"
fi

list="$work/proved.tsv"
: > "$list"
deps=""
proved=()
if [ "${PROVE_PUBLISH:-}" = 1 ] && [ -z "${PROVE_CREATED:-}" ]; then
  PROVE_CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

for name in "${names[@]}"; do
  tarball="$out/${name}-${abi}.tar.xz"
  obtain_args=(
    --name "$name"
    --abi "$abi"
    --gtk "$gtk"
    --pins "$pins"
  )
  if [ -n "$cache" ]; then
    obtain_args+=(--cache "$cache")
  fi
  if [ "$dry" -eq 0 ]; then
    obtain_args+=(--resolved "${resolved_of[$name]:-}" --inputs "${inputs_of[$name]:-}")
  fi
  decision="$("$ROOT/scripts/obtain-package.sh" "${obtain_args[@]}")"
  IFS=$'\t' read -r kind loc <<< "$decision"
  if [ "${#proved[@]}" -eq 0 ]; then
    echo "$kind $name alone"
  else
    echo "$kind $name on ${proved[*]}"
  fi
  if [ "$dry" -eq 0 ]; then
    if [ "$kind" = pin ]; then
      if ! curl -fsSL "$loc" -o "$tarball"; then
        echo "Release pin for $name did not download" >&2
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
        if [ "${#proved[@]}" -eq 0 ]; then
          echo "$kind $name alone"
        else
          echo "$kind $name on ${proved[*]}"
        fi
      fi
    fi
    if [ "$kind" = cache ]; then
      cp -a "$loc" "$tarball"
    fi
    if [ "$kind" != build ]; then
      if ! prove_tarball "$tarball" "$abi" "$name"; then
        echo "$name from $kind is not a usable package; building it" >&2
        if [ "$kind" = cache ] && [ -n "$cache" ]; then
          rm -f "$cache/$abi/$name.tar.xz" "$cache/$abi/$name.inputs"
        fi
        rm -f "$tarball"
        kind=build
      fi
    fi
    if [ "$kind" = build ]; then
      args=(--only "$name" --arch "$arch" --gtk "$gtk" --tarball "$tarball")
      if [ -n "$deps" ]; then
        args+=(--deps-sysroot "$deps")
      fi
      "$ROOT/scripts/build-sysroot.sh" "${args[@]}"
      if [ -n "$cache" ]; then
        mkdir -p "$cache/$abi"
        cp -a "$tarball" "$cache/$abi/$name.tar.xz"
        printf '%s\n' "${inputs_of[$name]}" > "$cache/$abi/$name.inputs"
      fi
      prove_tarball "$tarball" "$abi" "$name"
    fi
    publish_this=0
    if [ "${PROVE_PUBLISH:-}" = 1 ]; then
      publish_this=1
      # A pin whose URL is already this SDK's asset stays where it is.
      if [ "$kind" = pin ]; then
        asset="$(package_asset_name "$name" "$abi" "$(package_release_label "${track_of[$name]:-}" "$tarball" "$abi" "$name")")"
        case "$loc" in
          */"$asset") publish_this=0 ;;
        esac
      fi
    fi
    if [ "$publish_this" -eq 1 ]; then
      "$ROOT/scripts/publish-package.sh" \
        --name "$name" \
        --tarball "$tarball" \
        --arch "$arch" \
        --gtk "$gtk" \
        --track "${track_of[$name]:-}" \
        --resolved "${resolved_of[$name]:-}" \
        --inputs "${inputs_of[$name]:-}" \
        --created "${PROVE_CREATED:-}" \
        --commit
    fi
  fi
  proved+=("$name")
  if [ "$dry" -eq 1 ]; then
    continue
  fi
  printf '%s\tproof\tproof\tproof\t%s\n' "$name" "$tarball" >> "$list"
  next="$work/deps-$name"
  rm -rf "$next"
  "$ROOT/scripts/upstream-index.sh" write \
    --list "$list" \
    --abi "$abi" \
    --arch "$arch" \
    --gtk "$gtk" \
    --created "prove-$name" \
    --out "$work/deps-$name.json"
  "$ROOT/scripts/integrate-sysroot.sh" pin "$work/deps-$name.json" --dest "$next"
  deps="$next"
done
