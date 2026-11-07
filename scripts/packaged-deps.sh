#!/usr/bin/env bash
# A nested Meson wrap is removed when the dependency sysroot already has that
# package, so the build links the package instead of compiling it again.
set -euo pipefail

wrap_dependency_names() {
  local wrap=$1
  awk '
    /^\[provide\]/ { section = 1; next }
    /^\[/ { section = 0 }
    section && /^[[:space:]]*#/ { next }
    section && /^[[:space:]]*dependency_names[[:space:]]*=/ {
      line = $0
      sub(/^[^=]*=/, "", line)
      gsub(/[[:space:]]/, "", line)
      n = split(line, parts, ",")
      for (i = 1; i <= n; i++) if (parts[i] != "") print parts[i]
      next
    }
    section && /^[[:space:]]*program_names[[:space:]]*=/ { next }
    section && /=/ {
      name = $1
      sub(/[[:space:]]*=.*/, "", name)
      if (name != "") print name
    }
  ' "$wrap"
}

drop_satisfied_wraps() {
  local work=$1 sysroot=$2 abi=$3
  local pcdir wrap name satisfied
  [ -n "$sysroot" ] || return 0
  pcdir="$sysroot/lib/$abi/pkgconfig"
  [ -d "$pcdir" ] || return 0
  [ -d "$work/subprojects" ] || return 0
  while IFS= read -r wrap; do
    [ -f "$wrap" ] || continue
    if [ "$(dirname "$wrap")" = "$work/subprojects" ]; then
      continue
    fi
    satisfied=0
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      if [ -f "$pcdir/${name}.pc" ]; then
        satisfied=1
        break
      fi
    done < <(wrap_dependency_names "$wrap")
    if [ "$satisfied" -eq 1 ]; then
      echo "Using packaged $(basename "$wrap" .wrap)"
      rm -f "$wrap"
    fi
  done < <(find "$work/subprojects" -name '*.wrap' -type f | LC_ALL=C sort)
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    names)
      wrap_dependency_names "$2"
      ;;
    drop)
      [ "$#" -eq 4 ] || { echo "Usage: $0 drop WORK SYSROOT ABI" >&2; exit 2; }
      drop_satisfied_wraps "$2" "$3" "$4"
      ;;
    *)
      echo "Usage: $0 names WRAP | drop WORK SYSROOT ABI" >&2
      exit 2
      ;;
  esac
fi
