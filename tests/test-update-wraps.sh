#!/usr/bin/env bash
# A version in a wrap moves to the newest release on that line.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/update-wraps.sh
source "$ROOT/scripts/update-wraps.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

list="$tmp/tags"
cat > "$list" << 'EOF'
1.56.0
1.58.1
1.58.3
1.58.4-rc1
1.60.0
2.0.0
v1.58.5
EOF
[ "$(pick_release 1.58.2 1 "$list")" = "1.60.0" ]
printf '1.90.0\n' >> "$list"
[ "$(pick_release 1.58.2 1 "$list")" = "1.60.0" ]
[ -z "$(pick_release 1.58.2 1 <(printf '%s\n' 1.90.0))" ]
[ "$(pick_release 1.58.2 2 "$list")" = "v1.58.5" ]
[ -z "$(pick_release 1.60.0 1 "$list")" ]

cat > "$list" << 'EOF'
0.21.4
0.21.9
0.23.0
EOF
[ "$(pick_release 0.21.5 1 "$list")" = "0.21.9" ]

cat > "$list" << 'EOF'
v1.0.17
1.0.18
v1.0.18
EOF
[ "$(pick_release v1.0.16 2 "$list")" = "v1.0.18" ]

if ! revision_is_fixed main || ! revision_is_fixed ae709f962a51f9108a1e6381bcfbd05bbaecc840; then
  echo "a branch or a commit would be moved" >&2
  exit 1
fi
if revision_is_fixed 1.58.2; then
  echo "a version was treated as fixed" >&2
  exit 1
fi

remote="$tmp/upstream"
mkdir -p "$remote"
git -C "$remote" init -q
git -C "$remote" config user.email "test@example.com"
git -C "$remote" config user.name "test"
GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' \
  git -C "$remote" commit -q --allow-empty -m start
git -C "$remote" tag 1.2.3
GIT_AUTHOR_DATE='2024-01-01T00:00:00Z' GIT_COMMITTER_DATE='2024-01-01T00:00:00Z' \
  git -C "$remote" commit -q --allow-empty -m next
git -C "$remote" tag 1.2.4
git -C "$remote" tag 1.3.0
git -C "$remote" tag 2.0.0
git -C "$remote" tag 1.3.1-rc1

pkg="$tmp/packages/demo"
mkdir -p "$pkg"
cat > "$pkg/demo.wrap" << EOF
[wrap-git]
directory = demo
url = $remote
revision = 1.2.3
EOF
update_wrap "$pkg/demo.wrap"
grep -q '^revision = 1.3.0$' "$pkg/demo.wrap"

oldrev="$tmp/old-upstream"
mkdir -p "$oldrev"
git -C "$oldrev" init -q
git -C "$oldrev" config user.email "test@example.com"
git -C "$oldrev" config user.name "test"
GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' \
  git -C "$oldrev" commit -q --allow-empty -m old
git -C "$oldrev" tag 1.2.0
git -C "$oldrev" tag 1.9.0
GIT_AUTHOR_DATE='2024-01-01T00:00:00Z' GIT_COMMITTER_DATE='2024-01-01T00:00:00Z' \
  git -C "$oldrev" commit -q --allow-empty -m new
git -C "$oldrev" tag 1.3.0
cat > "$pkg/dated.wrap" << EOF
[wrap-git]
directory = demo
url = $oldrev
revision = 1.2.0
EOF
update_wrap "$pkg/dated.wrap"
grep -q '^revision = 1.3.0$' "$pkg/dated.wrap"

cat > "$pkg/fixed.wrap" << EOF
[wrap-git]
directory = demo
url = $remote
revision = main
EOF
update_wrap "$pkg/fixed.wrap"
grep -q '^revision = main$' "$pkg/fixed.wrap"

echo "update wraps: ok"
