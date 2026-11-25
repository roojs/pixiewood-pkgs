#!/usr/bin/env bash
# Cross-compile FreeRDP with the NDK CMake toolchain.
# The staged tree is what the pixie package installs. Copies under link/ are
# the shared libraries the Meson probe links.
set -euo pipefail

src=$1
build=$2
stage=$3
link=$4
cc=$5
prefix=$6
libdir=$7
cairo=$8
stamp=$9

if [ ! -f "$cc" ]; then
  echo "Android compiler missing: $cc" >&2
  exit 1
fi

base=$(basename "$cc")
case "$base" in
  aarch64-linux-android*)
    abi=arm64-v8a
    api=${base#aarch64-linux-android}
    ;;
  x86_64-linux-android*)
    abi=x86_64
    api=${base#x86_64-linux-android}
    ;;
  i686-linux-android*)
    abi=x86
    api=${base#i686-linux-android}
    ;;
  armv7a-linux-androideabi*)
    abi=armeabi-v7a
    api=${base#armv7a-linux-androideabi}
    ;;
  *)
    echo "Compiler is not an NDK Android clang: $base" >&2
    exit 1
    ;;
esac
api=${api%%-*}
if ! [[ "$api" =~ ^[0-9]+$ ]]; then
  echo "Could not read the API level from $base" >&2
  exit 1
fi

ndk=""
dir=$(dirname "$cc")
while [ "$dir" != / ]; do
  if [ -f "$dir/build/cmake/android.toolchain.cmake" ]; then
    ndk=$dir
    break
  fi
  dir=$(dirname "$dir")
done
if [ -z "$ndk" ]; then
  echo "NDK toolchain not found from $cc" >&2
  exit 1
fi

ssl_lib="$libdir/libssl.so"
crypto_lib="$libdir/libcrypto.so"
if [ ! -e "$ssl_lib" ] || [ ! -e "$crypto_lib" ]; then
  echo "OpenSSL libraries missing under $libdir" >&2
  exit 1
fi

rm -rf "$build" "$stage" "$link"
mkdir -p "$build" "$stage" "$link"

# The dependency sysroot is the only place pkg-config may look.
# Host libraries must not satisfy a find_package during this cross build.
export PKG_CONFIG_LIBDIR="$libdir/pkgconfig"
export PKG_CONFIG_PATH=""
unset PKG_CONFIG_SYSROOT_DIR || true
export PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1
export PKG_CONFIG_ALLOW_SYSTEM_LIBS=1

# The NDK toolchain searches libraries only under its own sysroot, and its
# library architecture is aarch64-linux-android rather than arm64-v8a.
# FreeRDP's FindCairo therefore misses libcairo.so when pkg-config is not
# what answers. Point it at the pixie copies directly.
cmake_extra=()
pkg_config=$(command -v pkg-config || true)
if [ -n "$pkg_config" ]; then
  cmake_extra+=(-DPKG_CONFIG_EXECUTABLE="$pkg_config")
fi
if [ "$cairo" = ON ]; then
  cairo_lib="$libdir/libcairo.so"
  if [ -f "$prefix/include/cairo/cairo.h" ]; then
    cairo_inc="$prefix/include/cairo"
  elif [ -f "$prefix/include/cairo.h" ]; then
    cairo_inc="$prefix/include"
  else
    cairo_inc=""
  fi
  if [ ! -e "$cairo_lib" ] || [ -z "$cairo_inc" ]; then
    echo "Cairo was requested, but libcairo was not found under $prefix" >&2
    exit 1
  fi
  cmake_extra+=(
    -DCAIRO_LIBRARY="$cairo_lib"
    -DCAIRO_LIBRARIES="$cairo_lib"
    -DCAIRO_INCLUDE_DIR="$cairo_inc"
  )
fi

# A prefix of "/" makes GNUInstallDirs rewrite libdir to usr/lib, which
# is not the pixie layout. Install under a plain prefix, then hoist the
# tree to the stage root. pkg-config files stay relocatable.
install_prefix=/pixiewood

