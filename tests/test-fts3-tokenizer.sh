#!/usr/bin/env bash
# Build sqlite the way packages/sqlite3 does, then run attacker SQL against it.
#
# Exits 0 when SQL text cannot call a native tokenizer module.
# Exits 1 while the package still compiles that module in as a default.
# This test is expected to fail until that compile flag is removed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAP="$ROOT/packages/sqlite3/sqlite3.wrap"
BUILD="$ROOT/packages/sqlite3/packagefiles/sqlite3/meson.build"
OPTIONS="$ROOT/packages/sqlite3/packagefiles/sqlite3/meson_options.txt"
PROBE="$ROOT/tests/fts3_tokenizer_probe.c"

flags="$(
  python3 - "$BUILD" "$OPTIONS" <<'PY'
import re, sys

build = open(sys.argv[1], encoding="utf-8").read()
opts = open(sys.argv[2], encoding="utf-8").read()

def option_default(name):
    match = re.search(r"option\(\s*'%s'\s*,(.*?)\)" % re.escape(name), opts, re.S)
    if not match:
        sys.exit("missing meson option %s" % name)
    value = re.search(r"value:\s*('auto'|true|false|'enabled'|'disabled')", match.group(1))
    if not value:
        sys.exit("missing default for %s" % name)
    return value.group(1).strip("'")

base = re.search(r"sqlite_args = \[(.*?)\]", build, re.S)
if not base:
    sys.exit("missing sqlite_args")
flags = re.findall(r"'(-D[^']+)'", base.group(1))

if option_default("strict") == "true":
    strict = re.search(r"if get_option\('strict'\)(.*?)endif", build, re.S)
    if not strict:
        sys.exit("missing strict flag block")
    flags += re.findall(r"'(-D[^']+)'", strict.group(1))

extensions = re.search(r"extensions = \[(.*)\]\s*extension_default", build, re.S)
if not extensions:
    sys.exit("missing extensions list")
all_ext = option_default("all-extensions")
for match in re.finditer(
    r"\[\s*'([A-Za-z0-9_]+)'\s*,\s*(true|false)\s*,\s*(\[[^\]]*\]|'[^']+')\s*,?\s*\]",
    extensions.group(1),
    re.S,
):
    name, default, raw = match.group(1), match.group(2), match.group(3)
    chosen = option_default(name)
    if chosen == "auto":
        if all_ext == "auto":
            enabled = default == "true"
        else:
            enabled = all_ext == "enabled"
    else:
        enabled = chosen in ("enabled", "true")
    if enabled:
        flags += re.findall(r"'(-D[^']+)'", raw)

if not flags:
    sys.exit("resolved no sqlite compile flags")
print("\n".join(flags))
PY
)"

url="$(sed -n "s/^source_url = //p" "$WRAP")"
hash="$(sed -n "s/^source_hash = //p" "$WRAP")"
directory="$(sed -n "s/^directory = //p" "$WRAP")"
if [[ -z "$url" || -z "$hash" || -z "$directory" ]]; then
  echo "sqlite3.wrap is missing source_url, source_hash, or directory" >&2
  exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
zip="$work/sqlite.zip"
curl -fsSL -o "$zip" "$url"
echo "$hash  $zip" | sha256sum -c -
unzip -q "$zip" -d "$work"
src="$work/$directory/sqlite3.c"
hdr="$work/$directory"
if [[ ! -f "$src" ]]; then
  echo "amalgamation sqlite3.c not found at $src" >&2
  exit 2
fi

cflags=()
while IFS= read -r flag; do
  [[ -n "$flag" ]] || continue
  cflags+=("$flag")
done <<<"$flags"

echo "compile flags:"
printf '  %s\n' "${cflags[@]}"

cc -O0 -o "$work/probe" "$PROBE" "$src" -I"$hdr" "${cflags[@]}" -ldl -lm -lpthread
"$work/probe"
