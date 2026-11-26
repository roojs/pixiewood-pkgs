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

scan_libadwaita() {
  local libdir inc meta system_gir vapidir lib
  if ! command -v g-ir-scanner >/dev/null 2>&1; then
    echo "g-ir-scanner is required to build libadwaita VAPI files" >&2
    exit 1
  fi
  if ! command -v vapigen >/dev/null 2>&1; then
    echo "vapigen is required to build libadwaita VAPI files" >&2
    exit 1
  fi
  if [ -z "$abi" ]; then
    echo "libadwaita VAPI staging needs --abi" >&2
    exit 1
  fi
  libdir="$destdir/lib/$abi"
  inc="$destdir/include/libadwaita-1"
  meta="$ROOT/packages/libadwaita/gir"
  lib="$libdir/libadwaita-1.so"
  if [ ! -f "$lib" ]; then
    echo "libadwaita library missing: $lib" >&2
    exit 1
  fi
  if [ ! -f "$inc/adwaita.h" ]; then
    echo "libadwaita header missing: $inc/adwaita.h" >&2
    exit 1
  fi
  mkdir -p "$gir_dir" "$vapi_dir"
  system_gir=/usr/share/gir-1.0
  if [ ! -d "$system_gir" ]; then
    echo "Host GIR directory missing: $system_gir" >&2
    exit 1
  fi
  export PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1
  export PKG_CONFIG_ALLOW_SYSTEM_LIBS=1
  if [ -n "$cross_cc" ]; then
    export CC="$cross_cc"
    export LD="$cross_cc"
  fi
  g-ir-scanner \
    --quiet \
    --warn-all \
    --no-libtool \
    --namespace=Adw \
    --nsversion=1 \
    --identifier-prefix=Adw \
    --symbol-prefix=adw \
    --pkg=libadwaita-1 \
    --pkg-export=libadwaita-1 \
    --library=adwaita-1 \
    --includes=Gio-2.0,Gtk-4.0 \
    --add-include-path="$system_gir" \
    -L"$libdir" \
    -ladwaita-1 \
    --cflags-begin \
    -I"$inc" \
    -I"$destdir/include" \
    -DADWAITA_COMPILATION \
    --cflags-end \
    -o "$gir_dir/Adw-1.gir" \
    "$inc/adwaita.h"
  vapidir="$(host_vapidir)"
  vapigen_args=(--quiet "--vapidir=$vapi_dir" "--girdir=$gir_dir" --pkg=gio-2.0 --pkg=gtk4)
  if [ -d "$meta" ]; then
    vapigen_args+=("--metadatadir=$meta")
  fi
  if [ -n "$vapidir" ] && [ -d "$vapidir" ]; then
    vapigen_args+=("--vapidir=$vapidir")
  fi
  vapigen_args+=(libadwaita-1 Adw-1.gir)
  (
    cd "$gir_dir"
    vapigen "${vapigen_args[@]}"
  )
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
      scan_libadwaita
    fi
    require_vapi 'libadwaita-1.vapi' 'libadwaita-1.vapi'
    ;;
  gtksourceview)
    if have_vapi 'gtksourceview-5.vapi'; then
      exit 0
    fi
    # GtkSourceView uses the same host-scan pattern as libadwaita when Meson GI is off.
    exit 0
    ;;
  *)
    exit 0
    ;;
esac

echo "Staged Vala API for $package in $vapi_dir"