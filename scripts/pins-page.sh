#!/usr/bin/env bash
# release.pins and snapshot.pins are published on this project's GitHub Pages site.
# fetch copies that site into the working tree.
# stage writes the site. A row this run did not change stays as it is on the site.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=upstream-index.sh
source "$ROOT/scripts/upstream-index.sh"

dest="$ROOT"
url=""
repo="${GITHUB_REPOSITORY:-roojs/pixiewood-pkgs}"
out=""

usage() {
  echo "Usage: $0 fetch [--dest DIR] [--repo OWNER/NAME] [--url URL]" >&2
  echo "       $0 stage --out DIR [--dest DIR] [--repo OWNER/NAME] [--url URL]" >&2
  exit 2
}

if [ "$#" -eq 0 ]; then
  usage
fi
cmd=$1
shift

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dest) dest=$2; shift 2 ;;
    --repo) repo=$2; shift 2 ;;
    --url) url=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

pages_url() {
  local owner name
  if [ -n "$url" ]; then
    printf '%s\n' "${url%/}"
    return 0
  fi
  owner="${repo%%/*}"
  name="${repo#*/}"
  if [ -z "$owner" ] || [ -z "$name" ] || [ "$owner" = "$name" ]; then
    echo "Repository must be OWNER/NAME: $repo" >&2
    return 1
  fi
  printf 'https://%s.github.io/%s\n' "$owner" "$name"
}

base_dir() {
  if [ "$dest" = "$ROOT" ]; then
    printf '%s\n' "$ROOT/out/pins-page-base"
  else
    printf '%s\n' "$dest/.pins-page-base"
  fi
}

valid_pins() {
  jq -e '.packages | type == "array"' "$1" >/dev/null 2>&1
}

# 0: the file was downloaded. 2: the site has no such file. 1: the site could not be read.
download_pins() {
  local name=$1 destfile=$2 page tmp err status code
  page="$(pages_url)" || return 1
  tmp="$(mktemp)"
  err="$(mktemp)"
  status=0
  code="$(curl -sS -L --retry 3 --retry-delay 2 -o "$tmp" -w '%{http_code}' "${page}/${name}" 2>"$err")" || status=$?
  if [ "$status" -eq 0 ] && valid_pins "$tmp"; then
    mkdir -p "$(dirname "$destfile")"
    cp "$tmp" "$destfile"
    rm -f "$tmp" "$err"
    return 0
  fi
  rm -f "$tmp"
  if [ "$code" = "404" ] || [ "$status" -eq 37 ]; then
    rm -f "$err"
    return 2
  fi
  echo "Could not download ${page}/${name}" >&2
  cat "$err" >&2
  rm -f "$err"
  return 1
}

