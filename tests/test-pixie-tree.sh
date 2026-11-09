#!/usr/bin/env bash
# Pack, activate, and stage pixie libraries without the Android NDK.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

destdir="$tmp/destdir"
abi=arm64-v8a
pkg="$destdir/lib/$abi/pkgconfig"
mkdir -p "$pkg" "$destdir/lib/$abi/gio/modules" "$destdir/share/glib-2.0/schemas"
cat > "$pkg/gtk4.pc" << 'EOF'
prefix=/
libdir=${prefix}/lib/arm64-v8a
includedir=${prefix}/include
Name: gtk4
Description: GTK
Version: 4.18.0
Libs: -L${libdir} -lgtk-4
Cflags: -I${includedir}/gtk-4.0
EOF
printf '%s\n' 'prefix=/' 'Name: glib' 'Version: 2.90.0' 'Libs: -L${prefix}/lib/arm64-v8a -lglib-2.0' \
  > "$pkg/glib-2.0.pc"
printf 'not-a-real-elf\n' > "$destdir/lib/$abi/libgtk-4.so"
printf 'archive\n' > "$destdir/lib/$abi/gio/modules/libgioopenssl.a"
printf '<schema/>\n' > "$destdir/share/glib-2.0/schemas/org.gtk.Settings.gschema.xml"
mkdir -p "$tmp/java/org/gtk/android"
printf 'class ToplevelActivity {}\n' > "$tmp/java/org/gtk/android/ToplevelActivity.java"
printf 'glib\ngtk\nopenssl\n' > "$tmp/provided.txt"
mkdir -p "$destdir/bin/$abi" "$destdir/share/glib-2.0/codegen"
# Same lookup as GLib's gdbus-codegen: bin/$abi is not named bin, and the
# baked datadir is /share, so the import only works via PYTHONPATH.
cat > "$destdir/bin/$abi/gdbus-codegen" << 'EOF'
#!/usr/bin/env python3
import os
import sys
path = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
if not os.path.isfile(os.path.join(path, 'codegen', 'codegen_main.py')):
    path = os.path.join('/share', 'glib-2.0')
sys.path.insert(0, path)
from codegen import codegen_main
raise SystemExit(codegen_main.codegen_main())
EOF
chmod a+x "$destdir/bin/$abi/gdbus-codegen"
cat > "$destdir/share/glib-2.0/codegen/__init__.py" << 'EOF'
EOF
cat > "$destdir/share/glib-2.0/codegen/codegen_main.py" << 'EOF'
def codegen_main():
    print('codegen-ok')
    return 0
EOF

"$ROOT/scripts/pixie-tree.sh" finalize \
  --destdir "$destdir" \
  --version 0.1.0 \
  --abi "$abi" \
  --arch aarch64 \
  --api 31 \
  --ndk 28.2.13676358 \
  --pixiewood-revision abc \
  --gtk-target Knowles.android-ime \
  --gtk-url https://gitlab.gnome.org/Knowles/gtk.git \
  --gtk-revision android-ime \
  --provided "$tmp/provided.txt" \
  --java-glue "$tmp/java"

gtk="$(cat "$destdir/lib/$abi/pkgconfig/gtk4.pc")"
printf '%s\n' "$gtk" | grep -q '^prefix=@PIXIEWOOD_SYSROOT@$'
if printf '%s\n' "$gtk" | grep -q '^prefix=/$'; then
  echo "gtk4.pc still has prefix=/" >&2
  exit 1
fi
gio="$(cat "$destdir/lib/$abi/pkgconfig/gioopenssl.pc")"
printf '%s\n' "$gio" | grep -q '^prefix=@PIXIEWOOD_SYSROOT@$'
printf '%s\n' "$gio" | grep -q 'libgioopenssl.a'
manifest="$destdir/share/pixiewood/MANIFEST.json"
grep -q '"gtk_target": "Knowles.android-ime"' "$manifest"
grep -q 'Knowles/gtk' "$manifest"
grep -q '"format": 1' "$manifest"
grep -q '"provided_dependencies": \["glib", "gtk", "openssl"\]' "$manifest"
grep -q '"pc": "gtk4"' "$manifest"
grep -q '"pc": "gioopenssl"' "$manifest"
test -f "$destdir/share/pixiewood/gtk-android-java/org/gtk/android/ToplevelActivity.java"

"$ROOT/scripts/pixie-tree.sh" activate "$destdir"
grep -q "^prefix=$destdir$" "$destdir/lib/$abi/pkgconfig/gtk4.pc"
cross_tool="$(sed -n "s/^gdbus-codegen = \['\(.*\)'\]/\\1/p" "$destdir/share/pixiewood/pixie.cross")"
test -n "$cross_tool"
test -x "$cross_tool"
test "$cross_tool" != "$destdir/bin/$abi/gdbus-codegen"
[ "$("$cross_tool")" = codegen-ok ]
cross="$(cat "$destdir/share/pixiewood/pixie.cross")"
printf '%s\n' "$cross" | grep -q 'pkg-config'
if printf '%s\n' "$cross" | grep -q 'sys_root'; then
  echo "pixie.cross must not set sys_root" >&2
  exit 1
fi
test -x "$destdir/share/pixiewood/pkg-config-wrapper"

root="$tmp/pixiewood-root"
"$ROOT/scripts/stage-runtime.sh" "$destdir" "$root"
test -f "$root/lib/$abi/libgtk-4.so"
test -f "$root/share/glib-2.0/schemas/org.gtk.Settings.gschema.xml"

moved="$tmp/moved"
mv "$destdir" "$moved"
"$ROOT/scripts/pixie-tree.sh" activate "$moved"
grep -q "^prefix=$moved$" "$moved/lib/$abi/pkgconfig/gtk4.pc"
cross_tool="$(sed -n "s/^gdbus-codegen = \['\(.*\)'\]/\\1/p" "$moved/share/pixiewood/pixie.cross")"
[ "$("$cross_tool")" = codegen-ok ]
if grep -q "^prefix=$destdir$" "$moved/lib/$abi/pkgconfig/gtk4.pc"; then
  echo "activate left the old prefix in gtk4.pc" >&2
  exit 1
fi

echo "pixie tree: ok"
