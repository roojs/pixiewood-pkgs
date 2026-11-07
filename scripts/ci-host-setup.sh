#!/usr/bin/env bash
# Host packages for a sysroot build.
# Fontconfig's main branch requires Meson >= 1.11, and GTK requires >= 1.8.
# Ubuntu's package is older, so a newer Meson is installed onto PATH for this step.
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  APT=(apt-get)
else
  APT=(sudo apt-get)
fi

"${APT[@]}" update
"${APT[@]}" install -y --no-install-recommends \
  build-essential \
  ca-certificates \
  cmake \
  curl \
  flex \
  bison \
  gettext \
  git \
  glslc \
  gperf \
  meson \
  nasm \
  ninja-build \
  pkg-config \
  python3 \
  python3-packaging \
  sassc \
  unzip \
  valac

version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n1)" = "$1" ]
}

if command -v meson >/dev/null 2>&1 && version_ge "$(meson --version)" 1.11.0; then
  echo "Using $(command -v meson) $(meson --version)"
  exit 0
fi

tools="${RUNNER_TEMP:-/tmp}/meson"
pool="https://deb.debian.org/debian/pool/main/m/meson"
deb="$(curl -fsSL "$pool/" \
  | grep -oE 'href="meson_[^"]+_all\.deb"' \
  | sed 's/^href="//;s/"$//' \
  | sort -V \
  | tail -n1)"
if [ -z "$deb" ]; then
  echo "Could not find a meson deb under $pool" >&2
  exit 1
fi
tmp="$(mktemp -d)"
curl -fsSL "$pool/$deb" -o "$tmp/meson.deb"
mkdir -p "$tools/root" "$tools/bin"
dpkg-deb -x "$tmp/meson.deb" "$tools/root"
real="$tools/root/usr/bin/meson"
mv "$real" "$real.real"
printf '%s\n' \
  '#!/bin/sh' \
  "export PYTHONPATH=\"$tools/root/usr/lib/python3/dist-packages\${PYTHONPATH:+:\$PYTHONPATH}\"" \
  "exec python3 \"$real.real\" \"\$@\"" \
  > "$real"
chmod +x "$real" "$real.real"
ln -sf "$real" "$tools/bin/meson"
# /usr/local/bin is already on PATH. GITHUB_PATH only affects later steps,
# and this script runs in the same step as the build.
if [ "$(id -u)" -eq 0 ]; then
  ln -sfn "$real" /usr/local/bin/meson
else
  sudo ln -sfn "$real" /usr/local/bin/meson
fi
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$tools/bin" >> "$GITHUB_PATH"
fi
hash -r
echo "Using $(command -v meson) $(meson --version)"
