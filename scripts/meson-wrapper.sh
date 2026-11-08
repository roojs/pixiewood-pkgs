#!/usr/bin/env bash
# Meson executable to pass to `pixiewood prepare --meson`.
#
# When PIXIEWOOD_PIXIE is set, `meson setup` also receives the activated
# pixie cross file. Other Meson invocations are forwarded unchanged.
set -euo pipefail

real_meson="${PIXIEWOOD_REAL_MESON:-meson}"

if [ -z "${PIXIEWOOD_PIXIE:-}" ]; then
  exec "$real_meson" "$@"
fi

sysroot="$(cd "$PIXIEWOOD_PIXIE" && pwd)"
cross="$sysroot/share/pixiewood/pixie.cross"
if [ ! -f "$cross" ]; then
  echo "Pixie cross file missing: $cross" >&2
  echo "Run scripts/activate-pixie.sh on the unpacked libraries first." >&2
  exit 1
fi

if [ "${1:-}" = "setup" ] || [ "${1:-}" = "configure" ]; then
  shift
  exec "$real_meson" setup --cross-file "$cross" "$@"
fi

exec "$real_meson" "$@"
