#!/usr/bin/env bash
# Bind an extracted sysroot to its path and write share/pixiewood/sysroot.cross.
set -euo pipefail

if [ "$#" -ne 1 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  echo "Usage: $0 SYSROOT" >&2
  echo "SYSROOT is the directory the release tarball was extracted into." >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$ROOT/sysroot-tree.sh" activate "$1"
