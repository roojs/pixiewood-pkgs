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

assert_pinned "$ROOT/packages/glib/glib.wrap"
assert_pinned "$ROOT/packages/gtk/gtk.wrap"
assert_pinned "$ROOT/packages/libadwaita/libadwaita.wrap"
assert_pinned "$ROOT/packages/gtk/pango.wrap.pin"
assert_pinned "$ROOT/packages/gtk/harfbuzz.wrap.pin"
assert_pinned "$ROOT/packages/fribidi/fribidi.wrap"
assert_pinned "$ROOT/packages/harfbuzz/harfbuzz.wrap"
assert_pinned "$ROOT/packages/cairo/cairo.wrap"
assert_pinned "$ROOT/packages/pango/pango.wrap"
assert_pinned "$ROOT/packages/gdk-pixbuf/gdk-pixbuf.wrap"
assert_pinned "$ROOT/packages/libepoxy/libepoxy.wrap"
assert_pinned "$ROOT/packages/graphene/graphene.wrap"

fontconfig_rev="$(revision_of "$ROOT/packages/fontconfig/fontconfig.wrap")"
if [ "$fontconfig_rev" != "main" ]; then
  echo "fontconfig.wrap changed upstream pin unexpectedly: $fontconfig_rev" >&2
  echo "If you pinned it, update this test and the release notes." >&2
  exit 1
fi

# shellcheck source=../scripts/gtk-target.sh
source "$ROOT/scripts/gtk-target.sh"
read -r gnome_url gnome_rev gnome_patch < <(gtk_target_read "$ROOT/packages/gtk/targets" gnome)
[ "$gnome_url" = "https://gitlab.gnome.org/GNOME/gtk.git" ]
[ "$gnome_rev" = "$(revision_of "$ROOT/packages/gtk/gtk.wrap")" ]
[ "$gnome_patch" = "-" ]
if gtk_target_read "$ROOT/packages/gtk/targets" Knowles.android-ime >/dev/null 2>&1; then
  echo "this distribution still lists the IME target" >&2
  exit 1
fi
ime_url=https://gitlab.gnome.org/Knowles/gtk.git
ime_rev=android-ime
wrap_copy="$(mktemp)"
cp "$ROOT/packages/gtk/gtk.wrap" "$wrap_copy"
gtk_target_apply_wrap "$wrap_copy" "$ime_url" "$ime_rev"
grep -q "^url = $ime_url$" "$wrap_copy"
grep -q "^revision = $ime_rev$" "$wrap_copy"
rm -f "$wrap_copy"

# A branch target is owner.branch. A nickname is rejected. Another fork is another line.
bad_targets="$(mktemp)"
printf '%s\n' 'ime https://gitlab.gnome.org/Knowles/gtk.git android-ime -' > "$bad_targets"
if gtk_target_read "$bad_targets" ime >/dev/null 2>"$bad_targets.err"; then
  echo "nickname ime was accepted" >&2
  exit 1
fi
grep -q 'Knowles.android-ime' "$bad_targets.err"
cat > "$bad_targets" << 'EOF'
gnome https://gitlab.gnome.org/GNOME/gtk.git ae709f962a51f9108a1e6381bcfbd05bbaecc840 -
Knowles.android-ime https://gitlab.gnome.org/Knowles/gtk.git android-ime -
Other.feature https://gitlab.gnome.org/Other/gtk.git feature -
EOF
read -r other_url other_rev other_patch < <(gtk_target_read "$bad_targets" Other.feature)
[ "$other_url" = "https://gitlab.gnome.org/Other/gtk.git" ]
[ "$other_rev" = feature ]
[ "$other_patch" = "-" ]
rm -f "$bad_targets" "$bad_targets.err"

# pango pin must not be named *.wrap or install would publish a second provider.
if compgen -G "$ROOT/packages/gtk/*.wrap" | grep -q 'pango\|harfbuzz'; then
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

# build-sysroot checks the wrap out before Meson, then applies diff_files.
# The patch has to match the private declaration it exports.
glib_tree="$tmp/glib-tree"
mkdir -p "$glib_tree/glib"
cat > "$glib_tree/glib/gutilsprivate.h" << 'EOF'

G_BEGIN_DECLS

void g_set_user_dirs (const gchar *first_dir_type,
                      ...) G_GNUC_NULL_TERMINATED;

EOF
patch -p1 -d "$glib_tree" --forward --batch < "$ROOT/packages/glib/packagefiles/glib/hack.patch" >/dev/null
grep -q '^GLIB_AVAILABLE_IN_ALL$' "$glib_tree/glib/gutilsprivate.h"

echo "pins and meson wrapper: ok"
