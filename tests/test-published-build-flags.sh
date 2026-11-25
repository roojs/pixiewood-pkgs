#!/usr/bin/env bash
# Shipped pixie libraries must be optimized and must not contain DWARF debug info.
#
# scripts/build-pixie.sh configures every Meson package, then
# scripts/pixie-tree.sh pack-fragment archives the install tree.
# packages/freerdp/packagefiles/freerdp/android-cmake.sh configures FreeRDP,
# and install-tree.sh copies that tree into the same pack step.
#
# The planted sources stand in for the upstream trees those scripts compile.
# They do not set per-target optimization, debug, b_ndebug, or strip, which is
# the same shape as packages/openssl/packagefiles/openssl/meson.build
# library() calls. The gtksourceview run also sets project() default_options
# buildtype=debugoptimized, matching
# packages/gtksourceview/packagefiles/gtksourceview/meson.build.
# Compiler flags still come from the real scripts.
#
# glib-networking is not built here. cross/extra.cross forces it to a static
# library, and Meson does not strip static archives on install.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for tool in clang llvm-ar llvm-ranlib llvm-strip llvm-as llvm-objdump python3 meson ninja cmake readelf pkg-config; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
done

# Clang with no optimization flag matches an explicit -O0 for this function.
# Meson and CMake both leave that as the unoptimized path.
cat > "$tmp/fold-probe.c" << 'EOF'
int published_fold(int n) {
  int s = 0;
  int i;
  for (i = 0; i < 4; i++)
    s += i;
  return s + n;
}
EOF
clang -c "$tmp/fold-probe.c" -o "$tmp/fold-default.o"
clang -O0 -c "$tmp/fold-probe.c" -o "$tmp/fold-o0.o"
if ! diff -q <(llvm-objdump -d "$tmp/fold-default.o" | sed '1,3d') \
             <(llvm-objdump -d "$tmp/fold-o0.o" | sed '1,3d') >/dev/null; then
  echo "clang with no -O flag did not match clang -O0" >&2
  exit 1
fi

failures=0
fail() {
  echo "$1" >&2
  failures=1
}

effective_opt() {
  python3 - "$1" << 'PY'
import re
import sys
text = sys.argv[1]
level = None
for token in text.replace("'", " ").replace('"', " ").split():
    if re.fullmatch(r"-O(?:0|1|2|3|s|z|g)", token):
        level = token
print(level or "")
PY
}

require_optimized() {
  local label=$1 command_text=$2
  local level
  level="$(effective_opt "$command_text")"
  case "$level" in
    -O2|-O3) ;;
    *)
      echo "$label compile command is not -O2 or -O3 (effective ${level:-none})" >&2
      echo "$command_text" >&2
      failures=1
      ;;
  esac
}

require_packed_library() {
  local tarball=$1 symbol=$2 libname=$3
  local extract so dis
  extract="$(mktemp -d "$tmp/extract.XXXXXX")"
  tar -xJf "$tarball" -C "$extract"
  so="$(find "$extract" -name "$libname" ! -type l | head -n1 || true)"
  if [ -z "$so" ]; then
    fail "$tarball contains no shared library"
    return
  fi
  if readelf -S "$so" | grep -q ' \.debug_info'; then
    echo "shipped $(basename "$so") from $tarball still has a .debug_info section" >&2
    failures=1
  fi
  # llvm-objdump still finds exported symbols after the dynamic symbol table is all
  # that remains. GNU objdump's --disassemble=name does not, once .symtab is gone.
  if ! dis="$(llvm-objdump -d --disassemble-symbols="$symbol" "$so" 2>/dev/null)"; then
    fail "shipped library is missing $symbol"
    return
  fi
  if ! printf '%s\n' "$dis" | grep -q "<$symbol>:"; then
    fail "shipped library is missing $symbol"
    return
  fi
  if printf '%s\n' "$dis" | grep -Eq '[[:space:]]jmp[[:space:]]'; then
    echo "shipped $symbol still contains the unoptimized loop" >&2
    failures=1
  fi
}

