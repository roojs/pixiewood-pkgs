# Read and write release.pins and snapshot.pins as JSON.
# Source this file; do not execute it.
# The pin field repo is the full git URL. packages/gtk/targets still uses a short name.

pins_targets_file() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' "$here/../packages/gtk/targets"
}

# Short name from packages/gtk/targets, or a URL, becomes the full git URL.
pins_repo_of() {
  local label=$1 file name url rest
  case "$label" in
    http://*|https://*|git@*)
      printf '%s\n' "$label"
      return 0
      ;;
  esac
  file="$(pins_targets_file)"
  if [ -f "$file" ]; then
    while read -r name url rest; do
      case "${name:-}" in ''|\#*) continue ;; esac
      if [ "$name" = "$label" ]; then
        printf '%s\n' "$url"
        return 0
      fi
    done < "$file"
  fi
  printf '%s\n' "$label"
}

# Full git URL, or the short name, becomes the short name used inside the scripts.
pins_label_of() {
  local repo=$1 file name url rest
  file="$(pins_targets_file)"
  if [ -f "$file" ]; then
    while read -r name url rest; do
      case "${name:-}" in ''|\#*) continue ;; esac
      if [ "$url" = "$repo" ] || [ "$name" = "$repo" ]; then
        printf '%s\n' "$name"
        return 0
      fi
    done < "$file"
  fi
  printf '%s\n' "$repo"
}

pins_rows() {
  local file=$1 abi repo name track resolved inputs url label
  [ -f "$file" ] || return 0
  while IFS=$'\t' read -r abi repo name track resolved inputs url; do
    [ -n "${abi:-}" ] || continue
    label="$(pins_label_of "$repo")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$abi" "$label" "$name" "$track" "$resolved" "$inputs" "$url"
  done < <(jq -r '
    .packages[]
    | [.abi, (.repo // .gtk // ""), .name, .track, .resolved, .inputs, .url]
    | @tsv
  ' "$file")
}

pins_store() {
  local file=$1 src line abi label name track resolved inputs url repo
  src="$(mktemp)"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    IFS=$'\t' read -r abi label name track resolved inputs url <<< "$line"
    [ -n "${abi:-}" ] || continue
    [ -n "${url:-}" ] || continue
    repo="$(pins_repo_of "$label")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$abi" "$repo" "$name" "$track" "$resolved" "$inputs" "$url"
  done > "$src"
  if [ ! -s "$src" ]; then
    jq -n '{packages: []}' > "$file"
    rm -f "$src"
    return 0
  fi
  jq -R -s '
    split("\n")
    | map(select(length > 0))
    | map(split("\t"))
    | map(select(length >= 7))
    | {
        packages: map({
          abi: .[0],
          repo: .[1],
          name: .[2],
          track: .[3],
          resolved: .[4],
          inputs: .[5],
          url: .[6]
        })
      }
  ' "$src" > "$file"
  rm -f "$src"
}

pins_upsert() {
  local file=$1
  local abi=$2 label=$3 name=$4 track=$5 resolved=$6 inputs=$7 url=$8
  local tmp row repo
  repo="$(pins_repo_of "$label")"
  row="$(jq -n \
    --arg abi "$abi" --arg repo "$repo" --arg name "$name" \
    --arg track "$track" --arg resolved "$resolved" --arg inputs "$inputs" --arg url "$url" \
    '{abi:$abi, repo:$repo, name:$name, track:$track, resolved:$resolved, inputs:$inputs, url:$url}')"
  tmp="$(mktemp)"
  if [ ! -f "$file" ]; then
    jq -n --argjson row "$row" '{packages: [$row]}' > "$tmp"
  else
    jq --argjson row "$row" --arg label "$label" '
      def same:
        .abi == $row.abi and .name == $row.name and (
          .repo == $row.repo or .gtk == $label or .repo == $label
        );
      if any(.packages[]; same) then
        .packages |= map(if same then $row else . end)
      else
        .packages += [$row]
      end
    ' "$file" > "$tmp"
  fi
  mv "$tmp" "$file"
}
