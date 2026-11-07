#!/usr/bin/env bash
# Check a finalized (not necessarily activated) sysroot tree.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 SYSROOT" >&2
  exit 2
fi

sysroot="$(cd "$1" && pwd)"
manifest="$sysroot/share/pixiewood/MANIFEST.json"
python3 - "$sysroot" "$manifest" << 'PY'
import json
import sys
from pathlib import Path

sysroot = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
if not manifest_path.is_file():
    sys.exit(f"missing {manifest_path}")
meta = json.loads(manifest_path.read_text(encoding="utf-8"))
abi = meta["abi"]
pkgconfig = sysroot / meta["pkgconfig_dir"]
required = [
    "gtk4.pc",
    "glib-2.0.pc",
    "libadwaita-1.pc",
    "libsoup-3.0.pc",
    "gioopenssl.pc",
    "gee-0.8.pc",
    "gtksourceview-5.pc",
    "webkitgtk-android-1.pc",
]
missing = [name for name in required if not (pkgconfig / name).is_file()]
if missing:
    sys.exit("missing pkg-config files: " + ", ".join(missing))
glue = sysroot / meta["java_glue"] / "org" / "gtk" / "android"
if not glue.is_dir() or not any(glue.rglob("*.java")):
    sys.exit(f"GTK Android Java glue missing under {glue}")
for pc in pkgconfig.glob("*.pc"):
    for line in pc.read_text(encoding="utf-8", errors="replace").splitlines():
        if line == "prefix=/":
            sys.exit(f"{pc} still has prefix=/ (finalize did not rewrite it)")
print(f"sysroot ok: profile={meta['profile']} version={meta['version']} abi={abi} pcs={len(list(pkgconfig.glob('*.pc')))}")
PY
