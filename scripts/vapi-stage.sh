#!/usr/bin/env bash
# Install Vala API (.vapi) files into a package destdir when Meson does not.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  echo "Usage: $0 --package NAME --destdir DIR" >&2
  exit 2
}

package=""
destdir=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --package) package=$2; shift 2 ;;
    --destdir) destdir=$2; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

if [ -z "$package" ] || [ -z "$destdir" ]; then
  usage
fi
if [ ! -d "$destdir" ]; then
  echo "Destdir missing: $destdir" >&2
  exit 1
fi

vapi_dir="$destdir/share/vala/vapi"
gir_dir="$destdir/share/gir-1.0"

have_vapi() {
  local pattern=$1
  [ -d "$vapi_dir" ] && compgen -G "$vapi_dir/$pattern" >/dev/null
}

require_vapi() {
  local pattern=$1 label=$2
  if ! have_vapi "$pattern"; then
    echo "$package pixie is missing $label under $vapi_dir" >&2
    exit 1
  fi
}

vapigen_gtk() {
  local gir vapidir
  if ! command -v vapigen >/dev/null 2>&1; then
    echo "vapigen is required to build gtk VAPI files" >&2
    exit 1
  fi
  if [ ! -d "$gir_dir" ]; then
    echo "gtk pixie is missing GIR files under $gir_dir" >&2
    exit 1
  fi
  mkdir -p "$vapi_dir"
  mapfile -t girs < <(find "$gir_dir" -maxdepth 1 -type f -name '*.gir' -printf '%f\n' | LC_ALL=C sort)
  if [ "${#girs[@]}" -eq 0 ]; then
    echo "gtk pixie has no GIR files to generate VAPI from" >&2
    exit 1
  fi
  vapidir="$(valac --print-vapidir 2>/dev/null || true)"
  args=(--quiet "--vapidir=$vapi_dir" "--girdir=$gir_dir" --library=gtk-4.0 --pkg=gio-2.0)
  if [ -n "$vapidir" ] && [ -d "$vapidir" ]; then
    args+=("--vapidir=$vapidir")
  fi
  for gir in "${girs[@]}"; do
    args+=("$gir")
  done
  (
    cd "$gir_dir"
    vapigen "${args[@]}"
  )
}

case "$package" in
  gtk)
    if have_vapi 'gtk4.vapi'; then
      exit 0
    fi
    vapigen_gtk
    require_vapi 'gtk4.vapi' 'gtk4.vapi'
    ;;
  libadwaita)
    require_vapi 'libadwaita-1.vapi' 'libadwaita-1.vapi'
    ;;
  gtksourceview)
    require_vapi 'gtksourceview-5.vapi' 'gtksourceview-5.vapi'
    ;;
  *)
    exit 0
    ;;
esac

echo "Staged Vala API for $package in $vapi_dir"