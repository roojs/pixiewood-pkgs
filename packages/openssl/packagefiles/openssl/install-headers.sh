#!/bin/sh
# Install the OpenSSL headers a later package compiles against.
# Generated headers replace the upstream copy of the same name.
set -eu
generated=$1
upstream=$2
if [ "$#" -ge 3 ]; then
  dest=$3
else
  dest="${MESON_INSTALL_DESTDIR_PREFIX:?}/include/openssl"
fi
mkdir -p "$dest"
if [ -d "$generated" ]; then
  find "$generated" -maxdepth 1 -type f -name '*.h' -exec cp -f {} "$dest/" \;
fi
if [ -d "$upstream" ]; then
  find "$upstream" -maxdepth 1 -type f -name '*.h' | while IFS= read -r file; do
    base=$(basename "$file")
    if [ ! -f "$dest/$base" ]; then
      cp -f "$file" "$dest/$base"
    fi
  done
fi
