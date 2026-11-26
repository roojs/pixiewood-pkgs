#!/usr/bin/env bash
# An unreviewed commit on the upstream branch named by fontconfig.wrap must
# not be checked out, packed, or recorded as the fontconfig package that
# later packages link.
#
# The scheduled Monitor upstreams job runs update-wraps, then
# upstream-index resolve and plan, then build-changed, then publish-package.
# This test runs those programs. It fails while a new commit on that branch
# becomes the published fontconfig tree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrap="$ROOT/packages/fontconfig/fontconfig.wrap"
order="$ROOT/build-order.txt"

bash -n "$ROOT/scripts/update-wraps.sh"
bash -n "$ROOT/scripts/upstream-index.sh"
bash -n "$ROOT/scripts/build-changed.sh"
bash -n "$ROOT/scripts/build-pixie.sh"
bash -n "$ROOT/scripts/checkout-cache.sh"
bash -n "$ROOT/scripts/publish-package.sh"
bash -n "$ROOT/scripts/current-pins.sh"
bash -n "$ROOT/scripts/obtain-package.sh"

revision_of() {
  sed -n 's/^revision[[:space:]]*=[[:space:]]*//p' "$1" | head -n1 | tr -d '[:space:]'
}

# fontconfig is ahead of the packages the finding says link it.
awk '
  $1 !~ /^#/ && NF {
    if ($1 == "fontconfig") font = NR
    if ($1 == "pango") pango = NR
    if ($1 == "gtk") gtk = NR
    if ($1 == "libadwaita") adwaita = NR
  }
  END {
    if (!(font && pango && gtk && adwaita)) exit 1
    if (!(font < pango && font < gtk && font < adwaita)) exit 1
  }
' "$order"

real_revision="$(revision_of "$wrap")"
[ -n "$real_revision" ]

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

upstream="$tmp/upstream"
mkdir -p "$upstream"
git -C "$upstream" init -q -b main
git -C "$upstream" config user.email test@example.com
git -C "$upstream" config user.name test
mkdir -p "$upstream/src"
cat > "$upstream/meson.build" << 'EOF'
project('fontconfig', 'c', version: '0.0.0')
EOF
printf 'trusted\n' > "$upstream/src/marker.c"
git -C "$upstream" add meson.build src/marker.c
git -C "$upstream" commit -q -m trusted
trusted="$(git -C "$upstream" rev-parse HEAD)"

# The published pin is this commit until the branch named by the wrap moves.
case "$real_revision" in
  main|master|HEAD|head|trunk)
    if [ "$real_revision" != main ]; then
      git -C "$upstream" branch "$real_revision" HEAD
    fi
    ;;
  *)
    if [[ ! "$real_revision" =~ ^[0-9a-f]{40}$ ]]; then
      git -C "$upstream" tag -a "$real_revision" HEAD -m "$real_revision"
    fi
    ;;
esac

copy="$tmp/repo"
mkdir -p "$copy"
tar -C "$ROOT" -cf - \
  --exclude .git --exclude out --exclude .cache \
  scripts packages cross android-distro.conf meson.build sysroot build-order.txt \
  release.pins snapshot.pins \
  | tar -C "$copy" -xf -
sed -i "s|^url[[:space:]]*=.*|url = ${upstream}|" "$copy/packages/fontconfig/fontconfig.wrap"
[ "$(revision_of "$copy/packages/fontconfig/fontconfig.wrap")" = "$real_revision" ]

# shellcheck source=../scripts/update-wraps.sh
source "$copy/scripts/update-wraps.sh"
onepkg="$tmp/onepkg"
mkdir -p "$onepkg"
ln -s "$copy/packages/fontconfig" "$onepkg/fontconfig"

# Yesterday's resolve, before the unreviewed commit exists.
update_wrap "$copy/packages/fontconfig/fontconfig.wrap"
"$copy/scripts/upstream-index.sh" resolve --packages "$onepkg" --gtk gnome --out "$tmp/yesterday.tsv"
yesterday="$(awk -F '\t' '$1 == "fontconfig" { print $4 }' "$tmp/yesterday.tsv")"
yesterday_inputs="$(awk -F '\t' '$1 == "fontconfig" { print $5 }' "$tmp/yesterday.tsv")"
[ -n "$yesterday" ] && [ -n "$yesterday_inputs" ]

printf 'unreviewed-upstream-commit\n' > "$upstream/src/marker.c"
git -C "$upstream" add src/marker.c
git -C "$upstream" commit -q -m unreviewed
attacker="$(git -C "$upstream" rev-parse HEAD)"
[ "$trusted" != "$attacker" ]
case "$real_revision" in
  master|HEAD|head|trunk)
    git -C "$upstream" branch -f "$real_revision" HEAD
    ;;
