#!/usr/bin/env bash
# Move each wrap to the newest release on its version line.
# A branch name or a commit stays as written. The next build publishes the new source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES_DIR="${PACKAGES_DIR:-$ROOT/packages}"

version_core() {
  local tag=$1 core prefix
  core=${tag#v}
  core=${core#V}
  if [[ "$core" =~ ([0-9]+(\.[0-9]+)+)$ ]]; then
    prefix=${core%"${BASH_REMATCH[1]}"}
    case "$prefix" in
      ""|*-|*_)
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
        ;;
    esac
  fi
  return 1
}

version_gt() {
  local left=$1 right=$2 first
  [ "$left" = "$right" ] && return 1
  first="$(printf '%s\n%s\n' "$left" "$right" | sort -V | head -n1)"
  [ "$first" = "$right" ]
}

same_series() {
  local cur=$1 cand=$2 depth=$3 i
  local -a c d
  IFS=. read -r -a c <<< "$cur"
  IFS=. read -r -a d <<< "$cand"
  if [ "${c[0]}" = 0 ]; then
    depth=2
  fi
  for ((i = 0; i < depth; i++)); do
    [ "${c[i]:-}" = "${d[i]:-}" ] || return 1
  done
}

style_rank() {
  local current=$1 tag=$2
  case "$current" in
    v*|V*)
      case "$tag" in
        v*|V*) printf '0\n' ;;
        *) printf '1\n' ;;
      esac
      ;;
    *)
      case "$tag" in
        v*|V*) printf '1\n' ;;
        *) printf '0\n' ;;
      esac
      ;;
  esac
}

# Newest release tag on the current version line. Empty when none is newer.
pick_release() {
  local current=$1 depth=$2 file=$3 cand core cur_core best best_core rank best_rank
  cur_core="$(version_core "$current")" || return 0
  best=""
  best_core=""
  best_rank=9
  while IFS= read -r cand || [ -n "$cand" ]; do
    [ -n "$cand" ] || continue
    core="$(version_core "$cand")" || continue
    same_series "$cur_core" "$core" "$depth" || continue
    version_gt "$core" "$cur_core" || continue
    rank="$(style_rank "$current" "$cand")"
    if [ -z "$best" ] || version_gt "$core" "$best_core" || { [ "$core" = "$best_core" ] && [ "$rank" -lt "$best_rank" ]; }; then
      best=$cand
      best_core=$core
      best_rank=$rank
    fi
  done < "$file"
  printf '%s\n' "$best"
}

revision_is_fixed() {
  local rev=$1
  case "$rev" in
    ""|main|master|HEAD|head|trunk) return 0 ;;
  esac
  [[ "$rev" =~ ^[0-9a-f]{40}$ ]]
}

wrap_field() {
  local file=$1 key=$2
  sed -n "s/^${key}[[:space:]]*=[[:space:]]*//p" "$file" | head -n1 | tr -d '[:space:]'
}

