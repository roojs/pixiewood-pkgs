#!/usr/bin/env bash
# current.pins names the index to download for each ABI and GTK target.
# It is committed before a publishing build. The repository source archive
# contains this file and nothing else.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=sysroot-common.sh
source "$ROOT/scripts/sysroot-common.sh"
# shellcheck source=upstream-index.sh
source "$ROOT/scripts/upstream-index.sh"

pins_file() {
  local file=${1:-$ROOT/current.pins}
  printf '%s\n' "$file"
}

pins_read() {
  local file=$1 abi=$2 gtk=$3
  local got_abi got_gtk version url
  if [ ! -f "$file" ]; then
    return 1
  fi
  while read -r got_abi got_gtk version url _; do
    if [ -z "${got_abi:-}" ] || [ "${got_abi#\#}" != "$got_abi" ]; then
      continue
    fi
    if [ "$got_abi" = "$abi" ] && [ "$got_gtk" = "$gtk" ] && [ -n "$url" ]; then
      printf '%s\n' "$url"
      return 0
    fi
  done < "$file"
  return 1
}

cmd_url() {
  local file="" abi="" gtk=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file) file=$2; shift 2 ;;
      --abi) abi=$2; shift 2 ;;
      --gtk) gtk=$2; shift 2 ;;
      *) echo "Unknown argument: $1" >&2; return 2 ;;
    esac
  done
  file="$(pins_file "$file")"
  if [ -z "$abi" ] || [ -z "$gtk" ]; then
    echo "Usage: $0 url --abi ABI --gtk TARGET [--file PATH]" >&2
    return 2
  fi
  if ! pins_read "$file" "$abi" "$gtk"; then
    echo "current.pins has no index for $abi $gtk" >&2
    return 1
  fi
}

cmd_write() {
  local file="" arch="" created="" repo="${GITHUB_REPOSITORY:-roojs/pixiewood-pkgs}"
  local -a gtks=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file) file=$2; shift 2 ;;
      --arch) arch=$2; shift 2 ;;
      --created) created=$2; shift 2 ;;
      --repo) repo=$2; shift 2 ;;
      --gtk) gtks+=("$2"); shift 2 ;;
      *) echo "Unknown argument: $1" >&2; return 2 ;;
    esac
  done
  file="$(pins_file "$file")"
  if [ -z "$arch" ] || [ -z "$created" ] || [ "${#gtks[@]}" -eq 0 ]; then
    echo "Usage: $0 write --arch ARCH --created STAMP [--repo OWNER/NAME] [--file PATH] --gtk TARGET ..." >&2
    return 2
  fi
  local abi version gtk
  abi="$(sysroot_map "$ROOT/cross/abi" "$arch")" || return 1
  version="$(release_version "$created")" || return 1
  declare -A lines=()
  local got_abi got_gtk got_version got_url
  if [ -f "$file" ]; then
    while read -r got_abi got_gtk got_version got_url _; do
      if [ -z "${got_abi:-}" ] || [ "${got_abi#\#}" != "$got_abi" ]; then
        continue
      fi
      [ -n "$got_url" ] || continue
      lines["${got_abi} ${got_gtk}"]="${got_abi} ${got_gtk} ${got_version} ${got_url}"
    done < "$file"
  fi
  for gtk in "${gtks[@]}"; do
    lines["${abi} ${gtk}"]="${abi} ${gtk} ${version} https://github.com/${repo}/releases/download/${version}/index-${abi}-${gtk}.json"
  done
  local tmp key
  tmp="$(mktemp)"
  {
    printf '%s\n' '# abi gtk release url'
    for key in "${!lines[@]}"; do
      printf '%s\n' "${lines[$key]}"
    done | LC_ALL=C sort
  } > "$tmp"
  mv "$tmp" "$file"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  command=${1:-}
  shift || true
  case "$command" in
    url) cmd_url "$@" ;;
    write) cmd_write "$@" ;;
    *)
      echo "Usage: $0 url|write ..." >&2
      exit 2
      ;;
  esac
fi
