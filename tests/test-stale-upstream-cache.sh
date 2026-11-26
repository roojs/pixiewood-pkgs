#!/usr/bin/env bash
# A branch tip moves without a recipe change. The package that is cached,
# uploaded, and pinned must be the package built from the resolved commit.
#
# Contract, once the stale-cache bug is fixed:
# - build-changed.sh reuses .cache/<abi>/<name>.tar.xz only when the stored
#   identity is this plan row's resolved revision and its inputs hash. A
#   stamp that is only the inputs hash is not that identity. After a git
#   build it records the resolved commit in the tarball at
#   share/pixiewood/upstream-revision (tar member ./share/pixiewood/upstream-revision
#   is fine) before it saves the cache copy.
# - obtain-package.sh returns cache only for that same identity. When
#   --resolved is set, an inputs-only stamp is a miss. When --resolved is
#   omitted, a stamp that is exactly the inputs hash is still a hit.
# - publish-package.sh, for track main|master|HEAD|head|trunk and a 40-hex
#   --resolved, reads that member and refuses unless it equals --resolved.
#   A refusal does not change or create the pin file, does not change the
#   tarball, and does not run gh. A numbered file release still publishes
#   without that member.
# - publish-index.sh applies the same refusal before it writes an index or
#   uploads. The monitor workflow uploads through this script, then pins
#   through publish-package.sh.
# - prove-package.sh does not take an inputs-only cache entry for a different
#   resolved commit. A build passes --resolved through to build-pixie.sh and
#   stores an identity obtain-package.sh accepts for that commit and rejects
#   for another. With PROVE_PUBLISH=1 the pin's resolved commit is the commit
#   recorded in the tarball that was published.
#
# Not executed here: actions/cache itself (the test puts the restored files
# where monitor-upstreams.yml passes --cache), and checkout-cache.sh. The
# prove stand-in for build-pixie.sh only records --resolved and writes a
# package tarball; it does not clone or compile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
cp "$ROOT/snapshot.pins" "$tmp/snapshot.pins.orig"
cleanup() {
  if [ -f "$tmp/snapshot.pins.orig" ]; then
    cp "$tmp/snapshot.pins.orig" "$ROOT/snapshot.pins"
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

die() {
  echo "$*" >&2
  exit 1
}

bash -n "$ROOT/scripts/build-changed.sh"
bash -n "$ROOT/scripts/obtain-package.sh"
bash -n "$ROOT/scripts/publish-package.sh"
bash -n "$ROOT/scripts/publish-index.sh"
bash -n "$ROOT/scripts/prove-package.sh"
bash -n "$ROOT/scripts/upstream-index.sh"

grep -q '^\[wrap-git\]' "$ROOT/packages/fontconfig/fontconfig.wrap"
grep -q '^revision = main$' "$ROOT/packages/fontconfig/fontconfig.wrap"

OLD=1111111111111111111111111111111111111111
NEW=2222222222222222222222222222222222222222
OTHER=3333333333333333333333333333333333333333
ABI=arm64-v8a

bin="$tmp/bin"
mkdir -p "$bin"
cat > "$bin/git" << 'EOF'
#!/bin/bash
if [ "$1" = ls-remote ]; then
  shift 2
  [ -n "${GIT_LS_REMOTE_SHA:-}" ]
  for ref in "$@"; do
    printf '%s\t%s\n' "$GIT_LS_REMOTE_SHA" "$ref"
  done
  exit 0
fi
exec /usr/bin/git "$@"
EOF
cat > "$bin/gh" << 'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${GH_LOG:?}"
exit 0
EOF
# prove runs in a user namespace where this account is root. pixie-pkg then
# tries to create /var/cache/pixie. Report the invoking user so fetch uses
# the home cache. ls-remote and gh stay the wrappers above.
cat > "$bin/id" << 'EOF'
#!/bin/bash
if [ "${1:-}" = -u ]; then
  printf '%s\n' "${PROVE_UID:?}"
  exit 0
fi
exec /usr/bin/id "$@"
EOF
chmod +x "$bin/git" "$bin/gh" "$bin/id"

resolve_at() {
  local sha=$1 out=$2
  PATH="$bin:$PATH" GIT_LS_REMOTE_SHA="$sha" \
    "$ROOT/scripts/upstream-index.sh" resolve --gtk gnome --out "$out"
}

resolve_at "$OLD" "$tmp/resolved-old.tsv"
resolve_at "$NEW" "$tmp/resolved-new.tsv"

fc_inputs="$(awk -F '\t' '$1 == "fontconfig" { print $5 }' "$tmp/resolved-old.tsv")"
fc_inputs_new="$(awk -F '\t' '$1 == "fontconfig" { print $5 }' "$tmp/resolved-new.tsv")"
fc_track="$(awk -F '\t' '$1 == "fontconfig" { print $3 }' "$tmp/resolved-new.tsv")"
fc_kind="$(awk -F '\t' '$1 == "fontconfig" { print $2 }' "$tmp/resolved-new.tsv")"
[ -n "$fc_inputs" ] || die "fontconfig inputs were empty"
[ "$fc_inputs" = "$fc_inputs_new" ] || die "fontconfig inputs changed when only the upstream commit changed"
[ "$fc_track" = main ] || die "fontconfig track is $fc_track"
[ "$fc_kind" = git ] || die "fontconfig kind is $fc_kind"
awk -F '\t' -v old="$OLD" '$1 == "fontconfig" && $4 == old { found = 1 } END { exit !found }' "$tmp/resolved-old.tsv"
awk -F '\t' -v new="$NEW" '$1 == "fontconfig" && $4 == new { found = 1 } END { exit !found }' "$tmp/resolved-new.tsv"

awk -F '\t' '{ printf "%s\t%s\t%s\t%s\thttps://example.invalid/old/%s.pixie\n", $1, $3, $4, $5, $1 }' \
  "$tmp/resolved-old.tsv" > "$tmp/previous.list"
"$ROOT/scripts/upstream-index.sh" write \
  --list "$tmp/previous.list" \
  --abi "$ABI" --arch aarch64 --gtk gnome --created 2026-11-01T00:00:00Z \
  --out "$tmp/previous.json"
"$ROOT/scripts/upstream-index.sh" plan \
  --resolved "$tmp/resolved-new.tsv" \
  --previous "$tmp/previous.json" \
  --gtk gnome --abi "$ABI" \
  --out "$tmp/full-plan.tsv"
awk -F '\t' -v new="$NEW" -v inputs="$fc_inputs" '
  $2 == "fontconfig" && $1 == "build" && $3 == "git" && $4 == "main" && $5 == new && $6 == inputs { found = 1 }
  END { exit !found }
' "$tmp/full-plan.tsv" || die "plan did not mark fontconfig build for the new commit"

# Gnome is the base target, so apply copies the plan and keeps the resolved commit.
{
  printf '%s\n' '# publish=1' '# build=1' '# gtk_target=gnome'
  while IFS= read -r name || [ -n "$name" ]; do
    name=${name%%#*}
    name=${name#"${name%%[![:space:]]*}"}
    name=${name%"${name##*[![:space:]]}"}
    [ -n "$name" ] || continue
    if [ "$name" = fontconfig ]; then
      printf 'build\tfontconfig\tgit\tmain\t%s\t%s\t-\n' "$NEW" "$fc_inputs"
    else
      # Not "keep": a kept row would be fetched before fontconfig is built.
      printf 'aside\t%s\tfile\t%s\thash\tinputs\t-\n' "$name" "$name"
    fi
  done < "$ROOT/build-order.txt"
} > "$tmp/focus-plan.tsv"
"$ROOT/scripts/current-pins.sh" apply \
  --plan "$tmp/focus-plan.tsv" --arch aarch64 --out "$tmp/applied-plan.tsv"
awk -F '\t' -v new="$NEW" -v inputs="$fc_inputs" '
  $2 == "fontconfig" && $1 == "build" && $5 == new && $6 == inputs { found = 1 }
  END { exit !found }
' "$tmp/applied-plan.tsv" || die "apply dropped fontconfig's resolved commit"

make_fontconfig_tarball() {
  local dest=$1 so_text=$2 revision=${3:-} dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/lib/$ABI/pkgconfig" "$dir/lib/$ABI"
  printf '%s\n' 'prefix=/' 'Name: fontconfig' 'Version: 9.9.9' > "$dir/lib/$ABI/pkgconfig/fontconfig.pc"
  printf '%s\n' "$so_text" > "$dir/lib/$ABI/libfontconfig.so"
  if [ -n "$revision" ]; then
    mkdir -p "$dir/share/pixiewood"
    printf '%s\n' "$revision" > "$dir/share/pixiewood/upstream-revision"
  fi
  tar -C "$dir" -cJf "$dest" .
  rm -rf "$dir"
}

tarball_revision() {
  local tarball=$1 member
  member="$(tar -tJf "$tarball" | grep -E '(^|/)share/pixiewood/upstream-revision$' | head -n1 || true)"
  [ -n "$member" ] || return 1
  tar -xJf "$tarball" -O "$member" | tr -d '[:space:]'
}

tarball_so() {
  local tarball=$1 member
  member="$(tar -tJf "$tarball" | grep -E '(^|/)lib/'"$ABI"'/libfontconfig\.so$' | head -n1 || true)"
  [ -n "$member" ] || return 1
  tar -xJf "$tarball" -O "$member" | tr -d '\n'
}

# The builder does not record the commit. build-changed.sh has to.
cat > "$tmp/build-pixie.sh" << 'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "${BUILD_LOG:?}"
tarball=""
resolved=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tarball) tarball=$2; shift 2 ;;
    --resolved) resolved=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$tarball" ]
dir="$(mktemp -d)"
mkdir -p "$dir/lib/arm64-v8a/pkgconfig" "$dir/lib/arm64-v8a"
printf '%s\n' 'prefix=/' 'Name: fontconfig' 'Version: 9.9.9' > "$dir/lib/arm64-v8a/pkgconfig/fontconfig.pc"
printf 'built-for-%s\n' "$resolved" > "$dir/lib/arm64-v8a/libfontconfig.so"
tar -C "$dir" -cJf "$tarball" .
rm -rf "$dir"
EOF
chmod +x "$tmp/build-pixie.sh"

cache="$tmp/cache"
mkdir -p "$cache/$ABI"
make_fontconfig_tarball "$cache/$ABI/fontconfig.tar.xz" stale-binary
printf '%s\n' "$fc_inputs" > "$cache/$ABI/fontconfig.inputs"
stale_bytes="$(cksum "$cache/$ABI/fontconfig.tar.xz")"

# Full plan from resolve: the inputs-only cache must not satisfy the new commit.
BUILD_LOG="$tmp/unused-build.log" BUILD_PIXIE="$tmp/build-pixie.sh" \
  "$ROOT/scripts/build-changed.sh" \
  --plan "$tmp/full-plan.tsv" \
  --arch aarch64 --gtk gnome \
  --cache "$cache" \
  --tarball-dir "$tmp/dry-out" \
  --dry-run > "$tmp/dry-before.txt"
if grep -qx 'cache fontconfig' "$tmp/dry-before.txt"; then
  die "build-changed reused an inputs-only cache for a new fontconfig commit"
fi
grep -qx 'build fontconfig' "$tmp/dry-before.txt" || die "fontconfig was not rebuilt for the new commit"

# Publishing a branch pin must describe the commit inside the tarball.
jq -n --arg url "https://gitlab.gnome.org/GNOME/gtk.git" '{packages: [
  {abi:"arm64-v8a", repo:$url, name:"glib", track:"gtrack", resolved:"gres", inputs:"gin", url:"https://example.invalid/glib.tar.xz"}
]}' > "$tmp/pins"
cp "$tmp/pins" "$tmp/pins.before"
make_fontconfig_tarball "$tmp/marked-old.tar.xz" stale-binary "$OLD"
make_fontconfig_tarball "$tmp/marked-new.tar.xz" built-for-"$NEW" "$NEW"
make_fontconfig_tarball "$tmp/unmarked.tar.xz" unmarked
cp "$tmp/marked-old.tar.xz" "$tmp/marked-old.copy"
: > "$tmp/gh.log"
if GH_LOG="$tmp/gh.log" PATH="$bin:$PATH" \
  "$ROOT/scripts/publish-package.sh" \
  --name fontconfig \
  --tarball "$tmp/marked-old.tar.xz" \
  --arch aarch64 --gtk gnome \
  --track main --resolved "$NEW" --inputs "$fc_inputs" \
  --created 2026-11-08T01:02:03Z \
  --repo roojs/pixiewood-pkgs \
  --file "$tmp/pins" > "$tmp/publish-mismatch.out" 2> "$tmp/publish-mismatch.err"; then
  die "publish-package recorded $NEW for a tarball built from $OLD"
