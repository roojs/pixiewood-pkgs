#!/usr/bin/env bash
# Published Android FreeRDP/WinPR libraries must be optimized, built with
# NDEBUG, and stripped. android-cmake.sh is what the freerdp Meson package
# runs; install-tree.sh and pixie-tree.sh pack that tree into the .pixie file.
# This test fails while that build is CMake Debug and the .so files are copied
# with their debug sections intact.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$ROOT/packages/freerdp/packagefiles/freerdp/android-cmake.sh"
install_tree="$ROOT/packages/freerdp/packagefiles/freerdp/install-tree.sh"
pixie_tree="$ROOT/scripts/pixie-tree.sh"

libs=(libwinpr3.so libfreerdp3.so libfreerdp-client3.so libfreerdp-server3.so)

fail() {
  echo "freerdp android release: $*" >&2
  exit 1
}

distro_get() {
  sed -n "s/^${1}=//p" "$ROOT/android-distro.conf" | head -n1 | tr -d '[:space:]'
}

ensure_ndk() {
  local version sdk ndk
  version="$(distro_get ndk)"
  [ -n "$version" ] || fail "android-distro.conf has no ndk version"
  sdk="${ANDROID_SDK_ROOT:-$ROOT/.cache/android-sdk}"
  ndk="$sdk/ndk/$version"
  if [ -f "$ndk/build/cmake/android.toolchain.cmake" ]; then
    printf '%s\n' "$ndk"
    return
  fi
  if [ "$version" != 28.2.13676358 ]; then
    fail "NDK $version is not installed and this test only knows how to fetch r28c"
  fi
  mkdir -p "$sdk/ndk"
  local tmp zip
  tmp="$(mktemp -d)"
  zip="$tmp/android-ndk-r28c-linux.zip"
  curl -fL --retry 3 -o "$zip" \
    "https://dl.google.com/android/repository/android-ndk-r28c-linux.zip"
  echo "a7b54a5de87fecd125a17d54f73c446199e72a64  $zip" | sha1sum -c -
  unzip -q "$zip" -d "$tmp"
  rm -rf "$ndk"
  mv "$tmp/android-ndk-r28c" "$ndk"
  rm -rf "$tmp"
  printf '%s\n' "$ndk"
}

write_probe() {
  local src=$1
  mkdir -p "$src"
  cat > "$src/CMakeLists.txt" << 'EOF'
cmake_minimum_required(VERSION 3.16)
project(freerdp_stage_probe C)
add_library(probe_obj OBJECT probe.c)
set_target_properties(probe_obj PROPERTIES POSITION_INDEPENDENT_CODE ON)
foreach(name winpr3 freerdp3 freerdp-client3 freerdp-server3)
  add_library(${name} SHARED $<TARGET_OBJECTS:probe_obj>)
  set_target_properties(${name} PROPERTIES OUTPUT_NAME "${name}" PREFIX "lib" SUFFIX ".so")
  install(TARGETS ${name} LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}")
  file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/${name}.pc" "Name: ${name}\nVersion: 3\n")
  install(FILES "${CMAKE_CURRENT_BINARY_DIR}/${name}.pc"
    DESTINATION "${CMAKE_INSTALL_LIBDIR}/pkgconfig")
endforeach()
EOF
  cat > "$src/probe.c" << 'EOF'
#include <assert.h>

int fold_session_cost(int n) {
  int sum = 0;
  for (int i = 1; i <= 8; i++)
    sum += i * n;
  return sum;
}

int check_session(int n) {
  assert(n > 0 && "rdp-session-assert-marker");
  return fold_session_cost(n);
}
EOF
}

compile_flags() {
  local build=$1
  awk '
    $0 ~ /probe\.c\.o: C_COMPILER__/ { show = 1; next }
    show && $0 ~ /^  FLAGS = / { sub(/^  FLAGS = /, ""); print; exit }
  ' "$build/build.ninja"
}

link_flags() {
  local build=$1
  awk '
    $0 ~ /libfreerdp3\.so: C_SHARED_LIBRARY_LINKER__/ { show = 1; next }
    show && $0 ~ /^  LINK_FLAGS = / { sub(/^  LINK_FLAGS = /, ""); print; exit }
  ' "$build/build.ninja"
}

require_release_flags() {
  local flags=$1 link=$2
  case " $flags " in
    *" -O0 "*|*" -O0") fail "compile flags are unoptimized: $flags" ;;
  esac
  case " $flags " in
    *" -O2 "*|*" -O3 "*|*" -Os "*|*" -Oz "*) ;;
    *) fail "compile flags have no optimization: $flags" ;;
  esac
  case " $flags " in
    *" -DNDEBUG "*|*" -DNDEBUG") ;;
    *) fail "compile flags do not define NDEBUG: $flags" ;;
  esac
  case " $flags " in
    *" -fno-limit-debug-info "*) fail "compile flags keep full debug info: $flags" ;;
  esac
  case " $link " in
    *"--gc-sections"*) ;;
    *) fail "link flags keep every section, which is the Debug linker setup: $link" ;;
  esac
}

