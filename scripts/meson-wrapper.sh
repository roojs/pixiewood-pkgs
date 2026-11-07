#!/usr/bin/env bash
# Meson executable to pass to `pixiewood prepare --meson`.
#
# When PIXIEWOOD_SYSROOT is set, `meson setup` also receives the activated
# sysroot cross file. Other Meson invocations are forwarded unchanged.
set -euo pipefail

real_meson="${PIXIEWOOD_REAL_MESON:-meson}"

if [ -z "${PIXIEWOOD_SYSROOT:-}" ]; then
  exec "$real_meson" "$@"
fi

sysroot="$(cd "$PIXIEWOOD_SYSROOT" && pwd)"
cross="$sysroot/share/pixiewood/sysroot.cross"
if [ ! -f "$cross" ]; then
  echo "Sysroot cross file missing: $cross" >&2
  echo "Run scripts/activate-sysroot.sh on the extracted tarball first." >&2
  exit 1
fi

if [ "${1:-}" = "setup" ] || [ "${1:-}" = "configure" ]; then
  shift
  exec "$real_meson" setup --cross-file "$cross" "$@"
fi

exec "$real_meson" "$@"