compile_command_for() {
  local builddir=$1 source_name=$2
  python3 - "$builddir/compile_commands.json" "$source_name" << 'PY'
import json
import sys
path, name = sys.argv[1], sys.argv[2]
rows = json.load(open(path))
for row in rows:
    if row.get("file", "").endswith("/" + name) or row.get("file", "").endswith(name):
        command = row.get("command")
        if command is None:
            command = " ".join(row.get("arguments", []))
        if " -c " in " " + command + " " or command.rstrip().endswith(" -c"):
            print(command)
            raise SystemExit(0)
raise SystemExit(1)
PY
}

write_fold() {
  cat > "$1" << 'EOF'
int published_fold(int n) {
  int s = 0;
  int i;
  for (i = 0; i < 4; i++)
    s += i;
  return s + n;
}
EOF
}

prepare_host_tools() {
  local bindir=$1
  mkdir -p "$bindir"
  local tool
  for tool in valac nasm glslc gperf; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      cat > "$bindir/$tool" << EOF
#!/bin/sh
echo "stub $tool was invoked" >&2
exit 1
EOF
      chmod +x "$bindir/$tool"
    fi
  done
}

prepare_meson_ndk() {
  local sdk=$1
  local ndk="$sdk/ndk/28.2.13676358"
  local prebuilt="$ndk/toolchains/llvm/prebuilt/linux-x86_64"
  local bin="$prebuilt/bin"
  mkdir -p "$bin" "$prebuilt/sysroot"
  cat > "$bin/aarch64-linux-android31-clang" << 'EOF'
#!/bin/bash
# The NDK sysroot is not installed in this test. Drop only --sysroot so the
# host compiler can link. Every other flag, including -O and -g, is kept.
log=${PIXIE_CLANG_LOG:?}
printf '%s\n' "$*" >> "$log"
args=()
skip=0
for arg in "$@"; do
  if [ "$skip" -eq 1 ]; then
    skip=0
    continue
  fi
  case "$arg" in
    --sysroot|-isysroot)
      skip=1
      ;;
    --sysroot=*|-isysroot=*)
      ;;
    *)
      args+=("$arg")
      ;;
  esac
done
exec /usr/bin/clang "${args[@]}"
EOF
  chmod +x "$bin/aarch64-linux-android31-clang"
  ln -sfn /usr/bin/llvm-ar "$bin/llvm-ar"
  ln -sfn /usr/bin/llvm-as "$bin/llvm-as"
  ln -sfn /usr/bin/llvm-ranlib "$bin/llvm-ranlib"
  ln -sfn /usr/bin/llvm-strip "$bin/llvm-strip"
  ln -sfn /usr/bin/ld "$bin/ld"
}

prepare_cmake_ndk() {
  local ndk=$1
  local prebuilt="$ndk/toolchains/llvm/prebuilt/linux-x86_64"
  local bin="$prebuilt/bin"
  mkdir -p "$bin" "$ndk/build/cmake" "$prebuilt/sysroot"
  cp -a "$ROOT/tests/fixtures/ndk-r28c/." "$ndk/build/cmake/"
  printf '%s\n' 'Pkg.Desc = Android NDK' 'Pkg.Revision = 28.2.13676358' > "$ndk/source.properties"
  cat > "$bin/clang" << 'EOF'
#!/bin/bash
# Host clang cannot link an Android target. Drop --target and --sysroot.
# Keep -O, -g, and -D flags from android-cmake.sh and the NDK toolchain.
log=${PIXIE_CLANG_LOG:?}
printf '%s\n' "$*" >> "$log"
args=()
skip=0
for arg in "$@"; do
  if [ "$skip" -eq 1 ]; then
    skip=0
    continue
  fi
  case "$arg" in
    --target|--sysroot|-isysroot|-target)
      skip=1
      ;;
    --target=*|--sysroot=*|-isysroot=*|-target=*)
      ;;
    *)
      args+=("$arg")
      ;;
  esac
done
exec /usr/bin/clang "${args[@]}"
EOF
  chmod +x "$bin/clang"
  ln -sfn clang "$bin/clang++"
  ln -sfn clang "$bin/aarch64-linux-android31-clang"
  ln -sfn /usr/bin/llvm-ar "$bin/llvm-ar"
  ln -sfn /usr/bin/llvm-ranlib "$bin/llvm-ranlib"
  ln -sfn /usr/bin/llvm-strip "$bin/llvm-strip"
  ln -sfn /usr/bin/ld "$bin/ld"
}

