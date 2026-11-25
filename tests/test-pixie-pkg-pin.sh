#!/usr/bin/env bash
# Pin for scripts/require-pixie.sh.
#
# scripts/pixie-pkg.pin contains one line: the full lowercase git object id
# of the pixie-pkg commit to install. Optional trailing whitespace is ignored.
# Anything that is not a 40-digit hexadecimal object id is rejected.
#
# require_pixie, and every caller that reaches it, must:
#   1. Fetch that object id from https://github.com/roojs/pixie-pkg.git.
#   2. Check out that commit and refuse unless HEAD is that object id and
#      scripts/install-local.sh in the work tree is the blob in that commit.
#   3. Run install-local.sh only after that check. A clone of the default
#      branch, a second lookup of the branch, or a pre-existing
#      .cache/pixie-pkg/bin/pixie-pkg must not execute.
#   4. Leave .cache/pixie-pkg/src at that commit.
#   5. Run install-local.sh and the pixie-pkg it installs with GH_TOKEN and
#      GITHUB_TOKEN unset. prove-package.sh still publishes with GH_TOKEN
#      when PROVE_PUBLISH=1, because that step is the same shell as the fetch.
#
# The cases below fail while the default branch is cloned and executed.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
backup=""
snap_backup=""
had_snap=0

note() {
  echo "$1" >&2
  fail=1
}

cleanup() {
  rm -rf "$ROOT/.cache/pixie-pkg"
  rm -f "$ROOT/scripts/pixie-pkg.pin"
  if [ -n "$backup" ] && [ -f "$backup" ]; then
    cp -a "$backup" "$ROOT/release.pins"
  fi
  if [ "$had_snap" -eq 1 ] && [ -n "$snap_backup" ] && [ -f "$snap_backup" ]; then
    cp -a "$snap_backup" "$ROOT/snapshot.pins"
  fi
}
trap cleanup EXIT

if PATH="/usr/bin:/bin" command -v pixie-pkg >/dev/null 2>&1; then
  echo "pixie-pkg is already installed on /usr/bin or /bin" >&2
  exit 2
fi

write_tool_script() {
  local file=$1 marker=$2 kind=$3
  {
    echo '#!/bin/bash'
    printf 'marker=%q\n' "$marker"
    if [ "$kind" = good ]; then
      cat <<'EOF'
if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
  printf '%s\n' present > "$marker/install-token"
else
  printf '%s\n' absent > "$marker/install-token"
fi
printf '%s\n' good > "$marker/good-install"
prefix="${PREFIX:-/usr}"
mkdir -p "$prefix/bin"
cat > "$prefix/bin/pixie-pkg" <<'INNER'
#!/bin/bash
EOF
      printf 'marker=%q\n' "$marker"
      cat <<'EOF'
if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
  printf '%s\n' present > "$marker/fetch-token"
else
  printf '%s\n' absent > "$marker/fetch-token"
fi
printf '%s\n' good > "$marker/good-fetch"
prev=""
dest=""
for arg in "$@"; do
  if [ "$prev" = "--dest" ]; then
    dest=$arg
  fi
  prev=$arg
done
if [ -n "$dest" ]; then
  mkdir -p "$dest"
  printf '%s\n' pinned > "$dest/pinned-by-fetch"
fi
exit 0
INNER
chmod +x "$prefix/bin/pixie-pkg"
EOF
    else
      printf 'printf %%s\\\\n %s > "$marker/%s-install"\n' "$kind" "$kind"
      cat <<'EOF'
if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
  printf '%s\n' present > "$marker/install-token"
else
  printf '%s\n' absent > "$marker/install-token"
fi
prefix="${PREFIX:-/usr}"
mkdir -p "$prefix/bin"
cat > "$prefix/bin/pixie-pkg" <<'INNER'
#!/bin/bash
EOF
      printf 'marker=%q\n' "$marker"
      printf 'printf %%s\\\\n %s > "$marker/%s-fetch"\n' "$kind" "$kind"
      cat <<'EOF'
if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
  printf '%s\n' present > "$marker/fetch-token"
else
  printf '%s\n' absent > "$marker/fetch-token"
fi
prev=""
dest=""
for arg in "$@"; do
  if [ "$prev" = "--dest" ]; then
    dest=$arg
  fi
  prev=$arg
done
if [ -n "$dest" ]; then
  mkdir -p "$dest"
  printf '%s\n' poisoned > "$dest/POISONED"
fi
exit 0
INNER
chmod +x "$prefix/bin/pixie-pkg"
EOF
    fi
  } > "$file"
  chmod +x "$file"
}

