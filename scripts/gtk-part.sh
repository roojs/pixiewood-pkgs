#!/usr/bin/env bash
# Split the GTK source tree so GDK can be built on its own.
# patch SRC applies the option to a checkout. The default part is all.
# pack BUILDDIR DESTDIR ABI installs the static archives and pixiewood-gdk.pc.
set -euo pipefail

patch_tree() {
  local src=$1 meson options
  meson="$src/meson.build"
  if [ ! -f "$meson" ]; then
    echo "GTK meson.build missing: $meson" >&2
    return 1
  fi
  if [ -f "$src/meson.options" ]; then
    options="$src/meson.options"
  elif [ -f "$src/meson_options.txt" ]; then
    options="$src/meson_options.txt"
  else
    echo "GTK meson options file missing under $src" >&2
    return 1
  fi
  if ! grep -q "pixiewood-part" "$options"; then
    cat >> "$options" << 'EOF'

option(
  'pixiewood-part',
  type: 'combo',
  choices: ['all', 'gdk', 'gtk'],
  value: 'all',
  description: 'Build GDK separately from GTK',
)
EOF
  fi
  if ! grep -q 'pixiewood_part' "$meson"; then
    local tmp
    tmp="$(mktemp)"
    awk '
      BEGIN { state = 0 }
      state == 0 && $0 == "subdir('\''gdk/version'\'')" {
        print "pixiewood_part = get_option('\''pixiewood-part'\'')"
        print
        state = 1
        next
      }
      state == 1 && $0 == "subdir('\''gdk'\'')" {
        print "if pixiewood_part == '\''gtk'\''"
        print "  libgdk_dep = dependency('\''pixiewood-gdk'\'')"
        print "  gdk_link = []"
        print "else"
        print "  subdir('\''gdk'\'')"
        print "  gdk_link = [libgdk]"
        print "endif"
        print "if pixiewood_part != '\''gdk'\''"
        state = 2
        next
      }
      { print }
      END {
        if (state == 2) {
          print "endif"
        } else {
          exit 2
        }
      }
    ' "$meson" > "$tmp" || {
      echo "Could not split GDK out of $meson" >&2
      rm -f "$tmp"
      return 1
    }
    mv "$tmp" "$meson"
  fi
  local file
  for file in "$src/gtk/meson.build" "$src/gsk/meson.build"; do
    [ -f "$file" ] || continue
    if grep -q 'gdk_link' "$file"; then
      continue
    fi
    sed -i \
      -e 's/link_with: \[libgtk_css, libgtk_svg, libgdk, libgsk \],/link_with: [libgtk_css, libgtk_svg, libgsk] + gdk_link,/' \
      -e 's/link_whole: \[libgtk_static, libgtk_css, libgtk_svg, libgdk, libgsk \],/link_whole: [libgtk_static, libgtk_css, libgtk_svg, libgsk] + gdk_link,/' \
      -e 's/link_with: \[libgtk_static, libgtk_css, libgdk, libgsk \],/link_with: [libgtk_static, libgtk_css, libgsk] + gdk_link,/' \
      -e 's/link_with: \[ libgdk, libgsk_f16c\],/link_with: [libgsk_f16c] + gdk_link,/' \
      "$file"
  done
}

pack_archives() {
  local builddir=$1 destdir=$2 abi=$3
  local libdir="$destdir/lib/$abi" archive base name flags
  if [ ! -d "$builddir" ] || [ ! -d "$destdir" ]; then
    echo "GDK pack needs a build directory and a destdir" >&2
    return 1
  fi
  mkdir -p "$libdir/pkgconfig"
  flags=""
  while IFS= read -r archive; do
    [ -n "$archive" ] || continue
    base="$(basename "$archive")"
    cp -a "$archive" "$libdir/$base"
    name="${base#lib}"
    name="${name%.a}"
    flags="$flags -l$name"
  done < <(find "$builddir" -type f -name '*.a' | LC_ALL=C sort)
  if [ -z "$flags" ]; then
    echo "GDK build produced no static libraries in $builddir" >&2
    return 1
  fi
  cat > "$libdir/pkgconfig/pixiewood-gdk.pc" << EOF
prefix=/
libdir=\${prefix}/lib/${abi}
includedir=\${prefix}/include

Name: pixiewood-gdk
Description: GDK from the GTK build
Version: 4
Libs: -L\${libdir} -Wl,--start-group -Wl,--whole-archive${flags} -Wl,--no-whole-archive -Wl,--end-group
Cflags: -I\${includedir}/gtk-4.0
EOF
}

command=${1:-}
shift || true
case "$command" in
  patch)
    [ -n "${1:-}" ] || { echo "Usage: $0 patch SRC" >&2; exit 2; }
    patch_tree "$1"
    ;;
  pack)
    [ "$#" -eq 3 ] || { echo "Usage: $0 pack BUILDDIR DESTDIR ABI" >&2; exit 2; }
    pack_archives "$1" "$2" "$3"
    ;;
  *)
    echo "Usage: $0 patch SRC | pack BUILDDIR DESTDIR ABI" >&2
    exit 2
    ;;
esac
