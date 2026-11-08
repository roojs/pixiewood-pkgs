#!/usr/bin/env bash
# Resolve upstream package identities and build a release index.
# Unchanged packages keep the previous tarball URL.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=gtk-target.sh
source "$ROOT/scripts/gtk-target.sh"

distro_get() {
  local key=$1
  sed -n "s/^${key}=//p" "$ROOT/android-distro.conf" | head -n1 | tr -d '[:space:]'
}

wrap_field() {
  local file=$1 key=$2
  sed -n "s/^${key}[[:space:]]*=[[:space:]]*//p" "$file" | head -n1 | tr -d '[:space:]'
}

index_resolve_git() {
  local url=$1 rev=$2 lines sha needle
  if [[ "$rev" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s' "$rev"
    return 0
  fi
  lines="$(git ls-remote "$url" "refs/tags/${rev}" "refs/tags/${rev}^{}" "refs/heads/${rev}")" || return 1
  needle="refs/tags/${rev}^{}"
  sha="$(printf '%s\n' "$lines" | awk -v needle="$needle" '$2 == needle { print $1; exit }')"
  if [ -z "$sha" ]; then
    needle="refs/heads/${rev}"
    sha="$(printf '%s\n' "$lines" | awk -v needle="$needle" '$2 == needle { print $1; exit }')"
  fi
  if [ -z "$sha" ]; then
    needle="refs/tags/${rev}"
    sha="$(printf '%s\n' "$lines" | awk -v needle="$needle" '$2 == needle { print $1; exit }')"
  fi
  if [ -z "$sha" ]; then
    echo "Could not resolve $rev from $url" >&2
    return 1
  fi
  printf '%s' "$sha"
}

index_hash_paths() {
  local exclude_patch=$1
  shift
  find "$@" -type f ! -path '*/.git/*' | LC_ALL=C sort | while IFS= read -r file; do
    if [ -n "$exclude_patch" ] && [[ "$file" == *.patch ]] && [ "$(basename "$file")" != "$exclude_patch" ]; then
      continue
    fi
    sha256sum "$file"
  done
}

gdk_tree_hash() {
  local url=$1 rev=$2 cache dir hash
  cache="${PIXIEWOOD_GDK_CACHE:-${TMPDIR:-/tmp}/pixiewood-gdk-tree}"
  dir="$cache/$rev"
  if [ ! -s "$dir/.part-hash" ]; then
    rm -rf "$dir"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin "$url"
    git -C "$dir" fetch --depth 1 origin "$rev"
    git -C "$dir" checkout -q --detach FETCH_HEAD
    if [ ! -d "$dir/gdk" ]; then
      echo "GTK checkout has no gdk directory: $rev" >&2
      return 1
    fi
    # GDK compiles against gtk/css. A css-only change still needs its own GDK.
    local paths=("$dir/gdk")
    if [ -d "$dir/gtk/css" ]; then
      paths+=("$dir/gtk/css")
    fi
    hash="$(index_hash_paths "" "${paths[@]}" | sha256sum | awk '{print $1}')"
    printf '%s\n' "$hash" > "$dir/.part-hash"
  fi
  cat "$dir/.part-hash"
}

index_shared_hash() {
  local api ndk
  api="$(distro_get api)"
  ndk="$(distro_get ndk)"
  {
    index_hash_paths "" \
      "$ROOT/cross" \
      "$ROOT/android-distro.conf" \
      "$ROOT/scripts/build-sysroot.sh" \
      "$ROOT/scripts/sysroot-tree.sh" \
      "$ROOT/scripts/gtk-target.sh" \
      "$ROOT/scripts/build-changed.sh"
    printf 'api=%s\nndk=%s\n' "$api" "$ndk"
  } | sha256sum | awk '{print $1}'
}

index_check_token() {
  if printf '%s' "$1" | LC_ALL=C grep -q '["[:cntrl:]\\]'; then
    echo "Index value contains a character JSON cannot store plainly: $1" >&2
    return 1
  fi
}

index_packages() {
  local file=$1
  sed -n 's/^    {"name": "\([^"]*\)", "track": "\([^"]*\)", "resolved": "\([^"]*\)", "inputs": "\([^"]*\)", "url": "\([^"]*\)".*/\1\t\2\t\3\t\4\t\5/p' "$file"
}

# 1.yymmddHHMMSS from a UTC stamp such as 2026-11-07T01:02:03Z.
# The clock time is part of the name so a later publish the same day is a new release.
release_version() {
  local stamp=$1 year month day hour minute second
  year="$(printf '%s' "$stamp" | sed -n 's/^\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)T\([0-9]\{2\}\):\([0-9]\{2\}\):\([0-9]\{2\}\).*/\1/p')"
  month="$(printf '%s' "$stamp" | sed -n 's/^\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)T\([0-9]\{2\}\):\([0-9]\{2\}\):\([0-9]\{2\}\).*/\2/p')"
  day="$(printf '%s' "$stamp" | sed -n 's/^\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)T\([0-9]\{2\}\):\([0-9]\{2\}\):\([0-9]\{2\}\).*/\3/p')"
  hour="$(printf '%s' "$stamp" | sed -n 's/^\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)T\([0-9]\{2\}\):\([0-9]\{2\}\):\([0-9]\{2\}\).*/\4/p')"
  minute="$(printf '%s' "$stamp" | sed -n 's/^\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)T\([0-9]\{2\}\):\([0-9]\{2\}\):\([0-9]\{2\}\).*/\5/p')"
  second="$(printf '%s' "$stamp" | sed -n 's/^\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)T\([0-9]\{2\}\):\([0-9]\{2\}\):\([0-9]\{2\}\).*/\6/p')"
  if [ -z "$year" ] || [ -z "$month" ] || [ -z "$day" ] || [ -z "$hour" ] || [ -z "$minute" ] || [ -z "$second" ]; then
    echo "Release stamp must be YYYY-MM-DDTHH:MM:SS: $stamp" >&2
    return 1
  fi
  printf '1.%s%s%s%s%s%s\n' "${year:2:2}" "$month" "$day" "$hour" "$minute" "$second"
}

index_write() {
  local out=$1 abi=$2 arch=$3 gtk=$4 created=$5 list=$6
  local api ndk pixiewood url rev patch target_line version
  local name track resolved inputs pkg_url first
  api="$(distro_get api)"
  ndk="$(distro_get ndk)"
  pixiewood="$(distro_get pixiewood)"
  # A published index is stamped YYYY-MM-DDTHH:MM:SS and versioned 1.yymmddHHMMSS.
  # A dependency index built for the next package uses its own stamp.
  if printf '%s' "$created" | grep -q '^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}'; then
    version="$(release_version "$created")" || return 1
  else
    version="$created"
  fi
  if ! target_line="$(gtk_target_read "$ROOT/packages/gtk/targets" "$gtk")"; then
    return 1
  fi
  read -r url rev patch <<< "$target_line"
  for value in "$abi" "$arch" "$gtk" "$created" "$version" "$url" "$rev" "$api" "$ndk" "$pixiewood"; do
    index_check_token "$value"
  done
  {
    printf '{\n'
    printf '  "format": 1,\n'
    printf '  "version": "%s",\n' "$version"
    printf '  "abi": "%s",\n' "$abi"
    printf '  "arch": "%s",\n' "$arch"
    printf '  "api": %s,\n' "$api"
    printf '  "ndk": "%s",\n' "$ndk"
    printf '  "pixiewood_revision": "%s",\n' "$pixiewood"
    printf '  "gtk_target": "%s",\n' "$gtk"
    printf '  "gtk_url": "%s",\n' "$url"
    printf '  "gtk_track": "%s",\n' "$rev"
    printf '  "created": "%s",\n' "$created"
    printf '  "packages": [\n'
    first=1
    while IFS=$'\t' read -r name track resolved inputs pkg_url; do
      [ -n "$name" ] || continue
      case "$name" in
        \#*) continue ;;
      esac
      index_check_token "$name"
      index_check_token "$track"
      index_check_token "$resolved"
      index_check_token "$inputs"
      index_check_token "$pkg_url"
      if [ "$first" -eq 1 ]; then
        first=0
      else
        printf ',\n'
      fi
      printf '    {"name": "%s", "track": "%s", "resolved": "%s", "inputs": "%s", "url": "%s"}' \
        "$name" "$track" "$resolved" "$inputs" "$pkg_url"
    done < "$list"
    if [ "$first" -eq 0 ]; then
      printf '\n'
    fi
    printf '  ]\n'
    printf '}\n'
  } > "$out"
}

cmd_resolve() {
  local packages="$ROOT/packages" gtk="${GTK_TARGET:-gnome}" out=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --packages) packages=$2; shift 2 ;;
      --gtk) gtk=$2; shift 2 ;;
      --out) out=$2; shift 2 ;;
      *) echo "Unknown argument: $1" >&2; return 2 ;;
    esac
  done
  local url rev patch shared exclude name wrap kind track resolved inputs dir target_line
  if ! target_line="$(gtk_target_read "$ROOT/packages/gtk/targets" "$gtk")"; then
    return 1
  fi
  read -r url rev patch <<< "$target_line"
  shared="$(index_shared_hash)"
  exclude=""
  if [ "$patch" = "-" ]; then
    exclude="__none__"
  else
    exclude="$patch"
  fi
  # exclude is the selected patch; index_hash_paths keeps that basename and drops other patches.
  {
    for dir in "$packages"/*/; do
      [ -d "$dir" ] || continue
      name="$(basename "$dir")"
      wrap="$dir/$name.wrap"
      [ -f "$wrap" ] || continue
      if [ "$name" = gtk ] || [ "$(wrap_field "$wrap" pixiewood_from)" = gtk ]; then
        track="$rev"
        kind=git
        resolved="$(index_resolve_git "$url" "$track")"
        if [ "$name" != gtk ]; then
          inputs="$(
            {
              printf 'shared %s\n' "$shared"
              printf 'gdk %s\n' "$(gdk_tree_hash "$url" "$resolved")"
              index_hash_paths "" "$dir" "$ROOT/scripts/gtk-part.sh"
            } | sha256sum | awk '{print $1}'
          )"
        elif [ "$patch" = "-" ]; then
          inputs="$(
            {
              printf 'shared %s\n' "$shared"
              index_hash_paths "__no_such_patch__" "$dir" "$ROOT/scripts/gtk-part.sh"
            } | sha256sum | awk '{print $1}'
          )"
        else
          inputs="$(
            {
              printf 'shared %s\n' "$shared"
              index_hash_paths "$patch" "$dir" "$ROOT/scripts/gtk-part.sh"
            } | sha256sum | awk '{print $1}'
          )"
        fi
      elif grep -q '^\[wrap-git\]' "$wrap"; then
        kind=git
        track="$(wrap_field "$wrap" revision)"
        resolved="$(index_resolve_git "$(wrap_field "$wrap" url)" "$track")"
        inputs="$(
          {
            printf 'shared %s\n' "$shared"
            index_hash_paths "" "$dir"
          } | sha256sum | awk '{print $1}'
        )"
      elif grep -q '^\[wrap-file\]' "$wrap"; then
        kind=file
        track="$(wrap_field "$wrap" source_filename)"
        resolved="$(wrap_field "$wrap" source_hash)"
        inputs="$(
          {
            printf 'shared %s\n' "$shared"
            index_hash_paths "" "$dir"
          } | sha256sum | awk '{print $1}'
        )"
      else
        echo "Wrap is neither git nor file: $wrap" >&2
        return 1
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$kind" "$track" "$resolved" "$inputs"
    done
  } | if [ -n "$out" ]; then cat > "$out"; else cat; fi
}

cmd_plan() {
  local resolved="" previous="" out="" force="" gtk="${GTK_TARGET:-gnome}" order="$ROOT/build-order.txt"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --resolved) resolved=$2; shift 2 ;;
      --previous) previous=$2; shift 2 ;;
      --out) out=$2; shift 2 ;;
      --force) force=$2; shift 2 ;;
      --gtk) gtk=$2; shift 2 ;;
      --build-order) order=$2; shift 2 ;;
      *) echo "Unknown argument: $1" >&2; return 2 ;;
    esac
  done
  if [ -z "$resolved" ] || [ -z "$out" ]; then
    echo "plan requires --resolved and --out" >&2
    return 2
  fi
  declare -A have_kind=() have_track=() have_resolved=() have_inputs=()
  declare -A prev_resolved=() prev_inputs=() prev_url=() prev_seen=()
  local name kind track rev inputs url status publish=0 build=0
  while IFS=$'\t' read -r name kind track rev inputs; do
    [ -n "$name" ] || continue
    case "$name" in \#*) continue ;; esac
    have_kind[$name]=$kind
    have_track[$name]=$track
    have_resolved[$name]=$rev
    have_inputs[$name]=$inputs
  done < "$resolved"
  if [ -n "$previous" ] && [ -f "$previous" ]; then
    while IFS=$'\t' read -r name track rev inputs url; do
      [ -n "$name" ] || continue
      prev_resolved[$name]=$rev
      prev_inputs[$name]=$inputs
      prev_url[$name]=$url
      prev_seen[$name]=1
    done < <(index_packages "$previous")
  fi
  local -a forced=()
  if [ -n "$force" ] && [ "$force" != all ]; then
    IFS=',' read -r -a forced <<< "$force"
  fi
  : > "$out"
  while IFS= read -r name || [ -n "$name" ]; do
    name=${name%%#*}
    name=${name#"${name%%[![:space:]]*}"}
    name=${name%"${name##*[![:space:]]}"}
    [ -n "$name" ] || continue
    if [ -z "${have_resolved[$name]:-}" ]; then
      echo "build-order entry has no wrap: $name" >&2
      return 1
    fi
    status=keep
    url="${prev_url[$name]:-}"
    if [ -z "${prev_seen[$name]:-}" ] \
      || [ "${prev_resolved[$name]}" != "${have_resolved[$name]}" ] \
      || [ "${prev_inputs[$name]}" != "${have_inputs[$name]}" ]; then
      status=build
      url='-'
    fi
    if [ "$force" = all ]; then
      status=build
      url='-'
    fi
    local item
    for item in "${forced[@]}"; do
      item=${item#"${item%%[![:space:]]*}"}
      item=${item%"${item##*[![:space:]]}"}
      if [ "$item" = "$name" ]; then
        status=build
        url='-'
      fi
    done
    if [ "$status" = build ]; then
      build=1
      publish=1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$status" "$name" "${have_kind[$name]}" "${have_track[$name]}" \
      "${have_resolved[$name]}" "${have_inputs[$name]}" "$url" >> "$out"
    unset "have_resolved[$name]"
  done < "$order"
  for name in "${!have_resolved[@]}"; do
    echo "Package is not in build-order: $name" >&2
    return 1
  done
  if [ -n "$previous" ] && [ -f "$previous" ]; then
    for name in "${!prev_seen[@]}"; do
      if ! awk -F '\t' -v name="$name" '$1 !~ /^#/ && $2 == name { found = 1 } END { exit !found }' "$out"; then
        publish=1
      fi
    done
  fi
  local tmp
  tmp="$(mktemp)"
  {
    printf '# publish=%s\n' "$publish"
    printf '# build=%s\n' "$build"
    printf '# gtk_target=%s\n' "$gtk"
    cat "$out"
  } > "$tmp"
  mv "$tmp" "$out"
  echo "publish=$publish"
  echo "build=$build"
}

cmd_assemble() {
  local plan="" built="" abi="" arch="" gtk="" created="" out=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --plan) plan=$2; shift 2 ;;
      --built) built=$2; shift 2 ;;
      --abi) abi=$2; shift 2 ;;
      --arch) arch=$2; shift 2 ;;
      --gtk) gtk=$2; shift 2 ;;
      --created) created=$2; shift 2 ;;
      --out) out=$2; shift 2 ;;
      *) echo "Unknown argument: $1" >&2; return 2 ;;
    esac
  done
  if [ -z "$plan" ] || [ -z "$abi" ] || [ -z "$arch" ] || [ -z "$gtk" ] || [ -z "$created" ] || [ -z "$out" ]; then
    echo "assemble requires --plan --abi --arch --gtk --created --out" >&2
    return 2
  fi
  declare -A built_url=()
  if [ -n "$built" ] && [ -r "$built" ]; then
    local bname burl
    while IFS=$'\t' read -r bname burl; do
      [ -n "$bname" ] || continue
      case "$bname" in \#*) continue ;; esac
      built_url[$bname]=$burl
    done < "$built"
  fi
  local list status name kind track resolved inputs url
  list="$(mktemp)"
  while IFS=$'\t' read -r status name kind track resolved inputs url; do
    [ -n "${status:-}" ] || continue
    case "$status" in \#*) continue ;; esac
    if [ "$status" = build ]; then
      url="${built_url[$name]:-}"
      if [ -z "$url" ]; then
        echo "No tarball URL for changed package $name" >&2
        return 1
      fi
    elif [ "$status" != keep ]; then
      echo "Bad plan status: $status" >&2
      return 1
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$track" "$resolved" "$inputs" "$url" >> "$list"
  done < "$plan"
  index_write "$out" "$abi" "$arch" "$gtk" "$created" "$list"
  rm -f "$list"
}

cmd_write() {
  local list="" abi="" arch="" gtk="" created="" out=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --list) list=$2; shift 2 ;;
      --abi) abi=$2; shift 2 ;;
      --arch) arch=$2; shift 2 ;;
      --gtk) gtk=$2; shift 2 ;;
      --created) created=$2; shift 2 ;;
      --out) out=$2; shift 2 ;;
      *) echo "Unknown argument: $1" >&2; return 2 ;;
    esac
  done
  index_write "$out" "$abi" "$arch" "$gtk" "$created" "$list"
}

cmd_packages() {
  local file=${1:-}
  [ -n "$file" ] || { echo "Usage: upstream-index.sh packages INDEX" >&2; return 2; }
  index_packages "$file"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  command=${1:-}
  shift || true
  case "$command" in
    resolve) cmd_resolve "$@" ;;
    plan) cmd_plan "$@" ;;
    assemble) cmd_assemble "$@" ;;
    write) cmd_write "$@" ;;
    packages) cmd_packages "$@" ;;
    *)
      echo "Usage: $0 resolve|plan|assemble|write|packages ..." >&2
      exit 2
      ;;
  esac
fi