# mode is bad-head (default branch is the unpinned commit) or good-head
# (default branch is the pin; the next upload-pack moves it).
prepare() {
  local mode=$1
  CASE="$(mktemp -d)"
  MARKER="$CASE/marker"
  mkdir -p "$MARKER"
  BARE="$CASE/bare.git"
  SRC="$CASE/src"
  HELPER="$CASE/helper"
  GITCFG="$CASE/gitconfig"
  ADVANCE="$CASE/advance-on"
  FLAG="$CASE/advanced"
  MOVED="$CASE/moved-install.sh"
  LOG="$CASE/helper.log"
  : > "$LOG"

  git init -b main "$SRC" >/dev/null
  git -C "$SRC" config user.email pixie-test@example.com
  git -C "$SRC" config user.name pixie-test
  mkdir -p "$SRC/scripts"
  write_tool_script "$SRC/scripts/install-local.sh" "$MARKER" good
  git -C "$SRC" add scripts/install-local.sh
  git -C "$SRC" commit -m good >/dev/null
  GOOD="$(git -C "$SRC" rev-parse HEAD)"
  write_tool_script "$SRC/scripts/install-local.sh" "$MARKER" bad
  git -C "$SRC" add scripts/install-local.sh
  git -C "$SRC" commit -m bad >/dev/null
  BAD="$(git -C "$SRC" rev-parse HEAD)"
  git init --bare -b main "$BARE" >/dev/null
  if [ "$mode" = good-head ]; then
    git -C "$SRC" push "$BARE" "$GOOD:refs/heads/main" >/dev/null
  else
    git -C "$SRC" push "$BARE" "$BAD:refs/heads/main" >/dev/null
  fi
  write_tool_script "$MOVED" "$MARKER" moved

  cat > "$HELPER" <<EOF
#!/bin/bash
set -u
bare=$(printf '%q' "$BARE")
flag=$(printf '%q' "$FLAG")
moved=$(printf '%q' "$MOVED")
advance=$(printf '%q' "$ADVANCE")
log=$(printf '%q' "$LOG")
printf 'call\n' >> "\$log"
set +e
/usr/bin/git --git-dir="\$bare" upload-pack "\$bare"
status=\$?
set -e
if [ -f "\$advance" ] && [ ! -f "\$flag" ]; then
  touch "\$flag"
  blob=\$(/usr/bin/git --git-dir="\$bare" hash-object -w --stdin < "\$moved")
  index=\$(mktemp)
  GIT_INDEX_FILE="\$index" /usr/bin/git --git-dir="\$bare" read-tree HEAD
  GIT_INDEX_FILE="\$index" /usr/bin/git --git-dir="\$bare" update-index --add --cacheinfo "100755,\$blob,scripts/install-local.sh"
  tree=\$(GIT_INDEX_FILE="\$index" /usr/bin/git --git-dir="\$bare" write-tree)
  rm -f "\$index"
  parent=\$(/usr/bin/git --git-dir="\$bare" rev-parse HEAD)
  new=\$(GIT_AUTHOR_NAME=pixie-test GIT_AUTHOR_EMAIL=pixie-test@example.com \
    GIT_COMMITTER_NAME=pixie-test GIT_COMMITTER_EMAIL=pixie-test@example.com \
    /usr/bin/git --git-dir="\$bare" commit-tree "\$tree" -p "\$parent" -m moved)
  /usr/bin/git --git-dir="\$bare" update-ref refs/heads/main "\$new"
fi
exit \$status
EOF
  chmod +x "$HELPER"

  cat > "$GITCFG" <<EOF
[protocol]
	allow = always
[protocol "ext"]
	allow = always
[url "ext::$HELPER"]
	insteadOf = https://github.com/roojs/pixie-pkg.git
EOF

  rm -rf "$ROOT/.cache/pixie-pkg"
  if [ "$mode" = missing-pin ]; then
    rm -f "$ROOT/scripts/pixie-pkg.pin"
  elif [ "$mode" = branch-name ]; then
    printf '%s\n' main > "$ROOT/scripts/pixie-pkg.pin"
  else
    printf '%s\n' "$GOOD" > "$ROOT/scripts/pixie-pkg.pin"
  fi
  if [ "$mode" = good-head ]; then
    : > "$ADVANCE"
  else
    rm -f "$ADVANCE"
  fi
}