fi
cmp -s "$tmp/pins.before" "$tmp/pins" || die "publish-package changed pins while refusing"
cmp -s "$tmp/marked-old.tar.xz" "$tmp/marked-old.copy" || die "publish-package changed the tarball while refusing"
[ ! -s "$tmp/gh.log" ] || die "publish-package ran gh while refusing"

rm -f "$tmp/absent.pins"
if GH_LOG="$tmp/gh.log" PATH="$bin:$PATH" \
  "$ROOT/scripts/publish-package.sh" \
  --name fontconfig \
  --tarball "$tmp/unmarked.tar.xz" \
  --arch aarch64 --gtk gnome \
  --track main --resolved "$NEW" --inputs "$fc_inputs" \
  --created 2026-11-08T01:02:03Z \
  --file "$tmp/absent.pins" > "$tmp/publish-unmarked.out" 2> "$tmp/publish-unmarked.err"; then
  die "publish-package recorded a branch commit with no revision in the tarball"
fi
[ ! -e "$tmp/absent.pins" ] || die "publish-package created a pin file while refusing"
[ ! -s "$tmp/gh.log" ] || die "publish-package ran gh for an unmarked tarball"

for branch in master HEAD head trunk; do
  cp "$tmp/pins.before" "$tmp/pins"
  if GH_LOG="$tmp/gh.log" PATH="$bin:$PATH" \
    "$ROOT/scripts/publish-package.sh" \
    --name fontconfig \
    --tarball "$tmp/unmarked.tar.xz" \
    --arch aarch64 --gtk gnome \
    --track "$branch" --resolved "$NEW" --inputs "$fc_inputs" \
    --created 2026-11-08T01:02:03Z \
    --file "$tmp/pins" > "$tmp/publish-$branch.out" 2> "$tmp/publish-$branch.err"; then
    die "publish-package recorded $branch without the built commit"
  fi
  cmp -s "$tmp/pins.before" "$tmp/pins" || die "publish-package changed pins for $branch"