write_meson_wrapper() {
  local path=$1
  cat > "$path" << 'WRAPPER'
#!/bin/bash
if [ "${1:-}" = subprojects ] && [ "${2:-}" = download ]; then
  set -eu
  wrap=$(echo subprojects/*.wrap)
  dir=$(sed -n 's/^directory[[:space:]]*=[[:space:]]*//p' "$wrap" | head -n1 | tr -d '[:space:]')
  [ -n "$dir" ]
  dest="subprojects/$dir"
  mkdir -p "$dest"
  cat > "$dest/fold.c" << 'C'
int published_fold(int n) {
  int s = 0;
  int i;
  for (i = 0; i < 4; i++)
    s += i;
  return s + n;
}
C
  defaults="'warning_level=1'"
  if [ -n "${PIXIE_PLANT_BUILDTYPE:-}" ]; then
    defaults="$defaults, 'buildtype=${PIXIE_PLANT_BUILDTYPE}'"
  fi
  if [ "${PIXIE_PLANT_KIND:-}" = override ]; then
    cat > "$dest/meson.options" << 'OPTS'
option('introspection', type: 'feature', value: 'auto')
option('vapi', type: 'boolean', value: true)
option('documentation', type: 'boolean', value: true)
option('build-testsuite', type: 'boolean', value: true)
option('install-tests', type: 'boolean', value: true)
OPTS
    cat > "$dest/meson.build" << EOF
project('planted', 'c', version: '0', default_options: [$defaults])
lib = library('planted', 'fold.c', install: true)
dep = declare_dependency(link_with: lib)
meson.override_dependency('${PIXIE_PLANT_DEP}', dep)
EOF
  else
    cat > "$dest/meson.build" << EOF
project('planted', 'c', version: '0', default_options: [$defaults])
src = files('fold.c')
libcrypto_lib = library('crypto', src, install: true)
libcrypto_dep = declare_dependency(link_with: libcrypto_lib)
libssl_lib = library('ssl', src, install: true)
libssl_dep = declare_dependency(link_with: libssl_lib)
openssl_dep = declare_dependency(dependencies: [libcrypto_dep, libssl_dep])
EOF
  fi
  exit 0
fi
exec /usr/bin/meson "$@"
WRAPPER
  chmod +x "$path"
}

run_meson_package() {
  local name=$1 kind=$2 buildtype=$3 dep=$4
  local sdk="$tmp/sdk-$name"
  local work="$tmp/work-$name"
  local tarball="$tmp/$name.tar.xz"
  local bindir="$tmp/bin-$name"
  local log="$tmp/clang-$name.log"
  prepare_host_tools "$bindir"
  prepare_meson_ndk "$sdk"
  write_meson_wrapper "$bindir/meson"
  : > "$log"
  ANDROID_SDK_ROOT="$sdk" \
    PIXIEWOOD_SYSROOT_WORK="$work" \
    PIXIE_PLANT_KIND="$kind" \
    PIXIE_PLANT_BUILDTYPE="$buildtype" \
    PIXIE_PLANT_DEP="$dep" \
    PIXIE_CLANG_LOG="$log" \
    PATH="$bindir:$PATH" \
    "$ROOT/scripts/build-pixie.sh" \
      --only "$name" \
      --arch aarch64 \
      --gtk gnome \
      --tarball "$tarball" \
    > "$tmp/$name.build.log" 2>&1 || {
      echo "build-pixie.sh --only $name failed" >&2
      cat "$tmp/$name.build.log" >&2
      failures=1
      return
    }
  local builddir="$work/build-aarch64"
  local command_text
  if ! command_text="$(compile_command_for "$builddir" fold.c)"; then
    echo "no compile command for fold.c in $builddir" >&2
    exit 1
  fi
  require_optimized "$name" "$command_text"
  local libname=libcrypto.so
  if [ "$kind" = override ]; then
    libname=libplanted.so
  fi
  require_packed_library "$tarball" published_fold "$libname"
}

echo "meson package with no buildtype default (openssl shape)"
run_meson_package openssl variables "" ""
openssl_tar="$tmp/openssl.tar.xz"
before="$(sha256sum "$openssl_tar" | awk '{print $1}')"
"$ROOT/scripts/publish-package.sh" \
  --no-upload \
  --name openssl \
  --tarball "$openssl_tar" \
  --arch aarch64 \
  --gtk gnome \
  --track v0 \
  --resolved abc \
  --inputs dead \
  --created 2026-01-01T00:00:00Z \
  --file "$tmp/pins.json" >/dev/null
after="$(sha256sum "$openssl_tar" | awk '{print $1}')"
if [ "$before" != "$after" ]; then
  fail "publish-package.sh changed the tarball it publishes"
fi

echo "meson package whose project default is debugoptimized (gtksourceview shape)"
run_meson_package gtksourceview override debugoptimized gtksourceview-5

echo "freerdp cmake package"
ndk="$tmp/ndk-freerdp"
prepare_cmake_ndk "$ndk"
src="$tmp/freerdp-src"
mkdir -p "$src"
cat > "$src/winpr.c" << 'EOF'
int published_fold(int n) {
  int s = 0;
  int i;
  for (i = 0; i < 4; i++)
    s += i;
  return s + n;
}
EOF
for pair in freerdp3:freerdp freerdp-client3:client freerdp-server3:server; do
  file="${pair%%:*}"
  sym="${pair##*:}"
  printf 'int %s_anchor(void) { return 0; }\n' "$sym" > "$src/$file.c"
  printf 'Name: %s\nDescription: fixture\nVersion: 3\nLibs: -l%s\n' "$file" "$file" > "$src/$file.pc"
done
printf 'Name: winpr3\nDescription: fixture\nVersion: 3\nLibs: -lwinpr3\n' > "$src/winpr3.pc"
cat > "$src/CMakeLists.txt" << 'EOF'
cmake_minimum_required(VERSION 3.16)
project(freerdp_fixture C)
add_library(winpr3 SHARED winpr.c)
add_library(freerdp3 SHARED freerdp3.c)
add_library(freerdp-client3 SHARED freerdp-client3.c)
add_library(freerdp-server3 SHARED freerdp-server3.c)
install(TARGETS winpr3 freerdp3 freerdp-client3 freerdp-server3
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR})
install(FILES winpr3.pc freerdp3.pc freerdp-client3.pc freerdp-server3.pc
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/pkgconfig)
EOF
prefix="$tmp/openssl-prefix"
libdir="$prefix/lib/arm64-v8a"
mkdir -p "$libdir"
: > "$libdir/libssl.so"
: > "$libdir/libcrypto.so"
cc="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android31-clang"
log="$tmp/clang-freerdp.log"
: > "$log"
if ! PIXIE_CLANG_LOG="$log" \
  "$ROOT/packages/freerdp/packagefiles/freerdp/android-cmake.sh" \
    "$src" \
    "$tmp/freerdp-build" \
    "$tmp/freerdp-stage" \
    "$tmp/freerdp-link" \
    "$cc" \
    "$prefix" \
    "$libdir" \
    OFF \
    "$tmp/freerdp.stamp" \
    > "$tmp/freerdp-cmake.log" 2>&1; then
  echo "android-cmake.sh failed" >&2
  cat "$tmp/freerdp-cmake.log" >&2
  failures=1
else
destdir="$tmp/freerdp-destdir"
mkdir -p "$destdir"
MESON_INSTALL_DESTDIR_PREFIX="$destdir" \
  "$ROOT/packages/freerdp/packagefiles/freerdp/install-tree.sh" \
    "$tmp/freerdp-stage"
freerdp_tar="$tmp/freerdp.tar.xz"
"$ROOT/scripts/pixie-tree.sh" pack-fragment \
  --destdir "$destdir" \
  --abi arm64-v8a \
  --tarball "$freerdp_tar" >/dev/null
winpr_cmd="$(grep -F 'winpr.c' "$log" | grep -F ' -c ' | head -n1 || true)"
if [ -z "$winpr_cmd" ]; then
  echo "android-cmake.sh did not compile winpr.c" >&2
  cat "$log" >&2
  failures=1
else
  require_optimized freerdp "$winpr_cmd"
  require_packed_library "$freerdp_tar" published_fold libwinpr3.so
fi
fi

if [ "$failures" -ne 0 ]; then
  exit 1
fi
echo "published libraries are optimized and have no DWARF debug info"
