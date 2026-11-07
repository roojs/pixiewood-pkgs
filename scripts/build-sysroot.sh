#!/usr/bin/env bash
# Cross-compile the OLLMchat Android library stack and pack a sysroot tarball.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${PROFILE:-ollmchat}"
ARCH="${ARCH:-aarch64}"
JOBS="${JOBS:-$(nproc)}"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ROOT/.cache/android-sdk}"
ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION:-28.2.13676358}"

usage() {
  echo "Usage: $0 [--arch aarch64|x86_64] [--jobs N]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --arch)
      ARCH="$2"
      shift 2
      ;;
    --jobs)
      JOBS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
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

PROFILE_DIR="$ROOT/stack/$PROFILE"
if [ ! -f "$PROFILE_DIR/meson.build" ]; then
  echo "Unknown profile: $PROFILE" >&2
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
# Not used by these scripts. GLib's glib-mkenums and the OpenSSL wrap
# generator are Python programs shipped by those projects.
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

upstream_field() {
  local key="$1"
  sed -n "s/^${key}=//p" "$PROFILE_DIR/UPSTREAM" | head -n1 | tr -d '[:space:]'
}

ensure_git_checkout() {
  local dir="$1" url="$2" rev="$3" actual peeled
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

WORK="${PIXIEWOOD_SYSROOT_WORK:-$ROOT/out/work-$PROFILE-$ARCH}"
rm -rf "$WORK"
mkdir -p "$WORK/subprojects/packagefiles"
cp "$PROFILE_DIR/meson.build" "$PROFILE_DIR/probe.c" "$PROFILE_DIR/extra.cross" "$WORK/"

shopt -s nullglob
for dep_dir in "$PROFILE_DIR/wraps"/*/; do
  dep="$(basename "$dep_dir")"
  if [ -f "$dep_dir/$dep.wrap" ]; then
    cp -a "$dep_dir/$dep.wrap" "$WORK/subprojects/"
  fi
  if [ -d "$dep_dir/packagefiles" ]; then
    cp -a "$dep_dir/packagefiles/." "$WORK/subprojects/packagefiles/"
  fi
done
shopt -u nullglob

# Pixiewood applies <patch>android-bugs</patch> by diff_files. Do the same
# when Meson fetches GTK, and also patch the checkout we create first.
if [ -f "$PROFILE_DIR/wraps/gtk/android-bugs.patch" ]; then
  mkdir -p "$WORK/subprojects/packagefiles/gtk"
  cp -a "$PROFILE_DIR/wraps/gtk/android-bugs.patch" "$WORK/subprojects/packagefiles/gtk/"
  # diff_files belongs in the wrap-git section. Appending it after [provide]
  # is ignored by Meson.
  if ! grep -q '^diff_files[[:space:]]*=' "$WORK/subprojects/gtk.wrap"; then
    awk '
      /^\[provide\]/ && !inserted {
        print "diff_files = gtk/android-bugs.patch"
        print ""
        inserted = 1
      }
      { print }
    ' "$WORK/subprojects/gtk.wrap" > "$WORK/subprojects/gtk.wrap.tmp"
    if ! grep -q '^diff_files[[:space:]]*=' "$WORK/subprojects/gtk.wrap.tmp"; then
      echo "gtk.wrap has no [provide] section: $WORK/subprojects/gtk.wrap" >&2
      exit 1
    fi
    mv "$WORK/subprojects/gtk.wrap.tmp" "$WORK/subprojects/gtk.wrap"
  fi
fi

gtk_url="$(field "$WORK/subprojects/gtk.wrap" url)"
gtk_rev="$(field "$WORK/subprojects/gtk.wrap" revision)"
ensure_git_checkout "$WORK/subprojects/gtk" "$gtk_url" "$gtk_rev"
echo "Applying android-bugs.patch"
set +e
patch -p1 -d "$WORK/subprojects/gtk" --forward --batch < "$PROFILE_DIR/wraps/gtk/android-bugs.patch"
patch_status=$?
set -e
if ! grep -q 'ollmchat-android-bugs-v16' "$WORK/subprojects/gtk/gdk/android/gdkandroidollmchatpatch.c"; then
  echo "android-bugs.patch did not apply (patch exit $patch_status)." >&2
  exit 1
fi

for pin in "$PROFILE_DIR/wraps/gtk/"*.wrap.pin; do
  [ -f "$pin" ] || continue
  cp -a "$pin" "$WORK/subprojects/gtk/subprojects/$(basename "$pin" .pin)"
done

# Drop a top-level pango provider. GTK's nested wrap is the pin.
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
  case "$rev" in
    main|master|HEAD)
      echo "Leaving $dir for Meson (wrap tracks $rev). The tarball is the frozen build."
      return 0
      ;;
  esac
  ensure_git_checkout "$WORK/subprojects/$dir" "$url" "$rev"
}

checkout_wrap "$WORK/subprojects/glib.wrap"
checkout_wrap "$WORK/subprojects/libadwaita.wrap"
for pin in "$PROFILE_DIR/wraps/gtk/"*.wrap.pin; do
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

cat > "$WORK/toolchain.cross" << EOF
[constants]
toolchain = '$prebuilt/'

[binaries]
cmake = 'cmake'
EOF

echo "Downloading Meson subprojects"
(
  cd "$WORK"
  meson subprojects download
)

builddir="$WORK/build-$ARCH"
meson setup \
  --cross-file "$WORK/toolchain.cross" \
  --cross-file "$ROOT/stack/cross/$ARCH.cross" \
  --cross-file "$ROOT/stack/cross/android.cross" \
  --cross-file "$WORK/extra.cross" \
  --buildtype debug \
  "$builddir" \
  "$WORK"

ninja -C "$builddir" -j "$JOBS"

version="$(tr -d '[:space:]' < "$PROFILE_DIR/VERSION")"
destdir="$ROOT/out/sysroot-$PROFILE-$ABI"
rm -rf "$destdir"
mkdir -p "$destdir"
meson install -C "$builddir" --destdir "$destdir" --no-rebuild

"$ROOT/scripts/sysroot-tree.sh" finalize \
  --destdir "$destdir" \
  --profile "$PROFILE" \
  --version "$version" \
  --abi "$ABI" \
  --arch "$ARCH" \
  --api "$(upstream_field api)" \
  --ndk "$ANDROID_NDK_VERSION" \
  --pixiewood-revision "$(upstream_field pixiewood)" \
  --ollmchat-wraps-revision "$(upstream_field ollmchat_wraps)" \
  --provided "$PROFILE_DIR/provided-dependencies.txt" \
  --java-glue "$WORK/subprojects/gtk/gdk/android/glue/java"

"$ROOT/scripts/verify-sysroot.sh" "$destdir"

tarball="$ROOT/out/pixiewood-android-sysroot-${version}-${ABI}.tar.xz"
tar -C "$destdir" -cJf "$tarball" .
echo "Wrote $tarball"