done

# A file release has no upstream commit member. That publish stays valid.
GH_LOG="$tmp/gh-file.log" PATH="$bin:$PATH" \
  "$ROOT/scripts/publish-package.sh" \
  --name openssl \
  --tarball "$tmp/unmarked.tar.xz" \
  --arch aarch64 --gtk gnome \
  --track openssl-3.0.8.tar.gz --resolved hash-o --inputs "$fc_inputs" \
  --created 2026-11-08T01:02:03Z \
  --repo roojs/pixiewood-pkgs \
  --file "$tmp/pins" \
  --no-upload > "$tmp/publish-file.out"
jq -e --arg inputs "$fc_inputs" '.packages[] | select(.name == "openssl" and .resolved == "hash-o" and .inputs == $inputs)' "$tmp/pins" >/dev/null
jq -e '.packages[] | select(.name == "glib" and .resolved == "gres")' "$tmp/pins" >/dev/null

cp "$tmp/pins.before" "$tmp/pins"
cp "$tmp/marked-new.tar.xz" "$tmp/marked-new.copy"
: > "$tmp/gh-match.log"
GH_LOG="$tmp/gh-match.log" PATH="$bin:$PATH" \
  "$ROOT/scripts/publish-package.sh" \
  --name fontconfig \
  --tarball "$tmp/marked-new.tar.xz" \
  --arch aarch64 --gtk gnome \
  --track main --resolved "$NEW" --inputs "$fc_inputs" \
  --created 2026-11-08T01:02:03Z \
  --repo roojs/pixiewood-pkgs \
  --file "$tmp/pins" > "$tmp/publish-match.out"
