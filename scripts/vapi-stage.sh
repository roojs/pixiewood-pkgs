#!/usr/bin/env bash
# Install Vala API (.vapi) files into a package destdir when Meson does not.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  echo "Usage: $0 --package NAME --destdir DIR [--abi ABI] [--cross-cc PATH]" >&2
  exit 2
}

package=""
destdir=""
abi=""
cross_cc=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --package) package=$2; shift 2 ;;
    --destdir) destdir=$2; shift 2 ;;
    --abi) abi=$2; shift 2 ;;
    --cross-cc) cross_cc=$2; shift 2 ;;
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

host_vapidir() {
  valac --print-vapidir 2>/dev/null || true
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
  vapidir="$(host_vapidir)"
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

stage_libadwaita_vapi() {
  local vendored="$ROOT/packages/libadwaita/vapi/libadwaita-1.vapi"
  if [ ! -f "$vendored" ]; then
    echo "vendored libadwaita VAPI missing: $vendored" >&2
    exit 1
  fi
  mkdir -p "$vapi_dir"
  cp -f "$vendored" "$vapi_dir/libadwaita-1.vapi"
}

case "$package" in
  gtk)
    if have_vapi 'gtk4.vapi'; then
      exit 0
    fi
    # GObject Introspection stays off for the Android GTK build. VAPI only when
    # GIR files were installed some other way (for example a future host scan).
    if [ -d "$gir_dir" ] && compgen -G "$gir_dir/*.gir" >/dev/null; then
      vapigen_gtk
      require_vapi 'gtk4.vapi' 'gtk4.vapi'
    fi
    exit 0
    ;;
  libadwaita)
    if ! have_vapi 'libadwaita-1.vapi'; then
      stage_libadwaita_vapi
    fi
    require_vapi 'libadwaita-1.vapi' 'libadwaita-1.vapi'
    ;;
  gtksourceview)
    if have_vapi 'gtksourceview-5.vapi'; then
      exit 0
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac

echo "Staged Vala API for $package in $vapi_dir"