#!/usr/bin/env bash
# Cross-compile Android GTK packages.
# GTK comes from the one line in packages/gtk/targets.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=gtk-target.sh
source "$ROOT/scripts/gtk-target.sh"
# shellcheck source=sysroot-common.sh
source "$ROOT/scripts/sysroot-common.sh"
# shellcheck source=packaged-deps.sh
source "$ROOT/scripts/packaged-deps.sh"

ARCH="${ARCH:-aarch64}"
JOBS="${JOBS:-$(nproc)}"
GTK_TARGET="${GTK_TARGET:-gnome}"
ONLY=""
DEPS_SYSROOT=""
RESOLVED=""
TARBALL_OUT=""
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ROOT/.cache/android-sdk}"

distro_get() {
  local key=$1
  sed -n "s/^${key}=//p" "$ROOT/android-distro.conf" | head -n1 | tr -d '[:space:]'
}

ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION:-$(distro_get ndk)}"

usage() {
  echo "Usage: $0 [--arch aarch64|x86_64] [--jobs N] [--gtk TARGET] [--only PACKAGE] [--deps-sysroot DIR] [--resolved REV] [--tarball PATH]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --gtk) GTK_TARGET="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --deps-sysroot) DEPS_SYSROOT="$2"; shift 2 ;;
    --resolved) RESOLVED="$2"; shift 2 ;;
    --tarball) TARBALL_OUT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

if ! ABI="$(sysroot_map "$ROOT/cross/abi" "$ARCH")"; then
  exit 2
fi

if ! target_line="$(gtk_target_read "$ROOT/packages/gtk/targets" "$GTK_TARGET")"; then
  exit 1
fi
read -r GTK_TARGET_URL GTK_TARGET_REV GTK_TARGET_PATCH <<< "$target_line"
if [ "$GTK_TARGET_PATCH" != "-" ] && [ ! -f "$ROOT/packages/gtk/$GTK_TARGET_PATCH" ]; then
  echo "GTK patch missing: packages/gtk/$GTK_TARGET_PATCH" >&2
  exit 1
fi
if [ -n "$ONLY" ] && [ ! -f "$ROOT/packages/$ONLY/$ONLY.wrap" ]; then
  echo "Unknown package: $ONLY" >&2
  exit 2
fi

# The full sysroot is assembled from pins, the package cache, then source.
if [ -z "$ONLY" ]; then
  exec "$ROOT/scripts/assemble-sysroot.sh" --arch "$ARCH" --gtk "$GTK_TARGET" --jobs "$JOBS"
fi

need_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

for tool in git meson ninja pkg-config patch curl cmake valac sassc nasm glslc gperf; do
  need_tool "$tool"
done

field() {
  local file="$1" key="$2"
  sed -n "s/^${key}[[:space:]]*=[[:space:]]*//p" "$file" | head -n1 | tr -d '[:space:]'
}

ensure_git_checkout() {
  "$ROOT/scripts/checkout-cache.sh" ensure "$1" "$2" "$3"
}

if [ ! -d "$ANDROID_SDK_ROOT/ndk/$ANDROID_NDK_VERSION" ]; then
  ANDROID_SDK_ROOT="$ANDROID_SDK_ROOT" ANDROID_NDK_VERSION="$ANDROID_NDK_VERSION" \
    "$ROOT/scripts/install-sdk.sh"
fi

NDK="$ANDROID_SDK_ROOT/ndk/$ANDROID_NDK_VERSION"
prebuilt="$(find "$NDK/toolchains/llvm/prebuilt" -mindepth 1 -maxdepth 1 -type d | head -n1)"
if [ -z "$prebuilt" ]; then
  echo "NDK LLVM prebuilt directory missing under $NDK" >&2
  exit 1
fi

WORK="${PIXIEWOOD_SYSROOT_WORK:-$ROOT/out/work-$GTK_TARGET-$ARCH${ONLY:+-$ONLY}}"
rm -rf "$WORK"
mkdir -p "$WORK/subprojects/packagefiles" "$WORK/sysroot"
cp "$ROOT/meson.build" "$WORK/"
cp "$ROOT/sysroot/probe.c" "$WORK/sysroot/"

shopt -s nullglob
if [ -n "$ONLY" ]; then
  package_dirs=("$ROOT/packages/$ONLY/")