cmake -S "$src" -B "$build" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$abi" \
  -DANDROID_PLATFORM="android-$api" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DCMAKE_INSTALL_PREFIX="$install_prefix" \
  -DCMAKE_INSTALL_LIBDIR="lib/$abi" \
  -DCMAKE_INSTALL_INCLUDEDIR=include \
  -DCMAKE_INSTALL_BINDIR="bin/$abi" \
  -DCMAKE_SKIP_RPATH=ON \
  -DCMAKE_PREFIX_PATH="$prefix" \
  -DOPENSSL_ROOT_DIR="$prefix" \
  -DOPENSSL_INCLUDE_DIR="$prefix/include" \
  -DOPENSSL_SSL_LIBRARY="$ssl_lib" \
  -DOPENSSL_CRYPTO_LIBRARY="$crypto_lib" \
  -DOPENSSL_USE_STATIC_LIBS=OFF \
  -DWITH_MANPAGES=OFF \
  -DWITH_SAMPLE=OFF \
  -DWITH_CLIENT=OFF \
  -DWITH_CLIENT_COMMON=ON \
  -DWITH_CLIENT_SDL=OFF \
  -DWITH_SERVER=ON \
  -DWITH_SHADOW=OFF \
  -DWITH_PROXY=OFF \
  -DWITH_PLATFORM_SERVER=OFF \
  -DWITH_CHANNELS=ON \
  -DWITH_CLIENT_CHANNELS=ON \
  -DWITH_SERVER_CHANNELS=ON \
  -DBUILD_TESTING=OFF \
  -DWITH_CLANG_FORMAT=OFF \
  -DWITH_CCACHE=OFF \
  -DWITH_FFMPEG=OFF \
  -DWITH_SWSCALE=OFF \
  -DWITH_CAIRO="$cairo" \
  "${cmake_extra[@]}" \
  -DWITH_JPEG=OFF \
  -DWITH_OPENH264=OFF \
  -DWITH_GSM=OFF \
  -DWITH_LAME=OFF \
  -DWITH_FAAD2=OFF \
  -DWITH_FAAC=OFF \
  -DWITH_SOXR=OFF \
  -DWITH_OPENCL=OFF \
  -DWITH_MBEDTLS=OFF \
  -DWITH_LIBRESSL=OFF \
  -DWITH_PCSC=OFF \
  -DWITH_CUPS=OFF \
  -DWITH_FUSE=OFF \
  -DWITH_PULSE=OFF \
  -DWITH_ALSA=OFF \
  -DWITH_OSS=OFF \
  -DWITH_SNDIO=OFF \
  -DBUILD_FUZZERS=OFF \
  -DWITH_RDPECAM_MOVIE=OFF

cmake --build "$build" --parallel "$(nproc)"
DESTDIR="$stage" cmake --install "$build" --strip

# The NDK toolchain compiles with -g in every build type, and CMake does not
# strip static archives on install.
strip_tool="$(dirname "$cc")/llvm-strip"
if [ ! -x "$strip_tool" ]; then
  echo "NDK strip tool missing: $strip_tool" >&2
  exit 1
fi
while IFS= read -r -d '' file; do
  magic="$(head -c 7 "$file" | od -An -tx1 | tr -d ' \n')"
  case "$magic" in
    7f454c46*|213c617263683e)
      "$strip_tool" --strip-debug "$file"
      ;;
  esac
done < <(find "$stage" -type f -print0)

installed="$stage${install_prefix}"
if [ ! -d "$installed" ]; then
  echo "Install tree missing: $installed" >&2
  find "$stage" -maxdepth 4 -type d >&2 || true
  exit 1
fi
shopt -s dotglob
mv "$installed"/* "$stage"/
rmdir "$installed"

# Text files still name the temporary prefix. A quoted prefix becomes "."
# so it matches FreeRDP's Android relative paths. A prefix with a following
# path component is rooted at the package instead.
while IFS= read -r -d '' file; do
  if grep -q -I -F "$install_prefix" "$file"; then
    sed -i \
      -e "s|${install_prefix}/|/|g" \
      -e "s|${install_prefix}\"|.\"|g" \
      -e "s|${install_prefix}\$|/|" \
      "$file"
  fi
done < <(find "$stage" -type f -print0)

for name in libwinpr3.so libfreerdp3.so libfreerdp-client3.so libfreerdp-server3.so; do
  src_so="$stage/lib/$abi/$name"
  if [ ! -e "$src_so" ]; then
    echo "Installed library missing: $src_so" >&2
    find "$stage" -name 'lib*.so*' | head -50 >&2 || true
    exit 1
  fi
  cp -L "$src_so" "$link/$name"
done

for pc in freerdp3.pc freerdp-client3.pc freerdp-server3.pc winpr3.pc; do
  if [ ! -f "$stage/lib/$abi/pkgconfig/$pc" ]; then
    echo "Installed pkg-config file missing: $pc" >&2
    find "$stage" -name '*.pc' | head -40 >&2 || true
    exit 1
  fi
done

touch "$stamp"