cmp -s "$tmp/marked-new.tar.xz" "$tmp/marked-new.copy" || die "publish-package rewrote a tarball it accepted"
jq -e --arg new "$NEW" --arg inputs "$fc_inputs" \
  '.packages[] | select(.name == "fontconfig" and .resolved == $new and .inputs == $inputs and .track == "main")' \
  "$tmp/pins" >/dev/null
grep -q 'fontconfig-arm-v31-snapshot.pixie' "$tmp/gh-match.log"
jq -e '.packages[] | select(.name == "glib" and .resolved == "gres")' "$tmp/pins" >/dev/null

# publish-index uploads the tarball the pin will name. It must refuse first.
printf '%s\n' '# publish=1' '# build=1' '# gtk_target=gnome' \
  "$(printf 'build\tfontconfig\tgit\tmain\t%s\t%s\t-\n' "$NEW" "$fc_inputs")" \
  > "$tmp/index-plan.tsv"
mkdir -p "$tmp/index-tb"
cp "$tmp/marked-old.tar.xz" "$tmp/index-tb/fontconfig-$ABI.tar.xz"
: > "$tmp/gh-index.log"
if GH_LOG="$tmp/gh-index.log" PATH="$bin:$PATH" \
  "$ROOT/scripts/publish-index.sh" \
  --plan "$tmp/index-plan.tsv" \
  --tarball-dir "$tmp/index-tb" \
  --arch aarch64 --gtk gnome \
  --repo roojs/pixiewood-pkgs \
  --created 2026-11-08T01:02:03Z \
  --out "$tmp/index-mismatch.json" > "$tmp/index-mismatch.out" 2> "$tmp/index-mismatch.err"; then
  die "publish-index uploaded a tarball built from $OLD as $NEW"
