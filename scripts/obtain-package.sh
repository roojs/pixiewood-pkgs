#!/usr/bin/env bash
# Decide where a package comes from, for prove and for a real sysroot build.
# A pin in release.pins or snapshot.pins is used when that package's recipe has not
# changed since the pin was committed. Otherwise a tarball in the package
# cache is used when it matches this resolve. Otherwise the package is built.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=gtk-target.sh
source "$ROOT/scripts/gtk-target.sh"
# shellcheck source=pins.sh
source "$ROOT/scripts/pins.sh"

obtain_pin_fields() {
  local file=$1 abi=$2 label=$3 name=$4
  local got_abi got_gtk _release got_name _track resolved inputs url
  [ -f "$file" ] || return 1
  while IFS=$'\t' read -r got_abi got_gtk _release got_name _track resolved inputs url _; do
    [ -n "${got_abi:-}" ] || continue
    if [ "$got_abi" = "$abi" ] && [ "$got_gtk" = "$label" ] && [ "$got_name" = "$name" ] && [ -n "$url" ]; then
      printf '%s\t%s\t%s\n' "$resolved" "$inputs" "$url"
      return 0
    fi
  done < <(pins_rows "$file")
  return 1
}

# Files that change the bytes of this package. A shared script is included
# only when that package's build actually runs it.
obtain_recipe_paths() {
  local name=$1 wrap
  printf '%s\n' "$ROOT/packages/$name" "$ROOT/cross" "$ROOT/android-distro.conf"
  wrap="$ROOT/packages/$name/$name.wrap"
  if [ -f "$wrap" ] && grep -q '^diff_files[[:space:]]*=' "$wrap"; then
    printf '%s\n' "$ROOT/scripts/build-sysroot.sh"
  fi
  if [ "$name" = gtk ] || [ "$name" = gdk ] || { [ -f "$wrap" ] && grep -q '^pixiewood_from[[:space:]]*=[[:space:]]*gtk[[:space:]]*$' "$wrap"; }; then
    printf '%s\n' "$ROOT/scripts/gtk-part.sh" "$ROOT/scripts/build-sysroot.sh"
  fi
}

obtain_pin_commit() {
  local file=$1
  local top
  top="$(cd "$ROOT" && pwd)"
  case "$file" in
    "$top"/release.pins|"$ROOT"/release.pins|"$top"/snapshot.pins|"$ROOT"/snapshot.pins)
      git -C "$ROOT" log -1 --format=%H -- "$file" 2>/dev/null || true
      ;;
  esac
}

obtain_pin_current() {
  local name=$1 pin_resolved=$2 pin_inputs=$3 current_resolved=$4 current_inputs=$5 pins=$6
  local commit path
  if [ -n "$current_resolved" ] && [ "$pin_resolved" != "$current_resolved" ]; then
    return 1
  fi
  commit="$(obtain_pin_commit "$pins")"
  if [ -z "$commit" ]; then
    if [ -n "$current_inputs" ] && [ "$pin_inputs" != "$current_inputs" ]; then
      return 1
    fi
    return 0
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if ! git -C "$ROOT" diff --quiet "$commit" HEAD -- "$path"; then
      return 1
    fi
  done < <(obtain_recipe_paths "$name")
  return 0
}

obtain_cache_path() {
  local cache=$1 abi=$2 name=$3
  [ -n "$cache" ] || return 1
  [ -f "$cache/$abi/$name.tar.xz" ] || return 1
  if [ -n "${4:-}" ]; then
    [ -f "$cache/$abi/$name.inputs" ] || return 1
    [ "$(cat "$cache/$abi/$name.inputs")" = "$4" ] || return 1
  fi
  printf '%s\n' "$cache/$abi/$name.tar.xz"
}

# Print "pin URL", "cache PATH", or "build".
obtain_decide() {
  local name=$1 abi=$2 gtk=$3 cache=$4 pins=$5 current_resolved=$6 current_inputs=$7
  local label fields pin_resolved pin_inputs pin_url cached
  label="$(package_pin_label "$name" "$gtk")"
  if fields="$(obtain_pin_fields "$pins" "$abi" "$label" "$name")"; then
    IFS=$'\t' read -r pin_resolved pin_inputs pin_url <<< "$fields"
    if obtain_pin_current "$name" "$pin_resolved" "$pin_inputs" "$current_resolved" "$current_inputs" "$pins"; then
      printf 'pin\t%s\n' "$pin_url"
      return 0
    fi
  fi
  if cached="$(obtain_cache_path "$cache" "$abi" "$name" "$current_inputs")"; then
    printf 'cache\t%s\n' "$cached"
    return 0
  fi
  printf 'build\n'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  name="" abi="" gtk="${GTK_TARGET:-gnome}" cache="" pins="$ROOT/release.pins"
  resolved="" inputs=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) name=$2; shift 2 ;;
      --abi) abi=$2; shift 2 ;;
      --gtk) gtk=$2; shift 2 ;;
      --cache) cache=$2; shift 2 ;;
      --pins) pins=$2; shift 2 ;;
      --resolved) resolved=$2; shift 2 ;;
      --inputs) inputs=$2; shift 2 ;;
      *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
  done
  if [ -z "$name" ] || [ -z "$abi" ]; then
    echo "Usage: $0 --name NAME --abi ABI [--gtk TARGET] [--cache DIR] [--pins FILE] [--resolved SHA] [--inputs HASH]" >&2
    exit 2
  fi
  obtain_decide "$name" "$abi" "$gtk" "$cache" "$pins" "$resolved" "$inputs"
fi
