#!/usr/bin/env bash
# Pack (finalize) or activate a pixiewood Android sysroot tree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sysroot-common.sh
source "$ROOT/sysroot-common.sh"

TOKEN='@PIXIEWOOD_SYSROOT@'

usage() {
  echo "Usage: $0 finalize --destdir DIR --profile NAME --version VER --abi ABI --arch ARCH --api N --ndk VER --pixiewood-revision REV --ollmchat-wraps-revision REV --provided FILE --java-glue DIR" >&2
  echo "       $0 activate SYSROOT" >&2
  exit 2
}

pc_field() {
  local file=$1 key=$2
  sed -n "s/^${key}:[[:space:]]*//p" "$file" | head -n1 | tr -d '\r'
}

write_gioopenssl_pc() {
  local destdir=$1 abi=$2 archive pkg
  archive="$destdir/lib/$abi/gio/modules/libgioopenssl.a"
  [ -f "$archive" ] || return 0
  pkg="$destdir/lib/$abi/pkgconfig"
  mkdir -p "$pkg"
  # glib-networking's generated .pc describes the shared GIO module.
  # OLLMchat links the static archive and calls g_io_openssl_load().
  cat > "$pkg/gioopenssl.pc" << EOF
prefix=/
libdir=\${prefix}/lib/${abi}

Name: gioopenssl
Description: Static GIO OpenSSL TLS backend
Version: 2.80.1
Requires: gio-2.0
Requires.private: libssl libcrypto
Libs: \${libdir}/gio/modules/libgioopenssl.a
Cflags:
EOF
}

write_manifest() {
  local destdir=$1 profile=$2 version=$3 abi=$4 arch=$5 api=$6 ndk=$7
  local pixiewood_rev=$8 ollmchat_rev=$9 provided=${10}
  local pkgconfig="$destdir/lib/$abi/pkgconfig"
  local meta="$destdir/share/pixiewood"
  local manifest="$meta/MANIFEST.json"
  local -a names=()
  local line name version_pc pc base count first

  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    names+=("$line")
  done < "$provided"
  if [ "${#names[@]}" -eq 0 ]; then
    echo "No provided dependencies in $provided" >&2
    exit 1
  fi

  mkdir -p "$meta"
  {
    printf '{\n'
    printf '  "format": 1,\n'
    printf '  "name": "pixiewood-android-sysroot",\n'
    printf '  "profile": "%s",\n' "$(sysroot_json_escape "$profile")"
    printf '  "version": "%s",\n' "$(sysroot_json_escape "$version")"
    printf '  "abi": "%s",\n' "$(sysroot_json_escape "$abi")"
    printf '  "arch": "%s",\n' "$(sysroot_json_escape "$arch")"
    printf '  "api": %s,\n' "$api"
    printf '  "ndk": "%s",\n' "$(sysroot_json_escape "$ndk")"
    printf '  "pixiewood_revision": "%s",\n' "$(sysroot_json_escape "$pixiewood_rev")"
    printf '  "ollmchat_wraps_revision": "%s",\n' "$(sysroot_json_escape "$ollmchat_rev")"
    printf '  "pkgconfig_dir": "%s",\n' "$(sysroot_json_escape "lib/$abi/pkgconfig")"
    printf '  "java_glue": "share/pixiewood/gtk-android-java",\n'
    printf '  "prefix_token": "%s",\n' "$TOKEN"
    printf '  "provided_dependencies": ['
    first=1
    for name in "${names[@]}"; do
      if [ "$first" -eq 1 ]; then
        first=0
      else
        printf ', '
      fi
      printf '"%s"' "$(sysroot_json_escape "$name")"
    done
    printf '],\n'
    printf '  "components": [\n'
    count=0
    first=1
    if [ -d "$pkgconfig" ]; then
      while IFS= read -r pc; do
        [ -n "$pc" ] || continue
        base="$(basename "$pc" .pc)"
        name="$(pc_field "$pc" Name)"
        [ -n "$name" ] || name="$base"
        version_pc="$(pc_field "$pc" Version)"
        if [ "$first" -eq 1 ]; then
          first=0
        else
          printf ',\n'
        fi
        printf '    {"pc": "%s", "name": "%s", "version": "%s"}' \
          "$(sysroot_json_escape "$base")" \
          "$(sysroot_json_escape "$name")" \
          "$(sysroot_json_escape "$version_pc")"
        count=$((count + 1))
      done < <(find "$pkgconfig" -name '*.pc' -type f | sort)
    fi
    if [ "$first" -eq 0 ]; then
      printf '\n'
    fi
    printf '  ],\n'
    printf '  "activated_prefix": null\n'
    printf '}\n'
  } > "$manifest"
  echo "Wrote $manifest ($count pkg-config files)"
}