set_field() {
  local file=$1 key=$2 value=$3 tmp
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    $0 ~ "^" key "[[:space:]]*=" && !found {
      print key " = " value
      found = 1
      next
    }
    { print }
    END { if (!found) exit 1 }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

series_depth() {
  local dir=$1
  if [ -d "$dir/packagefiles" ] && find "$dir/packagefiles" -type d -name generated-config | grep -q .; then
    printf '2\n'
  else
    printf '1\n'
  fi
}

fetch_to() {
  local url=$1 dest=$2
  curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$dest"
}

git_tags() {
  local url=$1 dest=$2
  git ls-remote --tags "$url" | awk '{ print $2 }' | sed -n 's|^refs/tags/||p' | sed 's/\^{}$//' | sort -u > "$dest"
}

update_git_wrap() {
  local wrap=$1 dir=$2 rev url depth tags chosen
  rev="$(wrap_field "$wrap" revision)"
  if revision_is_fixed "$rev"; then
    return 0
  fi
  version_core "$rev" >/dev/null || return 0
  url="$(wrap_field "$wrap" url)"
  [ -n "$url" ] || return 0
  depth="$(series_depth "$dir")"
  tags="$(mktemp)"
  git_tags "$url" "$tags"
  chosen="$(pick_release "$rev" "$depth" "$tags")"
  rm -f "$tags"
  [ -n "$chosen" ] || return 0
  set_field "$wrap" revision "$chosen"
  echo "$wrap: $rev -> $chosen"
}

upstream_of_wrapdb() {
  local ver=$1
  if [[ "$ver" =~ ^(.+)-[0-9]+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  printf '%s\n' "$ver"
}

update_wrapdb() {
  local wrap=$1 name current upstream best best_up ver up catalog versions chosen
  name="$(basename "$wrap")"
  name="${name%.wrap.pin}"
  name="${name%.wrap}"
  current="$(wrap_field "$wrap" wrapdb_version)"
  [ -n "$current" ] || return 0
  upstream="$(upstream_of_wrapdb "$current")"
  catalog="${WRAPDB_CATALOG:-}"
  if [ -z "$catalog" ]; then
    catalog="$(mktemp)"
    fetch_to "https://wrapdb.mesonbuild.com/v2/releases.json" "$catalog"
    WRAPDB_CATALOG=$catalog
  fi
  versions="$(mktemp)"
  jq -r --arg name "$name" '.[$name].versions[]?' "$catalog" > "$versions"
  best=""
  best_up=""
  while IFS= read -r ver || [ -n "$ver" ]; do
    [ -n "$ver" ] || continue
    up="$(upstream_of_wrapdb "$ver")"
    version_core "$up" >/dev/null || continue
    same_series "$upstream" "$up" 1 || continue
    version_gt "$up" "$upstream" || continue
    if [ -z "$best" ] || version_gt "$up" "$best_up"; then
      best=$ver
      best_up=$up
    fi
  done < "$versions"
  rm -f "$versions"
  [ -n "$best" ] || return 0
  fetch_to "https://github.com/mesonbuild/wrapdb/releases/download/${name}_${best}/${name}.wrap" "$wrap"
  echo "$wrap: $current -> $best"
}

hash_of() {
  sha256sum "$1" | awk '{ print $1 }'
}

update_gnome() {
  local wrap=$1 depth current cache name ext rel sumrel base url hash fallback fbbase tmp
  url="$(wrap_field "$wrap" source_url)"
  case "$url" in
    https://download.gnome.org/sources/*) ;;
    *) return 0 ;;
  esac
  name="$(printf '%s\n' "$url" | sed -n 's|https://download.gnome.org/sources/\([^/]*\)/.*|\1|p')"
  current="$(version_core "$(wrap_field "$wrap" source_filename)")" || return 0
  ext="${url##*.}"
  case "$url" in
    *.tar.xz) ext="tar.xz" ;;
    *.tar.gz) ext="tar.gz" ;;
    *.tar.bz2) ext="tar.bz2" ;;
  esac
  depth="$(series_depth "$(dirname "$wrap")")"
  cache="$(mktemp)"
  fetch_to "https://download.gnome.org/sources/${name}/cache.json" "$cache"
  tmp="$(mktemp)"
  jq -r --arg ext "$ext" --arg name "$name" '
    .[1][$name] | to_entries[]
    | select(.value[$ext] != null)
    | .key
  ' "$cache" > "$tmp"
  local chosen relpath
  chosen="$(pick_release "$current" "$depth" "$tmp")"
  if [ -z "$chosen" ]; then
    rm -f "$cache" "$tmp"
    return 0
  fi
  relpath="$(jq -r --arg ext "$ext" --arg name "$name" --arg ver "$chosen" '.[1][$name][$ver][$ext]' "$cache")"
  sumrel="$(jq -r --arg name "$name" --arg ver "$chosen" '.[1][$name][$ver].sha256sum // empty' "$cache")"
  rm -f "$cache" "$tmp"
  base="https://download.gnome.org/sources/${name}"
  hash=""
  if [ -n "$sumrel" ]; then
    tmp="$(mktemp)"
    fetch_to "${base}/${sumrel}" "$tmp"
    hash="$(awk -v file="$(basename "$relpath")" '$2 == file { print $1; exit }' "$tmp")"
    rm -f "$tmp"
  fi
  if [ -z "$hash" ]; then
    tmp="$(mktemp)"
    fetch_to "${base}/${relpath}" "$tmp"
    hash="$(hash_of "$tmp")"
    rm -f "$tmp"
  fi
  set_field "$wrap" source_url "${base}/${relpath}"
  set_field "$wrap" source_filename "$(basename "$relpath")"
  set_field "$wrap" source_hash "$hash"
  local directory
  directory="$(wrap_field "$wrap" directory)"
  if [ -n "$directory" ] && [ "$directory" != "${directory//"$current"/}" ]; then
    set_field "$wrap" directory "${directory//"$current"/"$chosen"}"
  fi
  fallback="$(wrap_field "$wrap" source_fallback_url || true)"
  if [ -n "$fallback" ]; then
    fbbase="$(printf '%s\n' "$fallback" | sed -n "s|\\(/sources/${name}/\\).*|\\1|p")"
    if [ -n "$fbbase" ]; then
      fbbase="${fallback%%/sources/${name}/*}/sources/${name}"
      set_field "$wrap" source_fallback_url "${fbbase}/${relpath}"
    fi
  fi
  echo "$wrap: $current -> $chosen"
}

