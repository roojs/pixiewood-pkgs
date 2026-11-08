#!/usr/bin/env bash
# One downloaded plan is extracted flat. Several keep their artifact directories.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bash -n "$ROOT/scripts/place-upstream-plans.sh"

mkdir -p "$tmp/flat"
printf '%s\n' '# publish=1' '# gtk_target=gnome' > "$tmp/flat/plan.tsv"
printf '%s\n' resolved > "$tmp/flat/resolved.tsv"
"$ROOT/scripts/place-upstream-plans.sh" "$tmp/flat" > "$tmp/flat.out"
test -f "$tmp/flat/upstream-plan-gnome/plan.tsv"
test -f "$tmp/flat/upstream-plan-gnome/resolved.tsv"
if [ -e "$tmp/flat/plan.tsv" ]; then
  echo "flat plan.tsv was left in the download directory" >&2
  exit 1
fi
grep -q 'Placed the single upstream plan at upstream-plan-gnome' "$tmp/flat.out"
grep -q 'upstream plan upstream-plan-gnome' "$tmp/flat.out"

mkdir -p "$tmp/many/upstream-plan-gnome" "$tmp/many/upstream-plan-other"
printf '%s\n' '# gtk_target=gnome' > "$tmp/many/upstream-plan-gnome/plan.tsv"
printf '%s\n' '# gtk_target=other' > "$tmp/many/upstream-plan-other/plan.tsv"
"$ROOT/scripts/place-upstream-plans.sh" "$tmp/many" > "$tmp/many.out"
test -f "$tmp/many/upstream-plan-gnome/plan.tsv"
test -f "$tmp/many/upstream-plan-other/plan.tsv"
if grep -q 'Placed the single upstream plan' "$tmp/many.out"; then
  echo "nested plans were moved again" >&2
  exit 1
fi

mkdir -p "$tmp/empty"
"$ROOT/scripts/place-upstream-plans.sh" "$tmp/empty" > "$tmp/empty.out"
grep -qx 'No upstream plans.' "$tmp/empty.out"

mkdir -p "$tmp/bad"
printf '%s\n' '# publish=1' > "$tmp/bad/plan.tsv"
if "$ROOT/scripts/place-upstream-plans.sh" "$tmp/bad" > "$tmp/bad.out" 2> "$tmp/bad.err"; then
  echo "a plan without gtk_target was accepted" >&2
  exit 1
fi
grep -q 'missing gtk_target' "$tmp/bad.err"

echo "place upstream plans: ok"
