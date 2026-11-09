#!/usr/bin/env bash
# release.pins and snapshot.pins are the package lists.
# release.pins names official releases. snapshot.pins names snapshots.
# A line is committed when that package is on a GitHub release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=pixie-common.sh
source "$ROOT/scripts/pixie-common.sh"
# shellcheck source=upstream-index.sh
source "$ROOT/scripts/upstream-index.sh"
# shellcheck source=pins.sh
source "$ROOT/scripts/pins.sh"

pins_file() {
  local file=${1:-$ROOT/release.pins}
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

pins_mark_replaced() {
  local -n _mark=$1
  local line
  if [ ! -f "$ROOT/packages/gtk/replaces" ]; then
    echo "Missing package list: $ROOT/packages/gtk/replaces" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    _mark[$line]=1
  done < "$ROOT/packages/gtk/replaces"
}

# The published release is the 1.yymmdd already in the download URL.
url_release() {
  local url=$1 tag
  tag="$(printf '%s\n' "$url" | sed -n 's|.*/releases/download/\(1\.[0-9][0-9]*\)/.*|\1|p')"
  case "$tag" in
    1.[0-9][0-9][0-9][0-9][0-9][0-9]|1.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
      printf '%s\n' "$tag"
      ;;
    *)
      echo "Download URL has no published release: $url" >&2
      return 1
      ;;
  esac
}