fi
[ ! -s "$tmp/gh-index.log" ] || die "publish-index ran gh for a mismatched commit"
[ ! -e "$tmp/index-mismatch.json" ] || die "publish-index wrote an index for a mismatched commit"
cmp -s "$tmp/marked-old.tar.xz" "$tmp/index-tb/fontconfig-$ABI.tar.xz" || die "publish-index changed the tarball"

cp "$tmp/marked-new.tar.xz" "$tmp/index-tb/fontconfig-$ABI.tar.xz"
: > "$tmp/gh-index.log"
GH_LOG="$tmp/gh-index.log" PATH="$bin:$PATH" \
  "$ROOT/scripts/publish-index.sh" \
  --plan "$tmp/index-plan.tsv" \
  --tarball-dir "$tmp/index-tb" \
  --arch aarch64 --gtk gnome \
  --repo roojs/pixiewood-pkgs \
  --created 2026-11-08T01:02:03Z \
  --out "$tmp/index-match.json" > "$tmp/index-match.out"
grep -q 'fontconfig-arm-v31-snapshot.pixie' "$tmp/gh-index.log"
jq -e --arg new "$NEW" '.packages[] | select(.name == "fontconfig" and .resolved == $new)' "$tmp/index-match.json" >/dev/null

# obtain: inputs-only cache is not the new commit. A current pin still wins.
jq -n --arg old "$OLD" --arg inputs "$fc_inputs" --arg url "https://gitlab.gnome.org/GNOME/gtk.git" \
  '{packages: [{abi:"arm64-v8a", repo:$url, name:"fontconfig", track:"main", resolved:$old, inputs:$inputs, url:"https://example.invalid/fontconfig-old.pixie"}]}' \
  > "$tmp/obtain.pins"
stale_cache="$tmp/stale-cache"
mkdir -p "$stale_cache/$ABI"
make_fontconfig_tarball "$stale_cache/$ABI/fontconfig.tar.xz" stale-binary
printf '%s\n' "$fc_inputs" > "$stale_cache/$ABI/fontconfig.inputs"
decision="$("$ROOT/scripts/obtain-package.sh" \
  --name fontconfig --abi "$ABI" --gtk gnome \
  --cache "$stale_cache" --pins "$tmp/obtain.pins" \
  --resolved "$NEW" --inputs "$fc_inputs")"
