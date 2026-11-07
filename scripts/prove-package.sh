#!/usr/bin/env bash
# Prove packages in build order, reusing a cache of tarballs whose inputs
# have not changed. This does not publish. Monitor upstreams is the release path.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=sysroot-common.sh
source "$ROOT/scripts/sysroot-common.sh"

arch="${ARCH:-aarch64}"
gtk="${GTK_TARGET:-gnome}"
packages=""
through=""
out=""
cache=""
dry=0
check=""
package_name=""

usage() {
  echo "Usage: $0 [--arch aarch64|x86_64] [--gtk TARGET] [--through PACKAGE] [--packages NAMES] [--cache DIR] [--out DIR] [--dry-run]" >&2
  echo "       $0 --check TARBALL --package NAME [--arch aarch64|x86_64]" >&2
  echo "The default proves every package from the start of build-order.txt through gtk." >&2
  echo "A cached tarball is reused when its inputs hash still matches." >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --arch) arch=$2; shift 2 ;;
    --gtk) gtk=$2; shift 2 ;;
    --packages) packages=$2; shift 2 ;;
    --through) through=$2; shift 2 ;;
    --cache) cache=$2; shift 2 ;;
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
  pc=""
  while IFS= read -r want_pc; do
    [ -n "$want_pc" ] || continue
    if ! grep -E -q "^(\./)?lib/${abi}/pkgconfig/${want_pc}\.pc$" "$listing"; then
      echo "$name tarball is missing lib/${abi}/pkgconfig/${want_pc}.pc" >&2
      rm -f "$listing"
      return 1
    fi
    if [ -z "$pc" ]; then
      pc="$(grep -E "^(\./)?lib/${abi}/pkgconfig/${want_pc}\.pc$" "$listing" | head -n1)"
    fi
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
  lib="$(grep -E "^(\./)?lib/${abi}/lib[^/]+\.(so|a)(\.|$)" "$listing" | head -n1 || true)"
  rm -f "$listing"
  if [ -z "$lib" ]; then
    echo "No library under lib/${abi} in $tarball" >&2
    return 1
  fi
  meta="$(tar -xJf "$tarball" -O "$pc" | awk -F ': ' '/^(Name|Version):/ { printf "%s ", $2 }')"
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

declare -A inputs_of=()
if [ "$dry" -eq 0 ]; then
  "$ROOT/scripts/upstream-index.sh" resolve --gtk "$gtk" --out "$work/resolved.tsv"
  while IFS=$'\t' read -r name _kind _track _resolved inputs; do
    [ -n "$name" ] || continue
    inputs_of[$name]=$inputs
  done < "$work/resolved.tsv"
fi

cache_hit() {
  local name=$1 cached_tar cached_stamp
  [ -n "$cache" ] || return 1
  cached_tar="$cache/$abi/$name.tar.xz"
  cached_stamp="$cache/$abi/$name.inputs"
  [ -f "$cached_tar" ] || return 1
  if [ "$dry" -eq 1 ]; then
    return 0
  fi
  [ -f "$cached_stamp" ] || return 1
  [ "$(cat "$cached_stamp")" = "${inputs_of[$name]:-}" ] || return 1
  prove_tarball "$cached_tar" "$abi" "$name"
}

list="$work/proved.tsv"
: > "$list"
deps=""
proved=()

for name in "${names[@]}"; do
  tarball="$out/${name}-${abi}.tar.xz"
  if cache_hit "$name"; then
    if [ "${#proved[@]}" -eq 0 ]; then
      echo "cached $name alone"
    else
      echo "cached $name on ${proved[*]}"
    fi
    if [ "$dry" -eq 0 ]; then
      cp -a "$cache/$abi/$name.tar.xz" "$tarball"
    fi
  elif [ "$dry" -eq 1 ]; then
    if [ "${#proved[@]}" -eq 0 ]; then
      echo "build $name alone"
    else
      echo "build $name on ${proved[*]}"
    fi
  else
    args=(--only "$name" --arch "$arch" --gtk "$gtk" --tarball "$tarball")
    if [ -n "$deps" ]; then
      args+=(--deps-sysroot "$deps")
    fi
    "$ROOT/scripts/build-sysroot.sh" "${args[@]}"
    prove_tarball "$tarball" "$abi" "$name"
    if [ -n "$cache" ]; then
      mkdir -p "$cache/$abi"
      cp -a "$tarball" "$cache/$abi/$name.tar.xz"
      printf '%s\n' "${inputs_of[$name]}" > "$cache/$abi/$name.inputs"
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
