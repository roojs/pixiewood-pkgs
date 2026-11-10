#!/usr/bin/env bash
# release.pins and snapshot.pins are published on this project's GitHub Pages site.
# fetch copies that site into the working tree.
# stage writes the site. A row this run did not change stays as it is on the site.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

write_index() {
  local site=$1
  cat > "$site/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>pixiewood-pkgs</title>
</head>
<body>
  <h1>pixiewood-pkgs</h1>
  <p>These are the package lists for the Android libraries. A pin names a <code>.pixie</code> file on a GitHub release. <a href="https://github.com/roojs/pixie-pkg">pixie-pkg</a> reads these files and installs the libraries.</p>
  <ul>
    <li><a href="release.pins"><code>release.pins</code></a> is the released versions. The version is the file name, for example <code>openssl-arm-v31-3.0.8.pixie</code>.</li>
    <li><a href="snapshot.pins"><code>snapshot.pins</code></a> is HEAD. Those files are named <code>snapshot</code>. GTK HEAD is the snapshot that matters. The other libraries in that list are the ones that build needs from there.</li>
  </ul>
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