run_env() {
  (
    set -euo pipefail
    export PATH="/usr/bin:/bin"
    export GH_TOKEN=placeholder-not-a-real-token
    export GITHUB_TOKEN=placeholder-not-a-real-token
    export GIT_CONFIG_GLOBAL="$GITCFG"
    export GIT_CONFIG_SYSTEM=/dev/null
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_TERMINAL_PROMPT=0
    "$@"
  )
}

direct_fetch() {
  local dest=$1
  mkdir -p "$dest"
  printf '{}\n' > "$dest/pins.json"
  run_env bash -c '
    set -euo pipefail
    root=$1
    dest=$2
    # shellcheck source=/dev/null
    source "$root/scripts/require-pixie.sh"
    require_pixie
    pixie-pkg fetch --dest "$dest" --pins "$dest/pins.json" --abi arm64-v8a
  ' bash "$ROOT" "$dest"
}

expect_pinned() {
  local label=$1
  if [ -e "$MARKER/bad-install" ]; then
    note "$label: install-local.sh from the unpinned default branch ran"
  fi
  if [ -e "$MARKER/bad-fetch" ]; then
    note "$label: pixie-pkg from the unpinned default branch ran"
  fi
  if [ -e "$MARKER/moved-install" ]; then
    note "$label: install-local.sh from a later default-branch lookup ran"
  fi
  if [ -e "$MARKER/moved-fetch" ]; then
    note "$label: pixie-pkg from a later default-branch lookup ran"
  fi
  if [ -e "$MARKER/poison-fetch" ]; then
    note "$label: a cached pixie-pkg ran without matching the pin"
  fi
  if [ ! -f "$MARKER/good-install" ]; then
    note "$label: install-local.sh from the pinned commit did not run"
  fi
  if [ ! -f "$MARKER/good-fetch" ]; then
    note "$label: pixie-pkg from the pinned commit did not run fetch"
  fi
  if [ -f "$MARKER/install-token" ] && [ "$(cat "$MARKER/install-token")" != absent ]; then
    note "$label: install-local.sh saw GH_TOKEN or GITHUB_TOKEN"
  fi
  if [ -f "$MARKER/fetch-token" ] && [ "$(cat "$MARKER/fetch-token")" != absent ]; then
    note "$label: pixie-pkg saw GH_TOKEN or GITHUB_TOKEN"
  fi
  local got blob pinned_blob
  got="$(git -C "$ROOT/.cache/pixie-pkg/src" rev-parse HEAD 2>/dev/null || true)"
  if [ "$got" != "$GOOD" ]; then
    note "$label: .cache/pixie-pkg/src is not the pinned commit"
  fi
  pinned_blob="$(git --git-dir="$BARE" rev-parse "$GOOD:scripts/install-local.sh" 2>/dev/null || true)"
  blob="$(git -C "$ROOT/.cache/pixie-pkg/src" hash-object scripts/install-local.sh 2>/dev/null || true)"
  if [ -z "$pinned_blob" ] || [ "$blob" != "$pinned_blob" ]; then
    note "$label: scripts/install-local.sh is not the blob from the pinned commit"
  fi
}

