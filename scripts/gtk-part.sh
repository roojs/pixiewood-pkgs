#!/usr/bin/env bash
# Install Android headers that gdkandroid.h includes and the GTK meson file omits.
# libadwaita includes the public header.
set -euo pipefail

install_referenced_android_headers() {
  local src=$1 meson header tmp name
  meson="$src/gdk/android/meson.build"
  header="$src/gdk/android/gdkandroid.h"
  [ -f "$meson" ] && [ -f "$header" ] || return 0
  local -a names=()
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -f "$src/gdk/android/$name" ] || continue
    if grep -q "'$name'" "$meson"; then
      continue
    fi
    names+=("$name")
  done < <(sed -n 's/.*<gdk\/android\/\([^>]*\)>.*/\1/p' "$header")
  [ "${#names[@]}" -gt 0 ] || return 0
  tmp="$(mktemp)"
  awk -v extra="$(printf '%s\n' "${names[@]}")" '
    BEGIN { n = split(extra, add, "\n") }
    inlist == 0 && $0 ~ /^gdk_android_public_headers = files\(\[/ {
      inlist = 1
      print
      next
    }
    inlist == 1 && $0 ~ /^\]\)/ {
      if (prev != "") {
        sub(/[[:space:]]*$/, "", prev)
        sub(/,$/, "", prev)
        print prev ","
      }
      for (i = 1; i <= n; i++) {
        if (add[i] == "") continue
        suffix = (i < n && add[i + 1] != "") ? "," : ""
        print "  \047" add[i] "\047" suffix
      }
      print
      inlist = 2
      next
    }
    inlist == 1 {
      if (prev != "") print prev
      prev = $0
      next
    }
    { print }
    END {
      if (inlist != 2) {
        print "gdk android public headers were not updated" > "/dev/stderr"
        exit 2
      }
    }
  ' "$meson" > "$tmp" || {
    echo "Could not install the Android headers referenced by $header" >&2
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$meson"
  echo "Installing Android headers: ${names[*]}"
}

command=${1:-}
shift || true
case "$command" in
  patch)
    [ -n "${1:-}" ] || { echo "Usage: $0 patch SRC" >&2; exit 2; }
    install_referenced_android_headers "$1"
    ;;
  *)
    echo "Usage: $0 patch SRC" >&2
    exit 2
    ;;
esac