esac

# The daily job runs again after that commit. A branch revision stays as written.
update_wrap "$copy/packages/fontconfig/fontconfig.wrap"
after_update="$(revision_of "$copy/packages/fontconfig/fontconfig.wrap")"
"$copy/scripts/upstream-index.sh" resolve --packages "$onepkg" --gtk gnome --out "$tmp/font.tsv"
font_kind="$(awk -F '\t' '$1 == "fontconfig" { print $2 }' "$tmp/font.tsv")"
font_track="$(awk -F '\t' '$1 == "fontconfig" { print $3 }' "$tmp/font.tsv")"
font_resolved="$(awk -F '\t' '$1 == "fontconfig" { print $4 }' "$tmp/font.tsv")"
font_inputs="$(awk -F '\t' '$1 == "fontconfig" { print $5 }' "$tmp/font.tsv")"
[ -n "$font_kind" ] && [ -n "$font_track" ] && [ -n "$font_resolved" ] && [ -n "$font_inputs" ]

# Yesterday's pin is the commit resolve returned before the new upstream
# commit. Other packages are unchanged.
list="$tmp/previous.list"
: > "$list"
while IFS= read -r name || [ -n "$name" ]; do
  name=${name%%#*}
  name=${name#"${name%%[![:space:]]*}"}
  name=${name%"${name##*[![:space:]]}"}
  [ -n "$name" ] || continue
  if [ "$name" = fontconfig ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' \
      fontconfig "$font_track" "$yesterday" "$yesterday_inputs" "file://${tmp}/old/fontconfig.pixie" >> "$list"
  else
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$name" "1.0.0" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "inputs-${name}" \
      "file://${tmp}/old/${name}.pixie" >> "$list"
  fi
done < "$copy/build-order.txt"
mkdir -p "$tmp/old"
: > "$tmp/old/fontconfig.pixie"
"$copy/scripts/upstream-index.sh" write \
  --list "$list" --abi arm64-v8a --arch aarch64 --gtk gnome \
  --created 2026-11-01T00:00:00Z --out "$tmp/previous.json"

resolved="$tmp/resolved.tsv"
: > "$resolved"
while IFS= read -r name || [ -n "$name" ]; do
  name=${name%%#*}
  name=${name#"${name%%[![:space:]]*}"}
  name=${name%"${name##*[![:space:]]}"}
  [ -n "$name" ] || continue
  if [ "$name" = fontconfig ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' \
      fontconfig "$font_kind" "$font_track" "$font_resolved" "$font_inputs" >> "$resolved"
  else
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$name" file "1.0.0" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "inputs-${name}" >> "$resolved"
  fi
done < "$copy/build-order.txt"
"$copy/scripts/upstream-index.sh" plan \
  --resolved "$resolved" \
  --previous "$tmp/previous.json" \
  --abi arm64-v8a \
  --gtk gnome \
  --build-order "$copy/build-order.txt" \
  --out "$tmp/plan.tsv"
"$copy/scripts/current-pins.sh" apply \
  --plan "$tmp/plan.tsv" --out "$tmp/applied.tsv" --arch aarch64
plan_status="$(awk -F '\t' '$2 == "fontconfig" { print $1; exit }' "$tmp/applied.tsv")"
plan_resolved="$(awk -F '\t' '$2 == "fontconfig" { print $5; exit }' "$tmp/applied.tsv")"

# Tools the compiler needs are stubbed. checkout-cache and the wrap logic are not.
stubs="$tmp/stubs"
mkdir -p "$stubs"
for tool in meson ninja pkg-config patch curl cmake valac sassc nasm glslc gperf pixie-pkg; do
  cat > "$stubs/$tool" << EOF
#!/bin/sh
printf '%s\n' "\$0 \$*" >> "$tmp/tool.log"
exit 1
EOF
  chmod +x "$stubs/$tool"
done
# pixie-pkg fetch is how earlier kept packages are unpacked. It is not the
# fontconfig checkout. Succeed without reading the fontconfig revision again.
cat > "$stubs/pixie-pkg" << EOF
#!/bin/sh
printf '%s\n' "\$0 \$*" >> "$tmp/tool.log"
exit 0
EOF
chmod +x "$stubs/pixie-pkg"

ndk="$tmp/sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64"
mkdir -p "$ndk"
export ANDROID_SDK_ROOT="$tmp/sdk"
export ANDROID_NDK_VERSION=28.2.13676358
export PIXIEWOOD_CHECKOUT_CACHE="$tmp/checkouts"
export PATH="/usr/bin:${stubs}"

builder="$tmp/record-build.sh"
cat > "$builder" << EOF
#!/usr/bin/env bash
set -euo pipefail
resolved=""
tarball=""
only=""
args=("\$@")
i=0
while [ "\$i" -lt "\$#" ]; do
  case "\${args[\$i]}" in
    --resolved) i=\$((i + 1)); resolved="\${args[\$i]}" ;;
    --tarball) i=\$((i + 1)); tarball="\${args[\$i]}" ;;
    --only) i=\$((i + 1)); only="\${args[\$i]}" ;;
  esac
  i=\$((i + 1))
done
printf '%s\n' "\$only \$resolved" >> "$tmp/builder.args"
export PIXIEWOOD_SYSROOT_WORK="$tmp/work-\$only"
set +e
"$copy/scripts/build-pixie.sh" "\$@" > "$tmp/build-\$only.out" 2> "$tmp/build-\$only.err"
set -e
if [ ! -d "\$PIXIEWOOD_SYSROOT_WORK/subprojects/\$only/.git" ]; then
  echo "build-pixie did not check out \$only" >&2
  cat "$tmp/build-\$only.out" >&2 || true
  cat "$tmp/build-\$only.err" >&2 || true
  exit 1
fi
git -C "\$PIXIEWOOD_SYSROOT_WORK/subprojects/\$only" rev-parse HEAD > "$tmp/checkout-\$only"
[ -n "\$tarball" ]
mkdir -p "\$(dirname "\$tarball")"
tar -C "\$PIXIEWOOD_SYSROOT_WORK/subprojects/\$only" -cJf "\$tarball" .
EOF
chmod +x "$builder"

checked_out=""
published_resolved=""
published_url=""
if [ "$plan_status" = build ]; then
  export BUILD_PIXIE="$builder"
  set +e
  "$copy/scripts/build-changed.sh" \
    --skip-missing-check \
    --plan "$tmp/applied.tsv" \
    --arch aarch64 \
    --gtk gnome \
    --tarball-dir "$tmp/packages-out" > "$tmp/changed.out" 2> "$tmp/changed.err"
  set -e
  if [ -f "$tmp/checkout-fontconfig" ]; then
    checked_out="$(cat "$tmp/checkout-fontconfig")"
  fi
  tarball="$tmp/packages-out/fontconfig-arm64-v8a.tar.xz"
  if [ -f "$tarball" ]; then
    set +e
    "$copy/scripts/publish-package.sh" \
      --name fontconfig \
      --tarball "$tarball" \
      --arch aarch64 \
      --gtk gnome \
      --track "$font_track" \
      --resolved "$plan_resolved" \
      --inputs "$font_inputs" \
      --created 2026-11-26T00:00:00Z \
      --repo roojs/pixiewood-pkgs \
      --no-upload > "$tmp/publish.out" 2> "$tmp/publish.err"
    publish_status=$?
    set -e
    if [ "$publish_status" -eq 0 ]; then
      published_url="$(awk '/^https:\/\// { print; exit }' "$tmp/publish.out")"
      published_resolved="$(jq -r '.packages[] | select(.name == "fontconfig" and .abi == "arm64-v8a") | .resolved' "$copy/snapshot.pins" | head -n1)"
    fi
  fi
fi

# Prove builds fontconfig without --resolved, so the wrap revision is resolved
# again at checkout. A directory that already has meson.build is what Meson
# 1.12.1 compiles (wrap.py _resolve returns it before _get_git).
prove_marker=""
export PIXIEWOOD_SYSROOT_WORK="$tmp/prove-work"
set +e
"$copy/scripts/build-pixie.sh" \
  --only fontconfig --arch aarch64 --gtk gnome \
  --tarball "$tmp/prove.tar.xz" > "$tmp/prove.out" 2> "$tmp/prove.err"
set -e
if [ -f "$tmp/prove-work/subprojects/fontconfig/src/marker.c" ]; then
  prove_marker="$(cat "$tmp/prove-work/subprojects/fontconfig/src/marker.c")"
fi

# The next build of pango, gtk, and libadwaita takes fontconfig from the pin
# list the unattended publish just wrote. Their own recipes changed; fontconfig's
# row did not, so it is kept and linked.
dep_urls=""
if [ -n "$published_url" ]; then
  "$copy/scripts/current-pins.sh" previous \
    --abi arm64-v8a --gtk gnome --out "$tmp/after.json"
  dep_resolved="$(jq -r '.packages[] | select(.name == "fontconfig") | .resolved' "$tmp/after.json" | head -n1)"
  dep_url="$(jq -r '.packages[] | select(.name == "fontconfig") | .url' "$tmp/after.json" | head -n1)"
  dep_list="$tmp/dep.list"
  : > "$dep_list"
  while IFS= read -r name || [ -n "$name" ]; do
    name=${name%%#*}
    name=${name#"${name%%[![:space:]]*}"}
    name=${name%"${name##*[![:space:]]}"}
    [ -n "$name" ] || continue
    if [ "$name" = fontconfig ]; then
      printf '%s\t%s\t%s\t%s\t%s\n' \
        fontconfig "$font_track" "$dep_resolved" "$font_inputs" "$dep_url" >> "$dep_list"
    else
      printf '%s\t%s\t%s\t%s\t%s\n' \
        "$name" "1.0.0" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "inputs-${name}" \
        "file://${tmp}/old/${name}.pixie" >> "$dep_list"
    fi
  done < "$copy/build-order.txt"
  "$copy/scripts/upstream-index.sh" write \
    --list "$dep_list" --abi arm64-v8a --arch aarch64 --gtk gnome \
    --created 2026-11-26T00:00:00Z --out "$tmp/dep-previous.json"
  dep_resolved_file="$tmp/dep-resolved.tsv"
  : > "$dep_resolved_file"
  while IFS= read -r name || [ -n "$name" ]; do
    name=${name%%#*}
    name=${name#"${name%%[![:space:]]*}"}
    name=${name%"${name##*[![:space:]]}"}
    [ -n "$name" ] || continue
    case "$name" in
      fontconfig)
        printf '%s\t%s\t%s\t%s\t%s\n' \
          fontconfig "$font_kind" "$font_track" "$dep_resolved" "$font_inputs" >> "$dep_resolved_file"
        ;;
      pango|gtk|libadwaita)
        printf '%s\t%s\t%s\t%s\t%s\n' \
          "$name" file "1.0.0" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "inputs-new-${name}" >> "$dep_resolved_file"
        ;;
      *)
        printf '%s\t%s\t%s\t%s\t%s\n' \
          "$name" file "1.0.0" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "inputs-${name}" >> "$dep_resolved_file"
        ;;
    esac
  done < "$copy/build-order.txt"
  "$copy/scripts/upstream-index.sh" plan \
    --resolved "$dep_resolved_file" \
    --previous "$tmp/dep-previous.json" \
    --abi arm64-v8a \
    --gtk gnome \
    --build-order "$copy/build-order.txt" \
    --out "$tmp/dep-plan.tsv"
  "$copy/scripts/build-changed.sh" \
    --dry-run \
    --skip-missing-check \
    --plan "$tmp/dep-plan.tsv" \
    --arch aarch64 \
    --gtk gnome \
    --tarball-dir "$tmp/dep-out" > "$tmp/dep-dry.out"
  dep_urls="$(grep -E '^dep (pango|gtk|libadwaita) fontconfig ' "$tmp/dep-dry.out" || true)"
fi

# obtain-package decides a snapshot build when the resolved commit moved.
obtain_decision="$("$copy/scripts/obtain-package.sh" \
  --name fontconfig \
  --abi arm64-v8a \
  --gtk gnome \
  --pins "$tmp/previous.json" \
  --resolved "$font_resolved" \
  --inputs "$font_inputs")"

# Resolving the branch tip is not, by itself, the published package. The
# failure is checking that commit out, packing it, or recording it where
# pango, gtk, and libadwaita will link it.
selected=0
if [ "$checked_out" = "$attacker" ] || [ "$published_resolved" = "$attacker" ]; then
  selected=1
fi
if [ "$prove_marker" = "unreviewed-upstream-commit" ]; then
  selected=1
fi
if [ -n "$published_url" ] && printf '%s\n' "$dep_urls" | grep -q "$published_url"; then
  if [ "$published_resolved" = "$attacker" ]; then
    selected=1
  fi
fi

if [ "$selected" -eq 1 ]; then
  echo "unreviewed fontconfig commit ${attacker} was selected for the published package" >&2
  echo "wrap revision before update: ${real_revision}" >&2
  echo "wrap revision after update-wraps: ${after_update}" >&2
  echo "resolve: ${font_resolved}" >&2
  echo "plan: ${plan_status} ${plan_resolved}" >&2
  echo "checkout: ${checked_out:-none}" >&2
  echo "published: ${published_resolved:-none} ${published_url:-none}" >&2
  echo "prove marker: ${prove_marker:-none}" >&2
  echo "obtain: ${obtain_decision}" >&2
  echo "later deps:" >&2
  printf '%s\n' "$dep_urls" >&2
  exit 1
fi

echo "fontconfig floating revision: ok"
