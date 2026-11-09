# Put the pixie-pkg command on PATH.
# Source this file; do not execute it.

require_pixie() {
  if command -v pixie-pkg >/dev/null 2>&1; then
    return 0
  fi
  local root dest
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  dest="$root/.cache/pixie-pkg"
  if [ ! -x "$dest/bin/pixie-pkg" ]; then
    rm -rf "$dest/src"
    mkdir -p "$dest"
    git clone --depth 1 https://github.com/roojs/pixie-pkg.git "$dest/src"
    PREFIX="$dest" "$dest/src/scripts/install-local.sh"
  fi
  export PATH="$dest/bin:$PATH"
  hash -r
}