[ "$decision" = build ] || die "obtain used an inputs-only cache for $NEW: $decision"
decision="$("$ROOT/scripts/obtain-package.sh" \
  --name fontconfig --abi "$ABI" --gtk gnome \
  --cache "$stale_cache" --pins "$tmp/obtain.pins" \
  --resolved "$OLD" --inputs "$fc_inputs")"
[ "$decision" = "pin"$'\t'"https://example.invalid/fontconfig-old.pixie" ] || die "a current snapshot pin was skipped: $decision"
decision="$("$ROOT/scripts/obtain-package.sh" \
  --name fontconfig --abi "$ABI" --gtk gnome \
  --cache "$stale_cache" --pins "$tmp/missing.pins" \
  --inputs "$fc_inputs")"
[ "$decision" = "cache"$'\t'"$stale_cache/$ABI/fontconfig.tar.xz" ] || die "inputs-only cache should still hit when no commit was requested: $decision"

# Real build. The output and the cache must name the commit the builder got.
: > "$tmp/build.log"
BUILD_LOG="$tmp/build.log" BUILD_PIXIE="$tmp/build-pixie.sh" \
  "$ROOT/scripts/build-changed.sh" \
  --skip-missing-check \
  --plan "$tmp/applied-plan.tsv" \
  --arch aarch64 --gtk gnome \
  --cache "$cache" \
  --tarball-dir "$tmp/out" > "$tmp/build-once.out"
grep -qx 'build fontconfig' "$tmp/build-once.out" || die "build-changed did not build fontconfig"
grep -q -- "--resolved $NEW" "$tmp/build.log" || die "builder was not passed the resolved commit"
built="$tmp/out/fontconfig-$ABI.tar.xz"
[ "$(tarball_so "$built")" = "built-for-$NEW" ] || die "output is not the tarball the builder wrote"
[ "$(tarball_revision "$built")" = "$NEW" ] || die "built tarball does not record $NEW"
[ "$(tarball_revision "$cache/$ABI/fontconfig.tar.xz")" = "$NEW" ] || die "cache was saved without the built commit"
[ "$(cksum "$cache/$ABI/fontconfig.tar.xz")" != "$stale_bytes" ] || die "cache still holds the stale tarball"
built_calls="$(wc -l < "$tmp/build.log" | tr -d ' ')"
[ "$built_calls" = 1 ] || die "expected one build, saw $built_calls"

BUILD_LOG="$tmp/build.log" BUILD_PIXIE="$tmp/build-pixie.sh" \
  "$ROOT/scripts/build-changed.sh" \
  --skip-missing-check \
  --plan "$tmp/applied-plan.tsv" \
  --arch aarch64 --gtk gnome \
  --cache "$cache" \
  --tarball-dir "$tmp/out-again" > "$tmp/build-twice.out"
grep -qx 'cache fontconfig' "$tmp/build-twice.out" || die "the commit just built was not reused"
[ "$(wc -l < "$tmp/build.log" | tr -d ' ')" = 1 ] || die "a second build ran for the same commit"
[ "$(tarball_revision "$tmp/out-again/fontconfig-$ABI.tar.xz")" = "$NEW" ]
[ "$(tarball_so "$tmp/out-again/fontconfig-$ABI.tar.xz")" = "built-for-$NEW" ]

awk -F '\t' -v other="$OTHER" 'BEGIN { OFS = "\t" } $2 == "fontconfig" { $5 = other } { print }' \
  "$tmp/applied-plan.tsv" > "$tmp/other-plan.tsv"
BUILD_LOG="$tmp/build.log" BUILD_PIXIE="$tmp/build-pixie.sh" \
  "$ROOT/scripts/build-changed.sh" \
  --skip-missing-check \
  --plan "$tmp/other-plan.tsv" \
  --arch aarch64 --gtk gnome \
  --cache "$cache" \
  --tarball-dir "$tmp/out-other" > "$tmp/build-other.out"
