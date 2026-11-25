# Install the pixie-pkg commit named in scripts/pixie-pkg.pin and make the
# pixie-pkg function run it. Source this file; do not execute it.
#
# The pin is a full git object id. Change it only in a reviewed commit.
# install-local.sh and pixie-pkg run without GH_TOKEN or GITHUB_TOKEN.

_pixie_pkg_bin=""

pixie-pkg() {
  if [ -z "$_pixie_pkg_bin" ]; then
    echo "pixie-pkg: run require_pixie first" >&2
    return 1
  fi
  env -u GH_TOKEN -u GITHUB_TOKEN "$_pixie_pkg_bin" "$@"
}

require_pixie() {
  if [ -n "$_pixie_pkg_bin" ]; then
    return 0
  fi
  local url root dest src pin line want have
  url=https://github.com/roojs/pixie-pkg.git
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  dest="$root/.cache/pixie-pkg"
  src="$dest/src"

  if [ ! -f "$root/scripts/pixie-pkg.pin" ]; then
    echo "require_pixie: scripts/pixie-pkg.pin is missing" >&2
    return 1
  fi
  line=""
  IFS= read -r line < "$root/scripts/pixie-pkg.pin" || true
  pin="${line%"${line##*[![:space:]]}"}"
  if ! [[ "$pin" =~ ^[0-9a-f]{40}$ ]]; then
    echo "require_pixie: scripts/pixie-pkg.pin is not a 40-digit git object id" >&2
    return 1
  fi

  # Nothing already under .cache/pixie-pkg is trusted; it is rebuilt from the pin.
  rm -rf "$dest"
  mkdir -p "$dest"
  git init -q "$src" || return 1
  # A server that refuses a want for a commit that is not a branch tip gets
  # asked for its branches and tags instead. Either way the checkout is by id.
  if ! git -C "$src" fetch -q --depth 1 --no-tags "$url" "$pin" 2>/dev/null; then
    git -C "$src" fetch -q --no-tags "$url" \
      '+refs/heads/*:refs/pixie/heads/*' '+refs/tags/*:refs/pixie/tags/*' || return 1
  fi
  git -C "$src" -c advice.detachedHead=false checkout -q --detach "$pin^{commit}" || return 1

  have="$(git -C "$src" rev-parse HEAD)" || return 1
  if [ "$have" != "$pin" ]; then
    echo "require_pixie: pixie-pkg checkout is $have, not the pin $pin" >&2
    return 1
  fi
  want="$(git -C "$src" rev-parse "$pin:scripts/install-local.sh")" || return 1
  have="$(git -C "$src" hash-object scripts/install-local.sh)" || return 1
  if [ "$have" != "$want" ]; then
    echo "require_pixie: scripts/install-local.sh does not match the pin $pin" >&2
    return 1
  fi
  if [ -n "$(git -C "$src" status --porcelain)" ]; then
    echo "require_pixie: pixie-pkg checkout differs from the pin $pin" >&2
    return 1
  fi

  env -u GH_TOKEN -u GITHUB_TOKEN PREFIX="$dest" \
    "$src/scripts/install-local.sh" || return 1
  if [ ! -x "$dest/bin/pixie-pkg" ]; then
    echo "require_pixie: install-local.sh did not install bin/pixie-pkg" >&2
    return 1
  fi
  _pixie_pkg_bin="$dest/bin/pixie-pkg"
}