require_release_library() {
  local so=$1 readelf=$2 objdump=$3 where=$4
  [ -f "$so" ] || fail "missing $where"
  if "$readelf" -S "$so" | awk '$2 == ".debug_info" || $2 == ".symtab" { found = 1 } END { exit !found }'; then
    fail "$where still has debug info or a static symbol table"
  fi
  if strings "$so" | grep -F -q 'rdp-session-assert-marker'; then
    fail "$where still contains the assertion text"
  fi
  local dis
  dis="$("$objdump" -d --disassemble-symbols=fold_session_cost "$so")"
  if printf '%s\n' "$dis" | grep -q '[[:space:]]subs[[:space:]]'; then
    fail "$where still has the unoptimized session-cost loop"
  fi
  if ! printf '%s\n' "$dis" | grep -q '[[:space:]]lsl[[:space:]]'; then
    fail "$where did not fold the session-cost loop"
  fi
}

main() {
  local ndk api prebuilt cc work prefix src build stage link destdir tarball pixie
  local flags link_flags name so readelf objdump
  ndk="$(ensure_ndk)"
  api="$(distro_get api)"
  [ "$api" = 31 ] || fail "this test follows the distro API, expected 31, got ${api:-empty}"
  prebuilt="$(find "$ndk/toolchains/llvm/prebuilt" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [ -n "$prebuilt" ] || fail "NDK LLVM prebuilt directory missing under $ndk"
  cc="$prebuilt/bin/aarch64-linux-android${api}-clang"
  [ -x "$cc" ] || fail "NDK compiler missing: $cc"
  readelf="$prebuilt/bin/llvm-readelf"
  objdump="$prebuilt/bin/llvm-objdump"

  work="$(mktemp -d)"
  # The trap outlives main, so the path cannot be a function-local variable.
  WORK_DIR="$work"
  trap 'rm -rf "$WORK_DIR"' EXIT
  prefix="$work/prefix"
  src="$work/src"
  build="$work/cmake"
  stage="$work/stage"
  link="$work/link"
  destdir="$work/destdir"
  mkdir -p "$prefix/lib/pkgconfig" "$prefix/include/cairo" "$destdir"
  # The script refuses to configure unless these dependency files exist.
  # Their contents are not read; FreeRDP's own CMake would link them.
  : > "$prefix/lib/libssl.so"
  : > "$prefix/lib/libcrypto.so"
  : > "$prefix/lib/libcairo.so"
  printf '%s\n' '/* cairo */' > "$prefix/include/cairo/cairo.h"
  write_probe "$src"

  # Same argument order as packages/freerdp/packagefiles/freerdp/meson.build.
  # Cairo is ON because a published build has already built cairo. No
  # CMAKE_BUILD_TYPE is supplied by the caller; the publish script does not
  # set one either.
  unset CMAKE_BUILD_TYPE || true
  bash "$script" \
    "$src" \
    "$build" \
    "$stage" \
    "$link" \
    "$cc" \
    "$prefix" \
    "$prefix/lib" \
    ON \
    "$work/stamp"

  flags="$(compile_flags "$build")"
  link_flags="$(link_flags "$build")"
  [ -n "$flags" ] || fail "could not read the probe compile command"
  [ -n "$link_flags" ] || fail "could not read the freerdp link command"
  require_release_flags "$flags" "$link_flags"

  for name in "${libs[@]}"; do
    require_release_library "$link/$name" "$readelf" "$objdump" "link/$name"
    require_release_library "$stage/lib/arm64-v8a/$name" "$readelf" "$objdump" "stage/$name"
  done

  # Meson 1.12 sets MESON_INSTALL_DESTDIR_PREFIX to the destdir when prefix is /.
  MESON_INSTALL_DESTDIR_PREFIX="$destdir" "$install_tree" "$stage"
  tarball="$work/freerdp-arm64-v8a.tar.xz"
  "$pixie_tree" pack-fragment --destdir "$destdir" --abi arm64-v8a --tarball "$tarball"
  # publish-package.sh publishes that tarball by copying it to the .pixie name.
  pixie="$work/freerdp-arm64-v8a-v31-probe.pixie"
  cp -a "$tarball" "$pixie"
  mkdir -p "$work/pixie-unpack"
  tar -xJf "$pixie" -C "$work/pixie-unpack"
  for name in "${libs[@]}"; do
    so="$work/pixie-unpack/lib/arm64-v8a/$name"
    require_release_library "$so" "$readelf" "$objdump" "pixie/$name"
    cmp -s "$destdir/lib/arm64-v8a/$name" "$so" || fail "pixie $name differs from the install tree"
  done

  echo "freerdp android release: ok"
}

main "$@"
