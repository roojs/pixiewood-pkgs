#!/usr/bin/env bash
# Put downloaded upstream plans at plans/upstream-plan-<gtk>/plan.tsv.
# actions/download-artifact extracts one artifact directly into the destination.
# Several artifacts land in destination/<artifact-name>/.
set -euo pipefail

dest=${1:-plans}
if [ ! -d "$dest" ]; then
  echo "No upstream plans."
  exit 0
fi

shopt -s nullglob
if [ -f "$dest/plan.tsv" ]; then
  gtk="$(sed -n 's/^# gtk_target=//p' "$dest/plan.tsv" | head -n1)"
  if [ -z "$gtk" ]; then
    echo "plan.tsv is missing gtk_target" >&2
    exit 1
  fi
  mkdir -p "$dest/upstream-plan-$gtk"
  mv "$dest/plan.tsv" "$dest/upstream-plan-$gtk/plan.tsv"
  if [ -f "$dest/resolved.tsv" ]; then
    mv "$dest/resolved.tsv" "$dest/upstream-plan-$gtk/resolved.tsv"
  fi
  echo "Placed the single upstream plan at upstream-plan-$gtk"
fi

count=0
for plan in "$dest"/upstream-plan-*/plan.tsv; do
  count=$((count + 1))
  echo "upstream plan $(basename "$(dirname "$plan")")"
done
if [ "$count" -eq 0 ]; then
  echo "No upstream plans."
fi