grep -qx 'build fontconfig' "$tmp/build-other.out" || die "a newer commit reused the previous tarball"
grep -q -- "--resolved $OTHER" "$tmp/build.log" || die "builder was not passed $OTHER"
[ "$(tarball_revision "$tmp/out-other/fontconfig-$ABI.tar.xz")" = "$OTHER" ]
[ "$(tarball_so "$tmp/out-other/fontconfig-$ABI.tar.xz")" = "built-for-$OTHER" ]
[ "$(tarball_revision "$cache/$ABI/fontconfig.tar.xz")" = "$OTHER" ]

# The cache now identifies OTHER. Put NEW back by building it again, then ask obtain.
awk -F '\t' -v new="$NEW" 'BEGIN { OFS = "\t" } $2 == "fontconfig" { $5 = new } { print }' \
  "$tmp/applied-plan.tsv" > "$tmp/new-plan.tsv"
BUILD_LOG="$tmp/build.log" BUILD_PIXIE="$tmp/build-pixie.sh" \
  "$ROOT/scripts/build-changed.sh" \
  --skip-missing-check \
  --plan "$tmp/new-plan.tsv" \
  --arch aarch64 --gtk gnome \
  --cache "$cache" \
  --tarball-dir "$tmp/out-new" > "$tmp/build-new.out"
decision="$("$ROOT/scripts/obtain-package.sh" \
  --name fontconfig --abi "$ABI" --gtk gnome \
  --cache "$cache" --pins "$tmp/obtain.pins" \
  --resolved "$NEW" --inputs "$fc_inputs")"
[ "$decision" = "cache"$'\t'"$cache/$ABI/fontconfig.tar.xz" ] || die "obtain missed the cache built for $NEW: $decision"
decision="$("$ROOT/scripts/obtain-package.sh" \
  --name fontconfig --abi "$ABI" --gtk gnome \
  --cache "$cache" --pins "$tmp/obtain.pins" \
  --resolved "$OTHER" --inputs "$fc_inputs")"
[ "$decision" = build ] || die "obtain reused $NEW for $OTHER: $decision"
decision="$("$ROOT/scripts/obtain-package.sh" \
  --name fontconfig --abi "$ABI" --gtk gnome \
  --cache "$cache" --pins "$tmp/missing.pins" \
  --resolved "$NEW" --inputs other-inputs)"
[ "$decision" = build ] || die "obtain ignored a different inputs hash: $decision"

# prove takes the same cache. A stale inputs-only entry must not be published.
prove_cache="$tmp/prove-cache"
mkdir -p "$prove_cache/$ABI"
make_fontconfig_tarball "$prove_cache/$ABI/fontconfig.tar.xz" stale-binary
printf '%s\n' "$fc_inputs" > "$prove_cache/$ABI/fontconfig.inputs"
"$ROOT/scripts/prove-package.sh" --check "$prove_cache/$ABI/fontconfig.tar.xz" --package fontconfig --arch aarch64 > "$tmp/prove-check.out"
jq -n --arg old "$OLD" --arg inputs "$fc_inputs" --arg url "https://gitlab.gnome.org/GNOME/gtk.git" \
  '{packages: [{abi:"arm64-v8a", repo:$url, name:"fontconfig", track:"main", resolved:$old, inputs:$inputs, url:"https://example.invalid/fontconfig-old.pixie"}]}' \
  > "$tmp/prove.pins"
cat > "$tmp/prove-build-pixie.sh" << 'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "${BUILD_LOG:?}"
tarball=""
resolved=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tarball) tarball=$2; shift 2 ;;
    --resolved) resolved=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$tarball" ]
