#!/usr/bin/env bash
# The changelog is the version. release.sh tags only after that version is committed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export CHANGELOG_MD="$tmp/CHANGELOG.md"

cat > "$CHANGELOG_MD" <<'EOF'
# Changelog

## [Unreleased]
EOF
if "$ROOT/scripts/release/changelog.sh" version >"$tmp/out" 2>"$tmp/err"; then
  echo "bare Unreleased should be refused" >&2
  exit 1
fi
grep -q 'set the version' "$tmp/err"

cat > "$CHANGELOG_MD" <<'EOF'
# Changelog

## [1.2.3] - 2026-11-09

- Already shipped.
EOF
if "$ROOT/scripts/release/changelog.sh" version >"$tmp/out" 2>"$tmp/err"; then
  echo "a dated heading should be refused" >&2
  exit 1
fi
grep -q 'already dated' "$tmp/err"

cat > "$CHANGELOG_MD" <<'EOF'
# Changelog

## [1.2.3] - Unreleased

- Publish the libraries from a version tag.
EOF
[ "$("$ROOT/scripts/release/changelog.sh" version)" = 1.2.3 ]
notes="$("$ROOT/scripts/release/changelog.sh" notes)"
grep -q 'Publish the libraries' <<<"$notes"

"$ROOT/scripts/release/changelog.sh" finalize v1.2.3 >"$tmp/out"
grep -q '^## \[Unreleased\]$' "$CHANGELOG_MD"
grep -q '^## \[1.2.3\] - ' "$CHANGELOG_MD"
if "$ROOT/scripts/release/changelog.sh" version >"$tmp/out" 2>"$tmp/err"; then
  echo "finalized changelog should wait for the next version" >&2
  exit 1
fi

if CURSOR_AGENT=1 "$ROOT/scripts/release.sh" --help >"$tmp/out" 2>"$tmp/err"; then
  echo "an agent must not run release.sh" >&2
  exit 1
fi
grep -q 'agents are banned' "$tmp/err"

unset CHANGELOG_MD

bare="$tmp/origin.git"
work="$tmp/work"
git init --bare -q "$bare"
git init -q -b main "$work"
git -C "$work" config user.email "test@example.com"
git -C "$work" config user.name "Test"
mkdir -p "$work/scripts/release"
cp "$ROOT/scripts/release.sh" "$work/scripts/release.sh"
cp "$ROOT/scripts/release/changelog.sh" "$work/scripts/release/changelog.sh"
chmod +x "$work/scripts/release.sh" "$work/scripts/release/changelog.sh"
cat > "$work/CHANGELOG.md" <<'EOF'
# Changelog

## [1.2.3] - Unreleased

- Publish the libraries from a version tag.
EOF
git -C "$work" add CHANGELOG.md scripts
git -C "$work" commit -m "Prepare 1.2.3" >/dev/null
git -C "$work" remote add origin "$bare"
git -C "$work" push -q -u origin main

echo "dirty" >> "$work/CHANGELOG.md"
if env -u CURSOR_AGENT "$work/scripts/release.sh" >"$tmp/out" 2>"$tmp/err"; then
  echo "a dirty tree must be refused" >&2
  exit 1
fi
grep -q 'not clean' "$tmp/err"
git -C "$work" checkout -- CHANGELOG.md

env -u CURSOR_AGENT "$work/scripts/release.sh" >"$tmp/out" 2>"$tmp/err"
grep -q 'Released v1.2.3' "$tmp/out"
git -C "$bare" rev-parse -q --verify refs/tags/v1.2.3 >/dev/null
git --git-dir="$bare" ls-remote --tags . refs/tags/v1.2.3 >/dev/null

env -u CURSOR_AGENT "$work/scripts/release.sh" >"$tmp/out" 2>"$tmp/err"
grep -q 'already exists' "$tmp/out"

echo "release: ok"
