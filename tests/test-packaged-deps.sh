#!/usr/bin/env bash
# A nested wrap is dropped when the sysroot already publishes that dependency.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bash -n "$ROOT/scripts/packaged-deps.sh"

wrap="$tmp/pango.wrap"
cat > "$wrap" << 'EOF'
[wrap-git]
directory = pango

[provide]
pango = libpango_dep
pangoft2 = libpangoft2_dep
dependency_names = pangocairo
EOF
"$ROOT/scripts/packaged-deps.sh" names "$wrap" > "$tmp/names"
grep -qx pango "$tmp/names"
grep -qx pangoft2 "$tmp/names"
grep -qx pangocairo "$tmp/names"

work="$tmp/work"
sysroot="$tmp/sysroot"
abi=arm64-v8a
mkdir -p "$work/subprojects/gtk/subprojects" "$work/subprojects/cairo/subprojects" \
  "$sysroot/lib/$abi/pkgconfig"
cp "$wrap" "$work/subprojects/gtk/subprojects/pango.wrap"
cp "$wrap" "$work/subprojects/pango.wrap"
cat > "$work/subprojects/cairo/subprojects/pixman.wrap" << 'EOF'
[provide]
pixman-1 = idep_pixman
EOF
printf 'Name: pango\n' > "$sysroot/lib/$abi/pkgconfig/pango.pc"

"$ROOT/scripts/packaged-deps.sh" drop "$work" "$sysroot" "$abi" > "$tmp/drop.out"
grep -q 'Using packaged pango' "$tmp/drop.out"
[ ! -f "$work/subprojects/gtk/subprojects/pango.wrap" ]
[ -f "$work/subprojects/pango.wrap" ]
[ -f "$work/subprojects/cairo/subprojects/pixman.wrap" ]

printf 'Name: pixman\n' > "$sysroot/lib/$abi/pkgconfig/pixman-1.pc"
"$ROOT/scripts/packaged-deps.sh" drop "$work" "$sysroot" "$abi" > "$tmp/drop2.out"
[ ! -f "$work/subprojects/cairo/subprojects/pixman.wrap" ]
[ -f "$work/subprojects/pango.wrap" ]

echo "packaged deps: ok"