[ -n "$resolved" ]
dir="$(mktemp -d)"
mkdir -p "$dir/lib/arm64-v8a/pkgconfig" "$dir/lib/arm64-v8a" "$dir/share/pixiewood"
printf '%s\n' 'prefix=/' 'Name: fontconfig' 'Version: 9.9.9' > "$dir/lib/arm64-v8a/pkgconfig/fontconfig.pc"
printf 'prove-built-for-%s\n' "$resolved" > "$dir/lib/arm64-v8a/libfontconfig.so"
printf '%s\n' "$resolved" > "$dir/share/pixiewood/upstream-revision"
tar -C "$dir" -cJf "$tarball" .
rm -rf "$dir"
EOF
chmod +x "$tmp/prove-build-pixie.sh"
: > "$tmp/prove-build.log"
: > "$tmp/prove-gh.log"
cat > "$tmp/run-prove.sh" << EOF
#!/bin/bash
set -euo pipefail
mount --bind "$tmp/prove-build-pixie.sh" "$ROOT/scripts/build-pixie.sh"
export PATH="$bin:\$PATH"
export GIT_LS_REMOTE_SHA="$NEW"
export GH_LOG="$tmp/prove-gh.log"
export BUILD_LOG="$tmp/prove-build.log"
export PROVE_PUBLISH=1
export PROVE_CREATED=2026-11-08T01:02:03Z
export GITHUB_REPOSITORY=roojs/pixiewood-pkgs
export PROVE_UID="$(id -u)"
"$ROOT/scripts/upstream-index.sh" resolve --gtk gnome --out "$tmp/prove-resolved.tsv"
awk -F '\t' '\$1 == "fontconfig" { print \$5 }' "$tmp/prove-resolved.tsv" > "$tmp/prove-inputs"
printf '%s\n' "\$(tr -d '[:space:]' < "$tmp/prove-inputs")" > "$prove_cache/$ABI/fontconfig.inputs"
exec "$ROOT/scripts/prove-package.sh" \\
  --arch aarch64 --gtk gnome --packages fontconfig \\
  --cache "$prove_cache" --pins "$tmp/prove.pins" --out "$tmp/prove-out"
EOF
chmod +x "$tmp/run-prove.sh"
set +e
unshare --user --mount --map-root-user "$tmp/run-prove.sh" > "$tmp/prove.out" 2> "$tmp/prove.err"
prove_rc=$?
set -e
if grep -qx 'cache fontconfig alone' "$tmp/prove.out"; then
  die "prove reused an inputs-only cache after fontconfig's commit changed"
fi
grep -qx 'build fontconfig alone' "$tmp/prove.out" || die "prove did not build fontconfig"
if [ "$prove_rc" -ne 0 ]; then
  cat "$tmp/prove.err" >&2
  die "prove failed after choosing a build"
fi
grep -q -- "--resolved $NEW" "$tmp/prove-build.log" || die "prove did not pass the resolved commit to the builder"
prove_tar="$tmp/prove-out/fontconfig-$ABI.tar.xz"
[ "$(tarball_so "$prove_tar")" = "prove-built-for-$NEW" ] || die "prove published a tarball it did not just build"
[ "$(tarball_revision "$prove_tar")" = "$NEW" ] || die "prove tarball does not record $NEW"
pin_resolved="$(jq -r --arg abi "$ABI" '.packages[] | select(.name == "fontconfig" and .abi == $abi) | .resolved' "$ROOT/snapshot.pins")"
[ "$pin_resolved" = "$NEW" ] || die "snapshot pin resolved is $pin_resolved, tarball is $NEW"
grep -q 'fontconfig-arm-v31-snapshot.pixie' "$tmp/prove-gh.log" || die "prove did not upload the built package"
prove_inputs="$(tr -d '[:space:]' < "$tmp/prove-inputs")"
[ -n "$prove_inputs" ] || die "prove did not resolve fontconfig inputs"
decision="$("$ROOT/scripts/obtain-package.sh" \
  --name fontconfig --abi "$ABI" --gtk gnome \
  --cache "$prove_cache" --pins "$tmp/missing.pins" \
  --resolved "$NEW" --inputs "$prove_inputs")"
[ "$decision" = "cache"$'\t'"$prove_cache/$ABI/fontconfig.tar.xz" ] || die "prove's cache is not reusable for $NEW: $decision"
decision="$("$ROOT/scripts/obtain-package.sh" \
  --name fontconfig --abi "$ABI" --gtk gnome \
  --cache "$prove_cache" --pins "$tmp/missing.pins" \
  --resolved "$OTHER" --inputs "$prove_inputs")"
[ "$decision" = build ] || die "prove's cache stamp ignored the commit: $decision"

echo "stale upstream cache: ok"