expect_refused() {
  local label=$1
  if [ -e "$MARKER/bad-install" ] || [ -e "$MARKER/bad-fetch" ] \
    || [ -e "$MARKER/moved-install" ] || [ -e "$MARKER/moved-fetch" ] \
    || [ -e "$MARKER/good-install" ] || [ -e "$MARKER/poison-fetch" ]; then
    note "$label: code from the clone ran before the pin was accepted"
  fi
}

run_direct_case() {
  local label=$1 mode=$2
  local err dest status
  prepare "$mode"
  dest="$CASE/fetch-dest"
  err="$CASE/stderr"
  set +e
  direct_fetch "$dest" >"$CASE/stdout" 2>"$err"
  status=$?
  set -e
  if [ "$mode" = missing-pin ] || [ "$mode" = branch-name ]; then
    expect_refused "$label"
    if [ "$status" -eq 0 ]; then
      note "$label: require_pixie succeeded without a commit pin"
    fi
  else
    if [ "$status" -ne 0 ]; then
      note "$label: require_pixie exited $status"
      tail -n 20 "$err" >&2 || true
    fi
    expect_pinned "$label"
  fi
}

# The default branch is a commit after the pin. Depth-1 clone of that branch
# does not contain the pin, and its install-local.sh must not run.
run_direct_case "unpinned default branch" bad-head

# The first git connection sees the pin. The default branch then moves.
# A second lookup of the branch must not be what install-local.sh comes from.
run_direct_case "default branch moves between lookups" good-head

# An already-installed binary is not a substitute for the pin.
prepare bad-head
mkdir -p "$ROOT/.cache/pixie-pkg/bin"
{
  echo '#!/bin/bash'
  printf 'marker=%q\n' "$MARKER"
  echo 'printf %s\\n poison > "$marker/poison-fetch"'
  echo 'exit 0'
} > "$ROOT/.cache/pixie-pkg/bin/pixie-pkg"
chmod +x "$ROOT/.cache/pixie-pkg/bin/pixie-pkg"
dest="$CASE/fetch-dest"
err="$CASE/stderr"
set +e
direct_fetch "$dest" >"$CASE/stdout" 2>"$err"
status=$?
set -e
if [ "$status" -ne 0 ]; then
  note "cached binary: require_pixie exited $status"
  tail -n 20 "$err" >&2 || true
fi
expect_pinned "cached binary"

# No object id: do not run the default branch.
run_direct_case "missing pin" missing-pin
run_direct_case "branch name is not a pin" branch-name