merge_pins() {
  local localfile=$1 basefile=$2 remotefile=$3 outfile=$4
  jq -n \
    --slurpfile local "$localfile" \
    --slurpfile base "$basefile" \
    --slurpfile remote "$remotefile" '
      def key: [.abi, (.repo // ""), .name];
      def find($rows; $row):
        [$rows[] | select(key == ($row | key))] | .[0];
      ($local[0].packages // []) as $local_pkgs
      | ($base[0].packages // []) as $base_pkgs
      | ($remote[0].packages // []) as $remote_pkgs
      | [ $local_pkgs[]
          | . as $row
          | select((find($base_pkgs; $row) == null) or (find($base_pkgs; $row) != $row))
        ] as $changed
      | reduce $changed[] as $row ($remote_pkgs;
          if any(.[]; key == ($row | key)) then
            map(if key == ($row | key) then $row else . end)
          else
            . + [$row]
          end)
      | {packages: .}
    ' > "$outfile"
}

cmd_fetch() {
  local base name got
  base="$(base_dir)"
  mkdir -p "$base" "$dest"
  for name in release.pins snapshot.pins; do
    got=0
    download_pins "$name" "$dest/$name" || got=$?
    if [ "$got" -eq 0 ]; then
      cp "$dest/$name" "$base/$name"
    elif [ "$got" -eq 2 ] && [ -f "$dest/$name" ]; then
      cp "$dest/$name" "$base/$name"
    elif [ "$got" -eq 2 ]; then
      echo "Pin file is missing: $dest/$name" >&2
      return 1
    else
      return 1
    fi
  done
}

html_text() {
  local s=$1
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  s=${s//\"/&quot;}
  printf '%s' "$s"
}

pins_rows_html() {
  local site=$1 rows name side label url abi count first line
  rows="$(mktemp)"
  pins_collect() {
    local file=$1 side=$2 name abi track url label abi_label
    [ -f "$file" ] || return 0
    while IFS=$'\t' read -r name abi track url; do
      [ -n "${name:-}" ] || continue
      label="$(package_track_label "$track")"
      abi_label="$(package_abi_label "$abi")"
      printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$side" "$abi_label" "$label" "$url" >> "$rows"
    done < <(jq -r '.packages[] | [.name, .abi, .track, (.url // "")] | @tsv' "$file")
  }
  pins_collect "$site/release.pins" release
  pins_collect "$site/snapshot.pins" snapshot

  pins_cell() {
    local name=$1 side=$2 matches uniq
    matches="$(awk -F '\t' -v n="$name" -v s="$side" '$1 == n && $2 == s' "$rows")"
    if [ -z "$matches" ]; then
      printf '<td class="none">—</td>'
      return 0
    fi
    uniq="$(printf '%s\n' "$matches" | awk -F '\t' '{ print $4 }' | sort -u | wc -l)"
    printf '<td>'
    if [ "$uniq" -eq 1 ]; then
      IFS=$'\t' read -r _ _ _ label url <<< "$(printf '%s\n' "$matches" | head -n1)"
      if [ -n "$url" ]; then
        printf '<a href="%s">%s</a>' "$(html_text "$url")" "$(html_text "$label")"
      else
        printf '%s' "$(html_text "$label")"
      fi
    else
      first=1
      while IFS=$'\t' read -r _ _ abi label url; do
        [ "$first" -eq 1 ] || printf '<br>'
        first=0
        if [ -n "$url" ]; then
          printf '<a href="%s">%s</a> %s' "$(html_text "$url")" "$(html_text "$label")" "$(html_text "$abi")"
        else
          printf '%s %s' "$(html_text "$label")" "$(html_text "$abi")"
        fi
      done <<< "$matches"
    fi
    printf '</td>'
  }

  : > "$rows.names"
  if [ -f "$ROOT/build-order.txt" ]; then
    while IFS= read -r name || [ -n "$name" ]; do
      name=${name%%#*}
      name=${name#"${name%%[![:space:]]*}"}
      name=${name%"${name##*[![:space:]]}"}
      [ -n "$name" ] || continue
      if awk -F '\t' -v n="$name" '$1 == n { found = 1 } END { exit !found }' "$rows"; then
        printf '%s\n' "$name" >> "$rows.names"
      fi
    done < "$ROOT/build-order.txt"
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! grep -qx "$name" "$rows.names"; then
      printf '%s\n' "$name" >> "$rows.names"
    fi
  done < <(awk -F '\t' '{ print $1 }' "$rows" | sort -u)

  while IFS= read -r name || [ -n "$name" ]; do
    [ -n "$name" ] || continue
    printf '<tr><th scope="row">%s</th>' "$(html_text "$name")"
    pins_cell "$name" release
    pins_cell "$name" snapshot
    printf '</tr>\n'
  done < "$rows.names"
  rm -f "$rows" "$rows.names"
}

write_index() {
  local site=$1 table
  table="$(pins_rows_html "$site")"
  cat > "$site/index.html" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>pixiewood-pkgs</title>
  <style>
    body { font-family: sans-serif; max-width: 40rem; margin: 2rem auto; padding: 0 1rem; color: #1c1c1c; }
    table { border-collapse: collapse; width: 100%; margin-top: 1.5rem; }
    th, td { text-align: left; padding: 0.35rem 0.75rem; border-bottom: 1px solid #ddd; }
    thead th { border-bottom: 2px solid #1c1c1c; }
    td.none { color: #888; }
    a { color: inherit; }
  </style>
</head>
<body>
  <h1>pixiewood-pkgs</h1>
  <p>These are the package lists for the Android libraries. A pin names a <code>.pixie</code> file on a GitHub release. <a href="https://github.com/roojs/pixie-pkg">pixie-pkg</a> reads these files and installs the libraries.</p>
  <ul>
    <li><a href="release.pins"><code>release.pins</code></a> is the released versions. The version is the file name, for example <code>openssl-arm-v31-3.0.8.pixie</code>.</li>
    <li><a href="snapshot.pins"><code>snapshot.pins</code></a> is HEAD. Those files are named <code>snapshot</code>. GTK HEAD is the snapshot that matters. The other libraries in that list are the ones that build needs from there.</li>
  </ul>
  <table>
    <thead>
      <tr><th scope="col">Package</th><th scope="col">Release</th><th scope="col">Snapshot</th></tr>
    </thead>
    <tbody>
${table}
    </tbody>
  </table>
</body>
</html>
EOF
}

cmd_stage() {
  local base name fresh empty site got
  if [ -z "$out" ]; then
    usage
  fi
  base="$(base_dir)"
  site="$out"
  mkdir -p "$site"
  for name in release.pins snapshot.pins; do
    if [ ! -f "$dest/$name" ]; then
      echo "Pin file is missing: $dest/$name" >&2
      return 1
    fi
    fresh="$(mktemp)"
    got=0
    download_pins "$name" "$fresh" || got=$?
    if [ "$got" -eq 0 ]; then
      if [ ! -f "$base/$name" ]; then
        empty="$(mktemp)"
        jq -n '{packages:[]}' > "$empty"
        merge_pins "$dest/$name" "$empty" "$fresh" "$site/$name"
        rm -f "$empty"
      else
        merge_pins "$dest/$name" "$base/$name" "$fresh" "$site/$name"
      fi
    elif [ "$got" -eq 2 ]; then
      cp "$dest/$name" "$site/$name"
    else
      rm -f "$fresh"
      return 1
    fi
    rm -f "$fresh"
  done
  write_index "$site"
}

case "$cmd" in
  fetch) cmd_fetch ;;
  stage) cmd_stage ;;
  *) echo "Unknown command: $cmd" >&2; usage ;;
esac
