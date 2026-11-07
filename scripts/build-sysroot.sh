#!/usr/bin/env bash
# Cross-compile Android GTK packages.
# Default GTK is native upstream GNOME, with no Android patch.
# --gtk Knowles.android-ime builds that owner.branch, which has those fixes.
# Branch targets are named <repo-owner>.<branch> in packages/gtk/targets.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=gtk-target.sh
source "$ROOT/scripts/gtk-target.sh"

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
  sed -n "s/^${key}=//p" "$ROOT/distro.conf" | head -n1 | tr -d '[:space:]'
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

case "$ARCH" in
  aarch64) ABI="arm64-v8a" ;;
  x86_64) ABI="x86_64" ;;
  *)
    echo "Unsupported arch: $ARCH" >&2
    exit 2
    ;;
esac

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

need_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

for tool in git meson ninja pkg-config patch curl cmake valac sassc nasm glslc gperf; do
  need_tool "$tool"
done
need_tool python3
if ! perl -MText::Template -e 1 >/dev/null 2>&1; then
  echo "Missing Perl module Text::Template (package libtext-template-perl)." >&2
  echo "The OpenSSL wrap runs generator.sh on the host during configure." >&2
  exit 1
fi

field() {
  local file="$1" key="$2"
  sed -n "s/^${key}[[:space:]]*=[[:space:]]*//p" "$file" | head -n1 | tr -d '[:space:]'
}

ensure_git_checkout() {
  local dir=$1 url=$2 rev=$3 actual peeled
  if [ -d "$dir/.git" ]; then
    actual="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
    if [ "$actual" = "$rev" ]; then
      return 0
    fi
    peeled="$(git -C "$dir" rev-parse --verify -q "${rev}^{commit}" 2>/dev/null || true)"
    if [ -n "$peeled" ] && [ "$actual" = "$peeled" ]; then
      return 0
    fi
  fi
  echo "Checking out $(basename "$dir") at $rev"
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$url"
  git -C "$dir" fetch --depth 1 origin "$rev"
  git -C "$dir" checkout --detach FETCH_HEAD
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
mkdir -p "$WORK/subprojects/packagefiles"
cp "$ROOT/meson.build" "$ROOT/probe.c" "$WORK/"

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

build_gtk=0
if [ -z "$ONLY" ] || [ "$ONLY" = gtk ]; then
  build_gtk=1
fi

if [ "$build_gtk" -eq 1 ]; then
  gtk_rev="$GTK_TARGET_REV"
  if [ -n "$RESOLVED" ]; then
    gtk_rev="$RESOLVED"
  fi
  gtk_target_apply_wrap "$WORK/subprojects/gtk.wrap" "$GTK_TARGET_URL" "$gtk_rev"
  echo "GTK target $GTK_TARGET ($GTK_TARGET_URL @ $gtk_rev)"
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
    mkdir -p "$WORK/subprojects/gtk/subprojects"
    cp -a "$pin" "$WORK/subprojects/gtk/subprojects/$(basename "$pin" .pin)"
  done
fi

for wrap in "$WORK/subprojects/"*.wrap; do
  [ -f "$wrap" ] || continue
  if grep -qE '^pango[[:space:]]*=' "$wrap"; then
    echo "Removing extra top-level pango wrap: $wrap"
    rm -f "$wrap"
  fi
done

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
  case "$rev" in
    main|master|HEAD)
      echo "Leaving $dir for Meson (wrap tracks $rev)."
      return 0
      ;;
  esac
  ensure_git_checkout "$WORK/subprojects/$dir" "$url" "$rev"
}

checkout_wrap "$WORK/subprojects/glib.wrap"
checkout_wrap "$WORK/subprojects/libadwaita.wrap"
if [ "$build_gtk" -eq 1 ]; then
  for pin in "$ROOT/packages/gtk/"*.wrap.pin; do
    [ -f "$pin" ] || continue
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

if [ -n "$ONLY" ]; then
  printf 'int main(void) { return 0; }\n' > "$WORK/probe.c"
  case "$ONLY" in
    openssl)
      cat > "$WORK/meson.build" << EOF
project('pixiewood-pkg-openssl', 'c', meson_version: '>=1.3.0', default_options: ['c_std=gnu11'])
executable('probe', 'probe.c', dependencies: [dependency('libssl'), dependency('libcrypto')], install: false)
EOF
      ;;
    glib-networking)
      cat > "$WORK/meson.build" << EOF
project('pixiewood-pkg-glib-networking', 'c', meson_version: '>=1.3.0', default_options: ['c_std=gnu11'])
subproject('glib-networking')
executable('probe', 'probe.c', dependencies: dependency('gioopenssl'), install: false)
EOF
      ;;
    *)
      dep=""
      case "$ONLY" in
        glib) dep="dependency('glib-2.0')" ;;
        fontconfig) dep="dependency('fontconfig')" ;;
        gtk) dep="dependency('gtk4')" ;;
        libadwaita) dep="dependency('libadwaita-1')" ;;
        gtksourceview) dep="dependency('gtksourceview-5')" ;;
        gee) dep="dependency('gee-0.8')" ;;
        json-glib) dep="dependency('json-glib-1.0')" ;;
        libxml2) dep="dependency('libxml-2.0')" ;;
        sqlite3) dep="dependency('sqlite3')" ;;
        nghttp2) dep="dependency('libnghttp2')" ;;
        libpsl) dep="dependency('libpsl')" ;;
        libsoup) dep="dependency('libsoup-3.0')" ;;
        webkitgtk-android) dep="dependency('webkitgtk-android-1')" ;;
        *)
          echo "No meson probe for $ONLY" >&2
          exit 1
          ;;
      esac
      cat > "$WORK/meson.build" << EOF
project('pixiewood-pkg-${ONLY}', 'c', meson_version: '>=1.3.0', default_options: ['c_std=gnu11'])
executable('probe', 'probe.c', dependencies: ${dep}, install: false)
EOF
      ;;
  esac
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

builddir="$WORK/build-$ARCH"
meson_args=(
  --cross-file "$WORK/toolchain.cross"
  --cross-file "$ROOT/cross/$ARCH.cross"
  --cross-file "$ROOT/cross/android.cross"
  --cross-file "$WORK/extra.cross"
)
if [ -n "$DEPS_SYSROOT" ]; then
  if [ ! -f "$DEPS_SYSROOT/share/pixiewood/sysroot.cross" ]; then
    echo "Dependency sysroot is not activated: $DEPS_SYSROOT" >&2
    exit 1
  fi
  meson_args+=(--cross-file "$DEPS_SYSROOT/share/pixiewood/sysroot.cross")
else
  meson_args+=(--cross-file "$WORK/isolate.cross")
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
  if [ "$ONLY" = gtk ]; then
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