update_github_file() {
  local wrap=$1 url current tag_ver org repo filename depth tags chosen new_ver new_file new_url tmp hash
  url="$(wrap_field "$wrap" source_url)"
  org="$(printf '%s\n' "$url" | sed -n 's|https://github.com/\([^/]*\)/\([^/]*\)/releases/download/\([^/]*\)/.*|\1|p')"
  repo="$(printf '%s\n' "$url" | sed -n 's|https://github.com/\([^/]*\)/\([^/]*\)/releases/download/\([^/]*\)/.*|\2|p')"
  tag_ver="$(printf '%s\n' "$url" | sed -n 's|https://github.com/\([^/]*\)/\([^/]*\)/releases/download/\([^/]*\)/.*|\3|p')"
  [ -n "$org" ] || return 0
  filename="$(wrap_field "$wrap" source_filename)"
  current="$(version_core "$filename")" || current="$(version_core "$tag_ver")" || return 0
  depth="$(series_depth "$(dirname "$wrap")")"
  tags="$(mktemp)"
  git_tags "https://github.com/${org}/${repo}.git" "$tags"
  chosen="$(pick_release "$tag_ver" "$depth" "$tags")"
  if [ -z "$chosen" ]; then
    chosen="$(pick_release "$current" "$depth" "$tags")"
  fi
  rm -f "$tags"
  [ -n "$chosen" ] || return 0
  new_ver="$(version_core "$chosen")"
  new_file="${filename//${current}/${new_ver}}"
  new_url="https://github.com/${org}/${repo}/releases/download/${chosen}/${new_file}"
  tmp="$(mktemp)"
  fetch_to "$new_url" "$tmp"
  hash="$(hash_of "$tmp")"
  rm -f "$tmp"
  set_field "$wrap" source_url "$new_url"
  set_field "$wrap" source_filename "$new_file"
  set_field "$wrap" source_hash "$hash"
  local directory
  directory="$(wrap_field "$wrap" directory)"
  if [ -n "$directory" ] && [ "$directory" != "${directory//"$current"/}" ]; then
    set_field "$wrap" directory "${directory//"$current"/"$new_ver"}"
  fi
  echo "$wrap: $current -> $new_ver"
}

sqlite_version() {
  local n=$1 major minor patch
  major=$((n / 1000000))
  minor=$(((n / 10000) % 100))
  patch=$(((n / 100) % 100))
  printf '%s.%s.%s\n' "$major" "$minor" "$patch"
}

