#!/usr/bin/env bash
# Bind unpacked pixie libraries to their path and write share/pixiewood/pixie.cross.
set -euo pipefail

if [ "$#" -ne 1 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  echo "Usage: $0 DIR" >&2
  echo "DIR is the directory the pixie libraries were unpacked into." >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$ROOT/pixie-tree.sh" activate "$1"
