#!/bin/sh
# Copy the staged FreeRDP install into the pixie destdir.
set -eu
src=$1
dest=${MESON_INSTALL_DESTDIR_PREFIX:?}
mkdir -p "$dest"
cp -a "$src"/. "$dest"/
