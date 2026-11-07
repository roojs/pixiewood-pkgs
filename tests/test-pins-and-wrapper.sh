#!/usr/bin/env bash
# Wrap pins stay off main/master, and the Meson wrapper appends the sysroot.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

revision_of() {
  sed -n 's/^revision[[:space:]]*=[[:space:]]*//p' "$1" | head -n1 | tr -d '[:space:]'
}

assert_pinned() {
  local file="$1" rev
  rev="$(revision_of "$file")"
  case "$rev" in
    ""|main|master|HEAD)
      echo "wrap must not track '$rev': $file" >&2
      exit 1
      ;;
  esac
}

assert_pinned "$ROOT/stack/ollmchat/wraps/glib/glib.wrap"
assert_pinned "$ROOT/stack/ollmchat/wraps/gtk/gtk.wrap"
assert_pinned "$ROOT/stack/ollmchat/wraps/libadwaita/libadwaita.wrap"
assert_pinned "$ROOT/stack/ollmchat/wraps/gtk/pango.wrap.pin"
assert_pinned "$ROOT/stack/ollmchat/wraps/gtk/harfbuzz.wrap.pin"

fontconfig_rev="$(revision_of "$ROOT/stack/ollmchat/wraps/fontconfig/fontconfig.wrap")"
if [ "$fontconfig_rev" != "main" ]; then
  echo "fontconfig.wrap changed upstream pin unexpectedly: $fontconfig_rev" >&2
  echo "If you pinned it, update this test and the release notes." >&2
  exit 1
fi

# pango pin must not be named *.wrap or install would publish a second provider.
if compgen -G "$ROOT/stack/ollmchat/wraps/gtk/*.wrap" | grep -q 'pango\|harfbuzz'; then
  echo "pango/harfbuzz pins must stay *.wrap.pin" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/sysroot/share/pixiewood" "$tmp/bin"
cat > "$tmp/sysroot/share/pixiewood/MANIFEST.json" << EOF
{"format": 1, "abi": "arm64-v8a", "prefix_token": "@PIXIEWOOD_SYSROOT@", "activated_prefix": null}
EOF
# activate writes the cross file the wrapper requires
"$ROOT/scripts/sysroot-tree.sh" activate "$tmp/sysroot"

cat > "$tmp/bin/fake-meson" << 'EOF'
#!/bin/bash
printf '%s\n' "$@"
EOF
chmod +x "$tmp/bin/fake-meson"

output="$(
  PIXIEWOOD_SYSROOT="$tmp/sysroot" \
  PIXIEWOOD_REAL_MESON="$tmp/bin/fake-meson" \
    "$ROOT/scripts/meson-wrapper.sh" setup --cross-file toolchain.cross builddir sourcedir
)"
first="$(printf '%s\n' "$output" | head -n1)"
second="$(printf '%s\n' "$output" | sed -n '2p')"
third="$(printf '%s\n' "$output" | sed -n '3p')"
[ "$first" = "setup" ]
[ "$second" = "--cross-file" ]
[ "$third" = "$tmp/sysroot/share/pixiewood/sysroot.cross" ]
printf '%s\n' "$output" | grep -q '^toolchain.cross$'
printf '%s\n' "$output" | grep -qx 'builddir'
printf '%s\n' "$output" | grep -qx 'sourcedir'

forward="$(
  PIXIEWOOD_REAL_MESON="$tmp/bin/fake-meson" \
    "$ROOT/scripts/meson-wrapper.sh" compile -C builddir
)"
[ "$forward" = "compile
-C
builddir" ]

echo "pins and meson wrapper: ok"
