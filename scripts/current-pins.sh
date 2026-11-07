#!/usr/bin/env bash
# current.pins is the package list: one line per package and its tarball URL.
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

abi_arch() {
  local abi=$1 arch got
  while read -r arch got _; do
    if [ -z "${arch:-}" ] || [ "${arch#\#}" != "$arch" ]; then
      continue
    fi
    if [ "$got" = "$abi" ]; then
      printf '%s\n' "$arch"
      return 0
    fi
  done < "$ROOT/cross/abi"
  echo "Unknown ABI: $abi" >&2
  return 1
}

release_stamp() {
  local version=$1 year month day
  if [ "${#version}" -ne 8 ] || [ "${version#1.}" = "$version" ]; then
    echo "Bad release version: $version" >&2
    return 1
  fi
  year="${version:2:2}"
  month="${version:4:2}"
  day="${version:6:2}"
  printf '20%s-%s-%sT00:00:00Z\n' "$year" "$month" "$day"
}

cmd_write() {
  local file="" arch="" created="" repo="${GITHUB_REPOSITORY:-roojs/pixiewood-pkgs}"
  local -a plans=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file) file=$2; shift 2 ;;
      --arch) arch=$2; shift 2 ;;
      --created) created=$2; shift 2 ;;
      --repo) repo=$2; shift 2 ;;
      --plan) plans+=("$2"); shift 2 ;;
      *) echo "Unknown argument: $1" >&2; return 2 ;;
    esac
  done
  file="$(pins_file "$file")"
  if [ -z "$arch" ] || [ -z "$created" ] || [ "${#plans[@]}" -eq 0 ]; then
    echo "Usage: $0 write --arch ARCH --created STAMP [--repo OWNER/NAME] [--file PATH] --plan FILE ..." >&2
    return 2
  fi
  local abi version base
  abi="$(sysroot_map "$ROOT/cross/abi" "$arch")" || return 1
  version="$(release_version "$created")" || return 1
  base="$(gtk_target_base "$ROOT/packages/gtk/targets")" || return 1
  declare -A before=()
  local before_name
  while IFS= read -r before_name || [ -n "$before_name" ]; do
    before_name=${before_name%%#*}
    before_name=${before_name#"${before_name%%[![:space:]]*}"}
    before_name=${before_name%"${before_name##*[![:space:]]}"}
    [ -n "$before_name" ] || continue
    [ "$before_name" = gtk ] && break
    before[$before_name]=1
  done < "$ROOT/build-order.txt"
  declare -A groups=()
  declare -A base_url=()
  local got_abi got_gtk release name track resolved inputs url key
  if [ -f "$file" ]; then
    while IFS=$'\t' read -r got_abi got_gtk release name track resolved inputs url _; do
      if [ -z "${got_abi:-}" ] || [ "${got_abi#\#}" != "$got_abi" ]; then
        continue
      fi
      [ -n "$url" ] || continue
      key="${got_abi} ${got_gtk}"
      groups[$key]+="${got_abi}"$'\t'"${got_gtk}"$'\t'"${release}"$'\t'"${name}"$'\t'"${track}"$'\t'"${resolved}"$'\t'"${inputs}"$'\t'"${url}"$'\n'
      if [ "$got_gtk" = "$base" ] && [ "$got_abi" = "$abi" ]; then
        base_url[$name]=$url
      fi
    done < "$file"
  fi
  local plan gtk status kind
  local -a ordered=()
  local -a later=()
  for plan in "${plans[@]}"; do
    gtk="$(sed -n 's/^# gtk_target=//p' "$plan" | head -n1)"
    if [ "$gtk" = "$base" ]; then
      ordered+=("$plan")
    else
      later+=("$plan")
    fi
  done
  if [ "${#later[@]}" -gt 0 ]; then
    ordered+=("${later[@]}")
  fi
  for plan in "${ordered[@]}"; do
    gtk="$(sed -n 's/^# gtk_target=//p' "$plan" | head -n1)"
    if [ -z "$gtk" ]; then
      echo "plan is missing gtk_target: $plan" >&2
      return 1
    fi
    key="${abi} ${gtk}"
    groups[$key]=""
    if [ "$gtk" = "$base" ]; then
      base_url=()
    fi
    while IFS=$'\t' read -r status name kind track resolved inputs url _; do
      [ -n "${status:-}" ] || continue
      case "$status" in \#*) continue ;; esac
      if [ "$gtk" != "$base" ] && [ -n "${before[$name]:-}" ] && [ -n "${base_url[$name]:-}" ]; then
        url="${base_url[$name]}"
      elif [ "$status" = build ] || [ -z "$url" ] || [ "$url" = "-" ]; then
        url="https://github.com/${repo}/releases/download/${version}/${name}-${abi}-${gtk}.tar.xz"
      elif [ "$status" != keep ]; then
        echo "Bad plan status: $status" >&2
        return 1
      fi
      if [ "$gtk" = "$base" ]; then
        base_url[$name]=$url
      fi
      groups[$key]+="${abi}"$'\t'"${gtk}"$'\t'"${version}"$'\t'"${name}"$'\t'"${track}"$'\t'"${resolved}"$'\t'"${inputs}"$'\t'"${url}"$'\n'
    done < "$plan"
    if [ -z "${groups[$key]}" ]; then
      echo "plan has no packages: $plan" >&2
      return 1
    fi
  done
  local tmp
  tmp="$(mktemp)"
  {
    printf '%s\n' '# abi gtk release name track resolved inputs url'
    while IFS= read -r key; do
      printf '%s' "${groups[$key]}"
    done < <(printf '%s\n' "${!groups[@]}" | LC_ALL=C sort)
  } > "$tmp"
  mv "$tmp" "$file"
}

cmd_apply() {
  local plan="" out="" arch="" file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --plan) plan=$2; shift 2 ;;
      --out) out=$2; shift 2 ;;
      --arch) arch=$2; shift 2 ;;
      --file) file=$2; shift 2 ;;
      *) echo "Unknown argument: $1" >&2; return 2 ;;
    esac
  done
  file="$(pins_file "$file")"
  if [ -z "$plan" ] || [ -z "$out" ] || [ -z "$arch" ]; then
    echo "Usage: $0 apply --plan FILE --out FILE --arch ARCH [--file PATH]" >&2
    return 2
  fi
  local base gtk abi
  base="$(gtk_target_base "$ROOT/packages/gtk/targets")" || return 1
  gtk="$(sed -n 's/^# gtk_target=//p' "$plan" | head -n1)"
  if [ -z "$gtk" ]; then
    echo "plan is missing gtk_target: $plan" >&2
    return 1
  fi
  abi="$(sysroot_map "$ROOT/cross/abi" "$arch")" || return 1
  if [ "$gtk" = "$base" ]; then
    cp "$plan" "$out"
    return 0
  fi
  declare -A before=()
  declare -A reuse=()
  local before_name got_abi got_gtk release name track resolved inputs url
  while IFS= read -r before_name || [ -n "$before_name" ]; do
    before_name=${before_name%%#*}
    before_name=${before_name#"${before_name%%[![:space:]]*}"}
    before_name=${before_name%"${before_name##*[![:space:]]}"}
    [ -n "$before_name" ] || continue
    [ "$before_name" = gtk ] && break
    before[$before_name]=1
  done < "$ROOT/build-order.txt"
  if [ -f "$file" ]; then
    while IFS=$'\t' read -r got_abi got_gtk release name track resolved inputs url _; do
      if [ -z "${got_abi:-}" ] || [ "${got_abi#\#}" != "$got_abi" ]; then
        continue
      fi
      if [ "$got_abi" = "$abi" ] && [ "$got_gtk" = "$base" ] && [ -n "$url" ]; then
        reuse[$name]=$url
      fi
    done < "$file"
  fi
  local tmp status kind
  tmp="$(mktemp)"
  while IFS=$'\t' read -r status name kind track resolved inputs url || [ -n "${status:-}" ]; do
    if [ -z "${status:-}" ]; then
      continue
    fi
    case "$status" in
      \#*)
        printf '%s\n' "$status"
        continue
        ;;
    esac
    if [ -n "${before[$name]:-}" ] && [ -n "${reuse[$name]:-}" ]; then
      printf 'keep\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$kind" "$track" "$resolved" "$inputs" "${reuse[$name]}"
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$status" "$name" "$kind" "$track" "$resolved" "$inputs" "$url"
    fi
  done < "$plan" > "$tmp"
  mv "$tmp" "$out"
}

cmd_index() {
  local file="" abi="" gtk="" out=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file) file=$2; shift 2 ;;
      --abi) abi=$2; shift 2 ;;
      --gtk) gtk=$2; shift 2 ;;
      --out) out=$2; shift 2 ;;
      *) echo "Unknown argument: $1" >&2; return 2 ;;
    esac
  done
  file="$(pins_file "$file")"
  if [ -z "$abi" ] || [ -z "$gtk" ] || [ -z "$out" ]; then
    echo "Usage: $0 index --abi ABI --gtk TARGET --out INDEX [--file PATH]" >&2
    return 2
  fi
  if [ ! -f "$file" ]; then
    echo "Missing package list: $file" >&2
    return 1
  fi
  local list got_abi got_gtk release name track resolved inputs url arch created set_release
  list="$(mktemp)"
  : > "$list"
  set_release=""
  while IFS=$'\t' read -r got_abi got_gtk release name track resolved inputs url _; do
    if [ -z "${got_abi:-}" ] || [ "${got_abi#\#}" != "$got_abi" ]; then
      continue
    fi
    [ "$got_abi" = "$abi" ] && [ "$got_gtk" = "$gtk" ] || continue
    if [ -n "$set_release" ] && [ "$set_release" != "$release" ]; then
      echo "current.pins has mixed releases for $abi $gtk" >&2
      return 1
    fi
    set_release="$release"
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$track" "$resolved" "$inputs" "$url" >> "$list"
  done < "$file"
  if [ ! -s "$list" ]; then
    echo "current.pins has no packages for $abi $gtk" >&2
    return 1
  fi
  arch="$(abi_arch "$abi")" || return 1
  created="$(release_stamp "$set_release")" || return 1
  index_write "$out" "$abi" "$arch" "$gtk" "$created" "$list"
  rm -f "$list"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  command=${1:-}
  shift || true
  case "$command" in
    write) cmd_write "$@" ;;
    apply) cmd_apply "$@" ;;
    index) cmd_index "$@" ;;
    *)
      echo "Usage: $0 write|apply|index ..." >&2
      exit 2
      ;;
  esac
fi
