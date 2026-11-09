#!/usr/bin/env bash
# Verify the tree is ready, then tag and push. That is all.
#
# 1. Read latest ## [X.Y.Z] - Unreleased from CHANGELOG.md
# 2. Exit if tag vX.Y.Z already exists (local or origin)
#    unless --retry: delete that tag locally and on origin, then continue
# 3. Verify: clean tree on main, non-empty notes
# 4. git tag -a + git push (main + tag) → GitHub Actions builds the libraries
#
# AGENTS ARE BANNED from running this script. Do not tag, push, or release
# on the user's behalf. Do not unset CURSOR_AGENT, spoof the environment,
# invoke git tag/push directly, or otherwise work around this guard.
# Only the human runs scripts/release.sh in a normal terminal.
set -euo pipefail

if [[ "${CURSOR_AGENT:-}" == "1" ]]; then
  cat >&2 <<'EOF'
error: agents are banned from running scripts/release.sh.

Do not work around this (unset CURSOR_AGENT, fake the env, call git tag/push
yourself, etc.). The human must run scripts/release.sh in a normal terminal.
EOF
  exit 1
fi

retry=0
for arg in "$@"; do
  case "${arg}" in
    --retry)
      retry=1
      ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/release.sh [--retry]

Create an annotated tag from CHANGELOG.md and push it to origin.

  --retry   Delete the existing version tag locally and on origin, then
            retag HEAD and push (use after a failed release CI run).
EOF
      exit 0
      ;;
    *)
      echo "error: unknown option: ${arg}" >&2
      echo "Usage: scripts/release.sh [--retry]" >&2
      exit 1
      ;;
  esac
done

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "${root}"

chmod +x scripts/release/changelog.sh
ver="$(scripts/release/changelog.sh version)"
tag="v${ver}"
notes="$(scripts/release/changelog.sh notes)"

echo "CHANGELOG.md latest: ${ver}"
echo "Tag: ${tag}"
echo "---- notes ----"
echo "${notes}"
echo "---------------"

if [[ -z "${notes//[[:space:]]/}" ]]; then
  echo "error: empty notes for ${ver} — fill CHANGELOG.md first" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree not clean — commit or stash before releasing" >&2
  git status --short >&2
  exit 1
fi

branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$branch" != main ]]; then
  echo "error: release from main (current branch is ${branch})" >&2
  exit 1
fi

git fetch --tags origin

if [[ "${retry}" -eq 1 ]]; then
  if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
    echo "Deleting local tag ${tag}..."
    git tag -d "${tag}"
  fi
  if git ls-remote --exit-code --tags origin "refs/tags/${tag}" >/dev/null 2>&1; then
    echo "Deleting origin tag ${tag}..."
    git push origin --delete "refs/tags/${tag}"
  fi
fi

if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
  echo "Tag ${tag} already exists locally — nothing to do."
  echo "Re-run with --retry to delete it and retag HEAD." >&2
  exit 0
fi

if git ls-remote --exit-code --tags origin "refs/tags/${tag}" >/dev/null 2>&1; then
  echo "Tag ${tag} already exists on origin — nothing to do."
  echo "Re-run with --retry to delete it and retag HEAD." >&2
  exit 0
fi

echo "Creating annotated tag ${tag}..."
git tag -a "${tag}" -m "${tag}"

echo "Pushing main and ${tag} to origin..."
git push origin main
git push origin "${tag}"

echo "Released ${tag}. GitHub will build the libraries."
