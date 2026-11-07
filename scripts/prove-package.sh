#!/usr/bin/env bash
# Build one small package, then any later packages on top of that sysroot.
# This does not publish. Monitor upstreams is the release path.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=sysroot-common.sh
source "$ROOT/scripts/sysroot-common.sh"

arch="${ARCH:-aarch64}"
gtk="${GTK_TARGET:-gnome}"
packages="sqlite3"
out=""
dry=0
check=""

usage() {
  echo "Usage: $0 [--arch aarch64|x86_64] [--gtk TARGET] [--packages NAMES] [--out DIR] [--dry-run]" >&2
  echo "       $0 --check TARBALL [--arch aarch64|x86_64]" >&2
  echo "NAMES is a build-order list. The default is sqlite3 alone." >&2
  echo "A later name is built against only the packages listed before it." >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --arch) arch=$2; shift 2 ;;
    --gtk) gtk=$2; shift 2 ;;
    --packages) packages=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --check) check=$2; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

if ! abi="$(sysroot_map "$ROOT/cross/abi" "$arch")"; then
  exit 2
fi

prove_tarball() {
  local tarball=$1 abi=$2 name=$3 listing pc lib meta
  if [ ! -f "$tarball" ]; then
    echo "Package tarball missing: $tarball" >&2
    return 1
  fi
  listing="$(mktemp)"
  tar -tJf "$tarball" > "$listing"
  pc="$(grep -E "^(\./)?lib/${abi}/pkgconfig/[^/]+\.pc$" "$listing" | head -n1 || true)"
  lib="$(grep -E "^(\./)?lib/${abi}/lib[^/]+\.(so|a)(\.|$)" "$listing" | head -n1 || true)"
  rm -f "$listing"
  if [ -z "$pc" ]; then
    echo "No pkg-config file under lib/${abi}/pkgconfig in $tarball" >&2
    return 1
  fi
  if [ -z "$lib" ]; then
    echo "No library under lib/${abi} in $tarball" >&2
    return 1
  fi
  meta="$(tar -xJf "$tarball" -O "$pc" | awk -F ': ' '/^(Name|Version):/ { printf "%s ", $2 }')"
  lib="${lib#./}"
  echo "proved ${name}: ${meta}(${lib})"
}

if [ -n "$check" ]; then
  prove_tarball "$check" "$abi" "$(basename "$check" .tar.xz)"
  exit 0
fi

if [ -z "$out" ]; then
  out="$ROOT/out/prove"
fi

declare -A order_at=()
position=0
while IFS= read -r name || [ -n "$name" ]; do
  name=${name%%#*}
  name=${name#"${name%%[![:space:]]*}"}
  name=${name%"${name##*[![:space:]]}"}
  [ -n "$name" ] || continue
  order_at[$name]=$position
  position=$((position + 1))
done < "$ROOT/build-order.txt"

IFS=',' read -ra raw_names <<< "$packages"
names=()
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
if [ "${#names[@]}" -eq 0 ]; then
  echo "No packages to prove" >&2
  exit 1
fi

mkdir -p "$out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
list="$work/proved.tsv"
: > "$list"
deps=""
proved=()

for name in "${names[@]}"; do
  tarball="$out/${name}-${abi}.tar.xz"
  if [ "$dry" -eq 1 ]; then
    if [ "${#proved[@]}" -eq 0 ]; then
      echo "prove $name alone"
    else
      echo "prove $name on ${proved[*]}"
    fi
    proved+=("$name")
    continue
  fi
  args=(--only "$name" --arch "$arch" --gtk "$gtk" --tarball "$tarball")
  if [ -n "$deps" ]; then
    args+=(--deps-sysroot "$deps")
  fi
  "$ROOT/scripts/build-sysroot.sh" "${args[@]}"
  prove_tarball "$tarball" "$abi" "$name"
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
  proved+=("$name")
done