else
  package_dirs=("$ROOT/packages"/*/)
fi
for dep_dir in "${package_dirs[@]}"; do
  dep="$(basename "$dep_dir")"
  if [ -f "$dep_dir/$dep.wrap" ]; then
    cp -a "$dep_dir/$dep.wrap" "$WORK/subprojects/"
  fi
  if [ -d "$dep_dir/packagefiles" ]; then
    cp -a "$dep_dir/packagefiles/." "$WORK/subprojects/packagefiles/"
  fi
done
shopt -u nullglob
rm -f "$WORK/subprojects/gdk.wrap"
# GDK is built from the GTK checkout. A one-package gdk build still needs gtk.wrap.
if [ "$ONLY" = gdk ]; then
  cp -a "$ROOT/packages/gtk/gtk.wrap" "$WORK/subprojects/gtk.wrap"
fi

build_gtk=0
if [ -z "$ONLY" ] || [ "$ONLY" = gtk ] || [ "$ONLY" = gdk ]; then
  build_gtk=1
fi

if [ "$build_gtk" -eq 1 ]; then
  gtk_rev="$GTK_TARGET_REV"
  if [ -n "$RESOLVED" ]; then
    gtk_rev="$RESOLVED"
  fi
  gtk_target_apply_wrap "$WORK/subprojects/gtk.wrap" "$GTK_TARGET_URL" "$gtk_rev"
  echo "GTK $GTK_TARGET_URL @ $gtk_rev"
  if [ "$GTK_TARGET_PATCH" != "-" ]; then
    mkdir -p "$WORK/subprojects/packagefiles/gtk"
    cp -a "$ROOT/packages/gtk/$GTK_TARGET_PATCH" "$WORK/subprojects/packagefiles/gtk/"
    if ! grep -q '^diff_files[[:space:]]*=' "$WORK/subprojects/gtk.wrap"; then
      awk -v patch="gtk/$GTK_TARGET_PATCH" '
        /^\[provide\]/ && !inserted {
          print "diff_files = " patch
          print ""
          inserted = 1
        }
        { print }
      ' "$WORK/subprojects/gtk.wrap" > "$WORK/subprojects/gtk.wrap.tmp"
      if ! grep -q '^diff_files[[:space:]]*=' "$WORK/subprojects/gtk.wrap.tmp"; then
        echo "gtk.wrap has no [provide] section" >&2
        exit 1
      fi
      mv "$WORK/subprojects/gtk.wrap.tmp" "$WORK/subprojects/gtk.wrap"
    fi
  fi
  gtk_url="$(field "$WORK/subprojects/gtk.wrap" url)"
  gtk_rev="$(field "$WORK/subprojects/gtk.wrap" revision)"
  ensure_git_checkout "$WORK/subprojects/gtk" "$gtk_url" "$gtk_rev"
  "$ROOT/scripts/gtk-part.sh" patch "$WORK/subprojects/gtk"
  if [ "$GTK_TARGET_PATCH" != "-" ]; then
    echo "Applying $GTK_TARGET_PATCH"
    set +e
    patch -p1 -d "$WORK/subprojects/gtk" --forward --batch < "$ROOT/packages/gtk/$GTK_TARGET_PATCH"
    patch_status=$?
    set -e
    if [ "$patch_status" -ne 0 ]; then
      echo "$GTK_TARGET_PATCH did not apply (patch exit $patch_status)." >&2
      exit 1
    fi
  fi
  for pin in "$ROOT/packages/gtk/"*.wrap.pin; do
    [ -f "$pin" ] || continue
    base="$(basename "$pin" .pin)"
    if [ -f "$WORK/subprojects/$base" ]; then
      continue
    fi
    mkdir -p "$WORK/subprojects/gtk/subprojects"
    cp -a "$pin" "$WORK/subprojects/gtk/subprojects/$base"
  done
fi

drop_satisfied_wraps "$WORK" "$DEPS_SYSROOT" "$ABI"

checkout_wrap() {
  local wrap="$1" dir url rev
  [ -f "$wrap" ] || return 0
  grep -q '^\[wrap-git\]' "$wrap" || return 0
  dir="$(field "$wrap" directory)"
  url="$(field "$wrap" url)"
  rev="$(field "$wrap" revision)"
  [ -n "$dir" ] || dir="$(basename "$wrap" .wrap)"
  [ -n "$url" ] && [ -n "$rev" ] || return 0
  if [ -n "$ONLY" ] && [ "$(basename "$wrap" .wrap)" = "$ONLY" ] && [ -n "$RESOLVED" ]; then
    rev="$RESOLVED"
  fi
  ensure_git_checkout "$WORK/subprojects/$dir" "$url" "$rev"
  # Meson applies diff_files only when it clones the wrap. This checkout
  # already exists, so the patches have to be applied here.
  apply_wrap_diff "$wrap" "$WORK/subprojects/$dir"
}

apply_wrap_diff() {
  local wrap=$1 dest=$2 files file patchfile
  files="$(field "$wrap" diff_files)"
  [ -n "$files" ] || return 0
  [ -d "$dest" ] || return 0
  IFS=',' read -ra parts <<< "$files"
  for file in "${parts[@]}"; do
    [ -n "$file" ] || continue
    patchfile="$WORK/subprojects/packagefiles/$file"
    if [ ! -f "$patchfile" ]; then
      echo "Wrap patch missing: $patchfile" >&2
      return 1
    fi
    echo "Applying $file"
    patch -p1 -d "$dest" --forward --batch < "$patchfile"
  done
}

for wrap in "$WORK/subprojects/"*.wrap; do
  checkout_wrap "$wrap"
done
if [ "$build_gtk" -eq 1 ]; then
  for pin in "$ROOT/packages/gtk/"*.wrap.pin; do
    [ -f "$pin" ] || continue
    base="$(basename "$pin" .pin)"
    if [ ! -f "$WORK/subprojects/gtk/subprojects/$base" ]; then
      continue
    fi
    dir="$(field "$pin" directory)"
    url="$(field "$pin" url)"
    rev="$(field "$pin" revision)"
    ensure_git_checkout "$WORK/subprojects/$dir" "$url" "$rev"
    nested="$WORK/subprojects/gtk/subprojects/$dir"
    if [ ! -e "$nested" ]; then
      ln -s "../../$dir" "$nested"
    fi
  done
fi

if [ ! -f "$WORK/subprojects/glib/gobject/glib-mkenums.in" ]; then
  grep -v 'glib-mkenums' "$ROOT/cross/extra.cross" > "$WORK/extra.cross"
else
  cp "$ROOT/cross/extra.cross" "$WORK/extra.cross"
fi

if [ "$ONLY" = gdk ]; then
  printf 'int main(void) { return 0; }\n' > "$WORK/probe.c"
  cat > "$WORK/meson.build" << EOF
project('pixiewood-pkg-gdk', 'c', meson_version: '>=1.3.0', default_options: ['c_std=gnu11'])
subproject('gtk')
executable('probe', 'probe.c', install: false)
EOF
elif [ -n "$ONLY" ]; then
  printf 'int main(void) { return 0; }\n' > "$WORK/probe.c"
  probe_line="$(awk -v name="$ONLY" '$1 !~ /^#/ && $1 == name { $1 = ""; sub(/^ /, ""); print; found = 1 } END { exit !found }' "$ROOT/packages/probes")" || {
    echo "No meson probe for $ONLY" >&2
    exit 1
  }
  subproject_line=""
  dep_args=()
  for word in $probe_line; do
    if [ "$word" = "+subproject" ]; then
      subproject_line="subproject('$ONLY')"
      continue
    fi
    dep_args+=("dependency('$word')")
  done
  joined="$(IFS=,; printf '%s' "${dep_args[*]}")"
  cat > "$WORK/meson.build" << EOF
project('pixiewood-pkg-${ONLY}', 'c', meson_version: '>=1.3.0', default_options: ['c_std=gnu11'])
$subproject_line
executable('probe', 'probe.c', dependencies: [$joined], install: false)
EOF
fi

cat > "$WORK/toolchain.cross" << EOF
[constants]
toolchain = '$prebuilt/'

[binaries]
cmake = 'cmake'
EOF

isolate="$WORK/pkgconfig-empty"
mkdir -p "$isolate"
cat > "$WORK/pkg-config-isolate" << EOF
#!/bin/sh
unset PKG_CONFIG_SYSROOT_DIR
export PKG_CONFIG_LIBDIR='$isolate'
export PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1
export PKG_CONFIG_ALLOW_SYSTEM_LIBS=1
exec pkg-config "\$@"
EOF
chmod +x "$WORK/pkg-config-isolate"
cat > "$WORK/isolate.cross" << EOF
[binaries]
pkg-config = ['$WORK/pkg-config-isolate']
EOF

echo "Downloading Meson subprojects"
(
  cd "$WORK"
  meson subprojects download
)
drop_satisfied_wraps "$WORK" "$DEPS_SYSROOT" "$ABI"

builddir="$WORK/build-$ARCH"
meson_args=(
  --cross-file "$WORK/toolchain.cross"
  --cross-file "$ROOT/cross/$ARCH.cross"
  --cross-file "$ROOT/cross/android.cross"
  --cross-file "$WORK/extra.cross"
)
if [ -n "$DEPS_SYSROOT" ]; then
  if [ ! -f "$DEPS_SYSROOT/share/pixiewood/pixie.cross" ]; then
    echo "Dependency sysroot is not activated: $DEPS_SYSROOT" >&2
    exit 1
  fi
  meson_args+=(--cross-file "$DEPS_SYSROOT/share/pixiewood/pixie.cross")
else
  meson_args+=(--cross-file "$WORK/isolate.cross")
fi
gdk_part=""
if [ "$ONLY" = gdk ]; then
  gdk_part=gdk
elif [ "$ONLY" = gtk ] && [ -n "$DEPS_SYSROOT" ] && [ -f "$DEPS_SYSROOT/lib/$ABI/pkgconfig/pixiewood-gdk.pc" ]; then
  gdk_part=gtk
fi
if [ -n "$gdk_part" ]; then
  cat > "$WORK/part.cross" << EOF
[gtk:project options]
pixiewood-part = '$gdk_part'
EOF
  meson_args+=(--cross-file "$WORK/part.cross")
  echo "GTK build part: $gdk_part"
fi

meson setup \
  "${meson_args[@]}" \
  --buildtype debug \
  "$builddir" \
  "$WORK"

ninja -C "$builddir" -j "$JOBS"

if [ -n "$ONLY" ]; then
  destdir="$ROOT/out/pkg-$ONLY-$GTK_TARGET-$ABI"
  rm -rf "$destdir"
  mkdir -p "$destdir"
  meson install -C "$builddir" --destdir "$destdir" --no-rebuild
  tarball="${TARBALL_OUT:-$ROOT/out/${ONLY}-${ABI}.tar.xz}"
  java_args=()
  if [ "$ONLY" = gdk ]; then
    "$ROOT/scripts/gtk-part.sh" pack "$builddir" "$destdir" "$ABI"
    java_args=(--java-glue "$WORK/subprojects/gtk/gdk/android/glue/java")
  elif [ "$ONLY" = gtk ] && [ "$gdk_part" != gtk ]; then
    java_args=(--java-glue "$WORK/subprojects/gtk/gdk/android/glue/java")
  fi
  "$ROOT/scripts/sysroot-tree.sh" pack-fragment \
    --destdir "$destdir" \
    --abi "$ABI" \
    --tarball "$tarball" \
    "${java_args[@]}"
  exit 0
fi

destdir="$ROOT/out/sysroot-$GTK_TARGET-$ABI"
rm -rf "$destdir"
mkdir -p "$destdir"
meson install -C "$builddir" --destdir "$destdir" --no-rebuild

"$ROOT/scripts/sysroot-tree.sh" finalize \
  --destdir "$destdir" \
  --version "$GTK_TARGET" \
  --abi "$ABI" \
  --arch "$ARCH" \
  --api "$(distro_get api)" \
  --ndk "$ANDROID_NDK_VERSION" \
  --pixiewood-revision "$(distro_get pixiewood)" \
  --gtk-target "$GTK_TARGET" \
  --gtk-url "$GTK_TARGET_URL" \
  --gtk-revision "$(git -C "$WORK/subprojects/gtk" rev-parse HEAD)" \
  --provided "$ROOT/build-order.txt" \
  --java-glue "$WORK/subprojects/gtk/gdk/android/glue/java"

"$ROOT/scripts/verify-sysroot.sh" "$destdir"

tarball="$ROOT/out/pixiewood-android-${GTK_TARGET}-${ABI}.tar.xz"
tar -C "$destdir" -cJf "$tarball" .
echo "Wrote $tarball"
