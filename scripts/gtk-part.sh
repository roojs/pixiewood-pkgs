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
    # config.h is written after the subdirs because gtk/meson.build still
    # adds to cdata. A GDK-only build must still generate it: gtk/css and
    # gdk include it, and the file is otherwise inside the skipped tail.
    # pkg_config.generate(libgtk) stays in that tail.
    awk '
      BEGIN { state = 0 }
      state == 0 && $0 == "subdir('\''gdk/version'\'')" {
        print "pixiewood_part = get_option('\''pixiewood-part'\'')"
        print
        state = 1
        next
      }
      state == 1 && $0 == "subdir('\''gdk'\'')" {
        print "subdir('\''gdk'\'')"
        print "if pixiewood_part == '\''gtk'\''"
        print "  gdk_link = []"
        print "else"
        print "  gdk_link = [libgdk]"
        print "endif"
        print "if pixiewood_part != '\''gdk'\''"
        state = 2
        next
      }
      state == 2 && $0 ~ /^# config\.h[[:space:]]*$/ {
        print "endif"
        print
        state = 3
        next
      }
      state == 3 && index($0, "configuration: cdata)") {
        print
        print "if pixiewood_part != '\''gdk'\''"
        state = 4
        next
      }
      { print }
      END {
        if (state == 4) {
          print "endif"
        } else {
          print "gtk-part split stopped in state " state > "/dev/stderr"
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
    if grep -Eq 'link_(with|whole):[^#]*\blibgdk\b' "$file"; then
      echo "GTK still links libgdk directly in $file" >&2
      grep -nE 'link_(with|whole):[^#]*\blibgdk\b' "$file" >&2
      return 1
    fi
  done
  if [ -f "$src/gtk/meson.build" ]; then
    patch_gtk_gdk_link "$src/gtk/meson.build"
  fi
  # GTK's typefuncs target needs gdkenum_h and gdkinc from this file.
  # A GTK build that reuses a GDK package still configures those headers,
  # and links the package instead of compiling libgdk again.
  if [ -f "$src/gdk/meson.build" ]; then
    patch_gdk_library "$src/gdk/meson.build"
  fi
}

patch_gdk_library() {
  local meson=$1 tmp
  if grep -q "pixiewood_part != 'gtk'" "$meson"; then
    return 0
  fi
  if ! grep -qx 'gdk_backends = \[\]' "$meson"; then
    echo "GDK meson.build has no backend list to split: $meson" >&2
    return 1
  fi
  tmp="$(mktemp)"
  awk '
    BEGIN { state = 0 }
    state == 0 && $0 == "gdk_backends = []" {
      print "if pixiewood_part != '\''gtk'\''"
      print "  pixiewood_gdk_link = []"
      print
      state = 1
      next
    }
    state == 1 && $0 == "libgdk_dep = declare_dependency(" {
      print
      state = 2
      next
    }
    state == 2 && $0 == ")" {
      print
      print "else"
      print "  # Link the packaged GDK into libgtk only. Tools already link"
      print "  # libgtk-4.so, and a second copy of libgdk.a cannot see the"
      print "  # CSS and GSK symbols hidden inside that shared library."
      print "  pixiewood_gdk_link = [dependency('\''pixiewood-gdk'\'')]"
      print "  libgdk_dep = declare_dependency("
      print "    sources: ['\''gdk.h'\'', gdk_gen_headers],"
      print "    include_directories: [confinc, gdkx11_inc, wlinc],"
      print "    dependencies: gdk_deps + [libgtk_css_dep],"
      print "  )"
      print "endif"
      state = 3
      next
    }
    { print }
    END {
      if (state != 3) {
        print "gdk library split stopped in state " state > "/dev/stderr"
        exit 2
      }
    }
  ' "$meson" > "$tmp" || {
    echo "Could not split the GDK library out of $meson" >&2
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$meson"
}

# The shared GTK library links the packaged GDK once. The public gtk
# dependency must not repeat that link: executables already link libgtk-4.so.
patch_gtk_gdk_link() {
  local meson=$1 tmp
  if ! grep -q "shared_library('gtk-4'" "$meson"; then
    return 0
  fi
  tmp="$(mktemp)"
  awk '
    BEGIN { target = "" }
    $0 ~ /static_library\('"'"'gtk'"'"'/ { target = "static" }
    $0 ~ /shared_library\('"'"'gtk-4'"'"'/ { target = "shared" }
    $0 ~ /^libgtk_dep = declare_dependency/ { target = "public" }
    $0 ~ /^libgtk_static_dep = declare_dependency/ { target = "static_dep" }
    target == "shared" && $0 ~ /^  dependencies: gtk_deps \+ \[libgtk_css_dep, libgtk_svg_dep, libgdk_dep, libgsk_dep\],$/ {
      sub(/,$/, "")
      print $0 " + pixiewood_gdk_link,"
      linked = 1
      next
    }
    target == "static" && $0 ~ /^  dependencies: gtk_deps \+ \[libgtk_css_dep, libgtk_svg_dep, libgdk_dep, libgsk_dep, media_deps, print_backend_deps\],$/ {
      sub(/,$/, "")
      print $0 " + pixiewood_gdk_link,"
      next
    }
    target == "static_dep" && $0 ~ /^  dependencies: gtk_deps \+ \[libgtk_css_dep, libgtk_svg_dep, libgdk_dep, libgsk_dep\],$/ {
      sub(/,$/, "")
      print $0 " + pixiewood_gdk_link,"
      next
    }
    { print }
    END {
      if (!linked) {
        print "GTK shared library did not gain the packaged GDK link" > "/dev/stderr"
        exit 2
      }
    }
  ' "$meson" > "$tmp" || {
    echo "Could not attach the packaged GDK to libgtk in $meson" >&2
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$meson"
}

archive_members() {
  local archive=$1
  if command -v ar >/dev/null 2>&1 && ar t "$archive" >/dev/null 2>&1; then
    ar t "$archive" | LC_ALL=C sort -u
    return 0
  fi
  if command -v llvm-ar >/dev/null 2>&1 && llvm-ar t "$archive" >/dev/null 2>&1; then
    llvm-ar t "$archive" | LC_ALL=C sort -u
    return 0
  fi
  return 1
}

# Meson writes static libraries as thin archives. Their members are paths
# back into the build tree, so a copied archive cannot be linked later.
# GNU ar MRI addlib stores the object bytes in a normal archive.
copy_archive() {
  local src=$1 dest=$2 magic staging
  magic="$(head -c 8 "$src" || true)"
  if [ "$magic" != '!<thin>' ]; then
    cp -a "$src" "$dest"
    return 0
  fi
  staging="$(mktemp -d)"
  ar -M << EOF
create $staging/lib.a
addlib $src
save
end
EOF
  mv "$staging/lib.a" "$dest"
  rmdir "$staging"
}

pack_archives() {
  local builddir=$1 destdir=$2 abi=$3
  local libdir="$destdir/lib/$abi" gdk_build libgdk archive base name flags header rel listed
  if [ ! -d "$builddir" ] || [ ! -d "$destdir" ]; then
    echo "GDK pack needs a build directory and a destdir" >&2
    return 1
  fi
  gdk_build="$builddir/subprojects/gtk/gdk"
  libgdk="$gdk_build/libgdk.a"
  if [ ! -f "$libgdk" ]; then
    libgdk="$(find "$builddir" -type f -name 'libgdk.a' ! -path '*.p/*' -print -quit)"
  fi
  if [ -z "$libgdk" ] || [ ! -f "$libgdk" ]; then
    echo "GDK build produced no libgdk.a under $builddir" >&2
    find "$builddir" -type f -name '*.a' >&2 || true
    return 1
  fi
  mkdir -p "$libdir/pkgconfig" "$destdir/include/gtk-4.0/gdk"
  copy_archive "$libgdk" "$libdir/libgdk.a"
  flags=" -lgdk"
  if listed="$(archive_members "$libgdk")"; then
    while IFS= read -r archive; do
      [ -n "$archive" ] || continue
      [ "$archive" = "$libgdk" ] && continue
      local members missing=0 member
      if ! members="$(archive_members "$archive")"; then
        missing=1
      else
        while IFS= read -r member; do
          [ -n "$member" ] || continue
          if ! grep -Fqx -- "$member" <<< "$listed"; then
            missing=1
            break
          fi
        done <<< "$members"
      fi
      if [ "$missing" -eq 1 ]; then
        base="$(basename "$archive")"
        copy_archive "$archive" "$libdir/$base"
        name="${base#lib}"
        name="${name%.a}"
        flags="$flags -l$name"
      fi
    done < <(find "$gdk_build" -type f -name 'lib*.a' ! -path '*.p/*' | LC_ALL=C sort)
  fi
  if [ -d "$gdk_build" ]; then
    while IFS= read -r header; do
      [ -n "$header" ] || continue
      rel="${header#"$gdk_build"/}"
      mkdir -p "$destdir/include/gtk-4.0/gdk/$(dirname "$rel")"
      cp -a "$header" "$destdir/include/gtk-4.0/gdk/$rel"
    done < <(find "$gdk_build" -type f -name '*.h' ! -path '*.p/*' | LC_ALL=C sort)
  fi
  cat > "$libdir/pkgconfig/pixiewood-gdk.pc" << EOF
prefix=/
libdir=\${prefix}/lib/${abi}
includedir=\${prefix}/include

Name: pixiewood-gdk
Description: GDK from the GTK build
Version: 4
Libs: -L\${libdir} -Wl,--whole-archive${flags} -Wl,--no-whole-archive -landroid -ljnigraphics -lnativewindow -llog
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