release_stamp() {
  local version=$1 rest year month day hour minute second
  rest="${version#1.}"
  if [ "$rest" = "$version" ]; then
    echo "Bad release version: $version" >&2
    return 1
  fi
  if [ "${#rest}" -eq 6 ]; then
    hour=00
    minute=00
    second=00
  elif [ "${#rest}" -eq 12 ]; then
    hour="${rest:6:2}"
    minute="${rest:8:2}"
    second="${rest:10:2}"
  else
    echo "Bad release version: $version" >&2
    return 1
  fi
  year="${rest:0:2}"
  month="${rest:2:2}"
  day="${rest:4:2}"
  printf '20%s-%s-%sT%s:%s:%sZ\n' "$year" "$month" "$day" "$hour" "$minute" "$second"
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
  declare -A replaced=()
  pins_mark_replaced replaced || return 1
  declare -A groups=()
  declare -A base_inputs=()
  local got_abi got_gtk name track resolved inputs url key label owner
  owner="$(distro_owner "$repo")"
  if [ -f "$file" ]; then
    while IFS=$'\t' read -r got_abi got_gtk name track resolved inputs url _; do
      [ -n "${got_abi:-}" ] || continue
      [ -n "$url" ] || continue
      if [ "$got_gtk" = "$base" ]; then
        label="$(package_pin_label "$name" "$base" "$repo")"
        if [ "$label" != "$base" ]; then
          got_gtk="$label"
        fi
        base_inputs[$name]=$inputs
      fi
      key="${got_abi} ${got_gtk}"
      groups[$key]+="${got_abi}"$'\t'"${got_gtk}"$'\t'"${name}"$'\t'"${track}"$'\t'"${resolved}"$'\t'"${inputs}"$'\t'"${url}"$'\n'
    done < <(pins_rows "$file")
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
    groups["${abi} ${gtk}"]=""
    if [ "$gtk" = "$base" ] && [ "$owner" != "$base" ]; then
      groups["${abi} ${owner}"]=""
    fi
    while IFS=$'\t' read -r status name kind track resolved inputs url _; do
      [ -n "${status:-}" ] || continue
      case "$status" in \#*) continue ;; esac
      if [ "$gtk" != "$base" ]; then
        if [ "$name" = gdk ] && [ -n "${base_inputs[gdk]:-}" ] && [ "$inputs" = "${base_inputs[gdk]}" ]; then
          continue
        fi
        if [ -z "${replaced[$name]:-}" ]; then
          continue
        fi
      fi
      label="$(package_pin_label "$name" "$gtk" "$repo")"
      if [ "$status" = build ] || [ -z "$url" ] || [ "$url" = "-" ]; then
        url="https://github.com/${repo}/releases/download/${version}/$(package_asset_name "$name" "$abi" "$(package_track_label "$track")")"
      elif [ "$status" != keep ]; then
        echo "Bad plan status: $status" >&2
        return 1
      fi
      if [ "$gtk" = "$base" ]; then
        base_inputs[$name]=$inputs
      fi
      groups["${abi} ${label}"]+="${abi}"$'\t'"${label}"$'\t'"${name}"$'\t'"${track}"$'\t'"${resolved}"$'\t'"${inputs}"$'\t'"${url}"$'\n'
    done < "$plan"
    if [ -z "${groups[${abi} ${gtk}]}" ]; then
      echo "plan has no packages: $plan" >&2
      return 1
    fi
  done
  local tmp
  tmp="$(mktemp)"
  {
    while IFS= read -r key; do
      printf '%s' "${groups[$key]}"
    done < <(printf '%s\n' "${!groups[@]}" | LC_ALL=C sort)
  } | pins_store "$tmp"
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
  declare -A replaced=()
  declare -A reuse_url=()
  declare -A reuse_inputs=()
  local got_abi got_gtk name track resolved inputs url label
  pins_mark_replaced replaced || return 1
  if [ -f "$file" ]; then
    while IFS=$'\t' read -r got_abi got_gtk name track resolved inputs url _; do
      [ -n "${got_abi:-}" ] || continue
      if [ "$got_abi" = "$abi" ] && [ -n "$url" ]; then
        reuse_url["${got_gtk} ${name}"]=$url
        reuse_inputs["${got_gtk} ${name}"]=$inputs
      fi
    done < <(pins_rows "$file")
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
    if [ "$name" = gdk ]; then
      if [ -n "${reuse_url["$base gdk"]:-}" ] && [ "$inputs" = "${reuse_inputs["$base gdk"]:-}" ]; then
        echo "gdk matches $base; reusing that build" >&2
        printf 'keep\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$name" "$kind" "$track" "$resolved" "$inputs" "${reuse_url["$base gdk"]}"
      else
        echo "gdk differs from $base; building it for $gtk" >&2
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$status" "$name" "$kind" "$track" "$resolved" "$inputs" "$url"
      fi
    elif [ -z "${replaced[$name]:-}" ]; then
      label="$(package_pin_label "$name" "$base")"
      if [ -z "${reuse_url["$label $name"]:-}" ]; then
        echo "No $label tarball for $name. $gtk replaces only the packages in packages/gtk/replaces." >&2
        return 1
      fi
      printf 'keep\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$kind" "$track" "$resolved" "$inputs" "${reuse_url["$label $name"]}"
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
  local list got_abi got_gtk name track resolved inputs url arch created set_url tag base owner order_name picked
  list="$(mktemp)"
  : > "$list"
  set_url=""
  base="$(gtk_target_base "$ROOT/packages/gtk/targets")" || return 1
  owner="$(distro_owner)"
  declare -A replaced=()
  declare -A row_track=() row_resolved=() row_inputs=() row_url=()
  pins_mark_replaced replaced || return 1
  while IFS=$'\t' read -r got_abi got_gtk name track resolved inputs url _; do
    [ -n "${got_abi:-}" ] || continue
    [ "$got_abi" = "$abi" ] || continue
    row_track["${got_gtk} ${name}"]=$track
    row_resolved["${got_gtk} ${name}"]=$resolved
    row_inputs["${got_gtk} ${name}"]=$inputs
    row_url["${got_gtk} ${name}"]=$url
  done < <(pins_rows "$file")
  if [ "$gtk" != "$base" ] && [ -z "${row_url["$gtk gtk"]:-}" ]; then
    echo "$file has no gtk package for $abi $gtk" >&2
    return 1
  fi
  while IFS= read -r order_name || [ -n "$order_name" ]; do
    order_name=${order_name%%#*}
    order_name=${order_name#"${order_name%%[![:space:]]*}"}
    order_name=${order_name%"${order_name##*[![:space:]]}"}
    [ -n "$order_name" ] || continue
    picked=""
    if [ "$gtk" != "$base" ] && [ -n "${row_url["$gtk $order_name"]:-}" ]; then
      picked="$gtk"
    elif [ -n "${row_url["$owner $order_name"]:-}" ] && [ "$owner" != "$base" ]; then
      picked="$owner"
    elif [ -n "${row_url["$base $order_name"]:-}" ]; then
      picked="$base"
    elif [ "$gtk" = "$base" ] && [ -n "${row_url["$gtk $order_name"]:-}" ]; then
      picked="$gtk"
    else
      continue
    fi
    if [ "$order_name" = gtk ]; then
      set_url="${row_url["$picked gtk"]}"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$order_name" \
      "${row_track["$picked $order_name"]}" \
      "${row_resolved["$picked $order_name"]}" \
      "${row_inputs["$picked $order_name"]}" \
      "${row_url["$picked $order_name"]}" >> "$list"
  done < "$ROOT/build-order.txt"
  if [ -z "$set_url" ]; then
    set_url="${row_url["$base openssl"]:-${row_url["$gtk gtk"]:-}}"
  fi
  if [ -z "$set_url" ]; then
    set_url="$(awk -F '\t' 'NF { print $5; exit }' "$list")"
  fi
  if [ ! -s "$list" ]; then
    echo "$file has no packages for $abi $gtk" >&2
    return 1
  fi
  arch="$(abi_arch "$abi")" || return 1
  tag="$(url_release "$set_url")" || return 1
  created="$(release_stamp "$tag")" || return 1
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