cmd_finalize() {
  local destdir= profile= version= abi= arch= api= ndk=
  local pixiewood_rev= ollmchat_rev= provided= java_glue=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --destdir) destdir=$2; shift 2 ;;
      --profile) profile=$2; shift 2 ;;
      --version) version=$2; shift 2 ;;
      --abi) abi=$2; shift 2 ;;
      --arch) arch=$2; shift 2 ;;
      --api) api=$2; shift 2 ;;
      --ndk) ndk=$2; shift 2 ;;
      --pixiewood-revision) pixiewood_rev=$2; shift 2 ;;
      --ollmchat-wraps-revision) ollmchat_rev=$2; shift 2 ;;
      --provided) provided=$2; shift 2 ;;
      --java-glue) java_glue=$2; shift 2 ;;
      *) echo "Unknown argument: $1" >&2; usage ;;
    esac
  done
  for value in "$destdir" "$profile" "$version" "$abi" "$arch" "$api" "$ndk" \
    "$pixiewood_rev" "$ollmchat_rev" "$provided" "$java_glue"; do
    if [ -z "$value" ]; then
      usage
    fi
  done
  if [ ! -d "$destdir" ]; then
    echo "Destdir missing: $destdir" >&2
    exit 1
  fi
  if [ ! -d "$java_glue" ]; then
    echo "Java glue directory missing: $java_glue" >&2
    exit 1
  fi
  destdir="$(cd "$destdir" && pwd)"
  java_glue="$(cd "$java_glue" && pwd)"
  write_gioopenssl_pc "$destdir" "$abi"
  sysroot_rewrite_prefix '/' "$TOKEN" "$destdir"
  mkdir -p "$destdir/share/pixiewood/gtk-android-java"
  cp -a "$java_glue/." "$destdir/share/pixiewood/gtk-android-java/"
  write_manifest "$destdir" "$profile" "$version" "$abi" "$arch" "$api" "$ndk" \
    "$pixiewood_rev" "$ollmchat_rev" "$provided"
}

sh_single_quote() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

write_wrapper() {
  local path=$1 pkgconfig=$2
  mkdir -p "$(dirname "$path")"
  cat > "$path" << EOF
#!/bin/sh
# Meson sets PKG_CONFIG_SYSROOT_DIR from the NDK sysroot.
# These .pc files already use absolute paths in the pixiewood sysroot.
unset PKG_CONFIG_SYSROOT_DIR
export PKG_CONFIG_LIBDIR=$(sh_single_quote "$pkgconfig")
export PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1
export PKG_CONFIG_ALLOW_SYSTEM_LIBS=1
exec pkg-config "\$@"
EOF
  chmod a+x "$path"
}

meson_quote() {
  local s=$1
  s=${s//\'/\\\'}
  printf "'%s'" "$s"
}

write_cross() {
  local sysroot=$1 abi=$2 wrapper=$3
  local pkgconfig="$sysroot/lib/$abi/pkgconfig"
  local dest="$sysroot/share/pixiewood/sysroot.cross"
  local tool script quoted_wrapper
  quoted_wrapper="$(meson_quote "$wrapper")"
  {
    printf '[binaries]\n'
    printf 'pkg-config = [%s]\n' "$quoted_wrapper"
    for tool in glib-mkenums glib-genmarshal gdbus-codegen; do
      script="$sysroot/bin/$abi/$tool"
      # Installed GLib tools are scripts. Run them through their shebang.
      if [ -f "$script" ] && [ "$(head -c 2 "$script")" = '#!' ]; then
        printf '%s = [%s]\n' "$tool" "$(meson_quote "$script")"
      fi
    done
    printf '\n[properties]\n'
    printf 'pkg_config_libdir = [%s]\n' "$(meson_quote "$pkgconfig")"
  } > "$dest"
}

cmd_activate() {
  local sysroot=${1:-}
  [ -n "$sysroot" ] || usage
  sysroot="$(cd "$sysroot" && pwd)"
  local manifest="$sysroot/share/pixiewood/MANIFEST.json"
  if [ ! -f "$manifest" ]; then
    echo "Sysroot manifest missing: $manifest" >&2
    exit 1
  fi
  local format abi token previous target pkgconfig
  format="$(sysroot_json_get format "$manifest")"
  if [ "$format" != 1 ]; then
    echo "Unsupported sysroot format: $format" >&2
    exit 1
  fi
  abi="$(sysroot_json_get abi "$manifest")"
  token="$(sysroot_json_get prefix_token "$manifest")"
  [ -n "$token" ] || token=$TOKEN
  previous="$(sysroot_json_get activated_prefix "$manifest")"
  target=$sysroot
  pkgconfig="$sysroot/lib/$abi/pkgconfig"
  if [ "$previous" = "$target" ] && ! sysroot_pc_contains "$pkgconfig" "$token"; then
    :
  else
    sysroot_rewrite_prefix "$token" "$target" "$sysroot"
    if [ -n "$previous" ] && [ "$previous" != "$target" ]; then
      sysroot_rewrite_prefix "$previous" "$target" "$sysroot"
    fi
  fi
  local wrapper="$sysroot/share/pixiewood/pkg-config-wrapper"
  write_wrapper "$wrapper" "$pkgconfig"
  write_cross "$sysroot" "$abi" "$wrapper"
  sysroot_set_activated_prefix "$manifest" "$target"
  echo "Activated $sysroot"
  echo "Meson cross file: $sysroot/share/pixiewood/sysroot.cross"
}

command=${1:-}
shift || usage
case "$command" in
  finalize) cmd_finalize "$@" ;;
  activate) cmd_activate "$@" ;;
  *) usage ;;
esac