# Monitor Upstreams builds through build-changed.sh with the job token set.
prepare bad-head
plan="$CASE/plan.tsv"
{
  echo '# gtk_target=gnome'
  while IFS= read -r name || [ -n "$name" ]; do
    name=${name%%#*}
    name=${name#"${name%%[![:space:]]*}"}
    name=${name%"${name##*[![:space:]]}"}
    [ -n "$name" ] || continue
    if [ "$name" = libxml2 ]; then
      printf 'build\tlibxml2\tfile\tlibxml2.tar.xz\thash\tinputs\t-\n'
    else
      printf 'keep\t%s\tfile\t%s\thash\tinputs\t-\n' "$name" "$name"
    fi
  done < "$ROOT/build-order.txt"
} > "$plan"
builder="$CASE/build-pixie"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$builder"
chmod +x "$builder"
err="$CASE/stderr"
set +e
(
  set -euo pipefail
  export PATH="/usr/bin:/bin"
  export GH_TOKEN=placeholder-not-a-real-token
  export GITHUB_TOKEN=placeholder-not-a-real-token
  export GIT_CONFIG_GLOBAL="$GITCFG"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_TERMINAL_PROMPT=0
  export BUILD_PIXIE="$builder"
  "$ROOT/scripts/build-changed.sh" \
    --skip-missing-check \
    --plan "$plan" \
    --arch aarch64 \
    --gtk gnome \
    --tarball-dir "$CASE/tarballs"
) >"$CASE/stdout" 2>"$err"
status=$?
set -e
if [ "$status" -ne 0 ]; then
  note "build-changed: exited $status"
  tail -n 30 "$err" >&2 || true
fi
expect_pinned "build-changed"

# Prove Package resolves upstreams, reuses a cached openssl tarball, publishes
# with the job token, then fetches the dependency sysroot.
prepare bad-head
if [ -z "$backup" ]; then
  backup="$(mktemp)"
  cp -a "$ROOT/release.pins" "$backup"
fi
if [ -f "$ROOT/snapshot.pins" ]; then
  had_snap=1
  snap_backup="$(mktemp)"
  cp -a "$ROOT/snapshot.pins" "$snap_backup"
fi
ghdir="$CASE/bin"
mkdir -p "$ghdir"
cat > "$ghdir/gh" <<EOF
#!/bin/bash
marker=$(printf '%q' "$MARKER")
if [ -n "\${GH_TOKEN:-}" ] || [ -n "\${GITHUB_TOKEN:-}" ]; then
  printf '%s\n' present > "\$marker/gh-token"
else
  printf '%s\n' absent > "\$marker/gh-token"
fi
exit 0
EOF
chmod +x "$ghdir/gh"
err="$CASE/stderr"
set +e
(
  set -euo pipefail
  export PATH="$ghdir:/usr/bin:/bin"
  export GH_TOKEN=placeholder-not-a-real-token
  export GITHUB_TOKEN=placeholder-not-a-real-token
  export GIT_CONFIG_GLOBAL="$GITCFG"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_TERMINAL_PROMPT=0
  export PROVE_PUBLISH=1
  export PROVE_CREATED=2026-11-25T00:00:00Z
  resolved="$CASE/resolved.tsv"
  "$ROOT/scripts/upstream-index.sh" resolve --gtk gnome --out "$resolved"
  inputs="$(awk -F '\t' '$1 == "openssl" { print $5; exit }' "$resolved")"
  [ -n "$inputs" ]
  abi=arm64-v8a
  cache="$CASE/cache/$abi"
  stage="$CASE/openssl-stage"
  mkdir -p "$cache" "$stage/lib/$abi/pkgconfig"
  printf '%s\n' 'prefix=/usr' 'Name: openssl' 'Version: 3.0.8' \
    > "$stage/lib/$abi/pkgconfig/openssl.pc"
  printf '%s\n' stub > "$stage/lib/$abi/libssl.so"
  printf '%s\n' stub > "$stage/lib/$abi/libcrypto.so"
  tar -C "$stage" -cJf "$cache/openssl.tar.xz" lib
  printf '%s\n' "$inputs" > "$cache/openssl.inputs"
  "$ROOT/scripts/prove-package.sh" \
    --arch aarch64 \
    --gtk gnome \
    --packages openssl \
    --pins /dev/null \
    --cache "$CASE/cache" \
    --out "$CASE/prove-out"
) >"$CASE/stdout" 2>"$err"
status=$?
set -e
if [ -f "$backup" ]; then
  cp -a "$backup" "$ROOT/release.pins"
fi
if [ "$had_snap" -eq 1 ]; then
  cp -a "$snap_backup" "$ROOT/snapshot.pins"
fi
if [ "$status" -ne 0 ]; then
  note "prove-package: exited $status"
  tail -n 40 "$err" >&2 || true
fi
expect_pinned "prove-package"
if [ ! -f "$MARKER/gh-token" ] || [ "$(cat "$MARKER/gh-token")" != present ]; then
  note "prove-package: publish did not see GH_TOKEN"
fi

cleanup
trap - EXIT

if [ "$fail" -ne 0 ]; then
  echo "pixie-pkg pin checks failed" >&2
  exit 1
fi
echo "pixie-pkg pin checks passed"