update_sqlite() {
  local wrap=$1 url number current page lines chosen ver rel hash tmp depth
  url="$(wrap_field "$wrap" source_url)"
  case "$url" in
    https://www.sqlite.org/*) ;;
    *) return 0 ;;
  esac
  number="$(printf '%s\n' "$url" | sed -n 's/.*sqlite-amalgamation-\([0-9][0-9]*\)\.zip/\1/p')"
  [ -n "$number" ] || return 0
  current="$(sqlite_version "$number")"
  depth="$(series_depth "$(dirname "$wrap")")"
  page="$(mktemp)"
  lines="$(mktemp)"
  fetch_to "https://www.sqlite.org/download.html" "$page"
  awk -F, '/^PRODUCT,/ && $3 ~ /sqlite-amalgamation-[0-9]+\.zip$/ { print $2 }' "$page" > "$lines"
  chosen="$(pick_release "$current" "$depth" "$lines")"
  if [ -z "$chosen" ]; then
    rm -f "$page" "$lines"
    return 0
  fi
  rel="$(awk -F, -v ver="$chosen" '$2 == ver && $3 ~ /sqlite-amalgamation-[0-9]+\.zip$/ { print $3; exit }' "$page")"
  rm -f "$page" "$lines"
  tmp="$(mktemp)"
  fetch_to "https://www.sqlite.org/${rel}" "$tmp"
  hash="$(hash_of "$tmp")"
  rm -f "$tmp"
  number="$(printf '%s\n' "$rel" | sed -n 's/.*sqlite-amalgamation-\([0-9][0-9]*\)\.zip/\1/p')"
  set_field "$wrap" source_url "https://www.sqlite.org/${rel}"
  set_field "$wrap" source_filename "sqlite-amalgamation-${number}.zip"
  set_field "$wrap" source_hash "$hash"
  set_field "$wrap" directory "sqlite-amalgamation-${number}"
  echo "$wrap: $current -> $chosen"
}

update_openssl() {
  local wrap=$1 url current depth tags chosen new_ver hash tmp dest
  url="$(wrap_field "$wrap" source_url)"
  case "$url" in
    https://www.openssl.org/source/*) ;;
    *) return 0 ;;
  esac
  current="$(version_core "$(wrap_field "$wrap" source_filename)")" || return 0
  depth="$(series_depth "$(dirname "$wrap")")"
  tags="$(mktemp)"
  git_tags "https://github.com/openssl/openssl.git" "$tags"
  chosen="$(pick_release "$current" "$depth" "$tags")"
  rm -f "$tags"
  [ -n "$chosen" ] || return 0
  new_ver="$(version_core "$chosen")"
  dest="$(mktemp)"
  if ! fetch_to "https://www.openssl.org/source/openssl-${new_ver}.tar.gz" "$dest"; then
    rm -f "$dest"
    dest="$(mktemp)"
    fetch_to "https://www.openssl.org/source/old/${new_ver%.*}/openssl-${new_ver}.tar.gz" "$dest"
    url="https://www.openssl.org/source/old/${new_ver%.*}/openssl-${new_ver}.tar.gz"
  else
    url="https://www.openssl.org/source/openssl-${new_ver}.tar.gz"
  fi
  hash="$(hash_of "$dest")"
  rm -f "$dest"
  set_field "$wrap" source_url "$url"
  set_field "$wrap" source_filename "openssl-${new_ver}.tar.gz"
  set_field "$wrap" source_hash "$hash"
  local directory
  directory="$(wrap_field "$wrap" directory)"
  if [ -n "$directory" ] && [ "$directory" != "${directory//"$current"/}" ]; then
    set_field "$wrap" directory "${directory//"$current"/"$new_ver"}"
  fi
  echo "$wrap: $current -> $new_ver"
}

update_file_wrap() {
  local wrap=$1
  if [ -n "$(wrap_field "$wrap" wrapdb_version)" ]; then
    update_wrapdb "$wrap"
    return 0
  fi
  case "$(wrap_field "$wrap" source_url)" in
    https://download.gnome.org/sources/*) update_gnome "$wrap" ;;
    https://github.com/*/releases/download/*) update_github_file "$wrap" ;;
    https://www.sqlite.org/*) update_sqlite "$wrap" ;;
    https://www.openssl.org/source/*) update_openssl "$wrap" ;;
  esac
}

update_wrap() {
  local wrap=$1 dir
  [ -f "$wrap" ] || return 0
  dir="$(dirname "$wrap")"
  if grep -q '^\[wrap-git\]' "$wrap"; then
    update_git_wrap "$wrap" "$dir"
  elif grep -q '^\[wrap-file\]' "$wrap"; then
    update_file_wrap "$wrap"
  fi
}

update_all() {
  local wrap
  shopt -s nullglob
  for wrap in "$PACKAGES_DIR"/*/*.wrap "$PACKAGES_DIR"/*/*.wrap.pin; do
    update_wrap "$wrap"
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  update_all
fi
