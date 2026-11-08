# Read and write release.pins and snapshot.pins as JSON.
# Source this file; do not execute it.

pins_rows() {
  local file=$1
  [ -f "$file" ] || return 0
  jq -r '
    .packages[]
    | [.abi, .gtk, .release, .name, .track, .resolved, .inputs, .url]
    | @tsv
  ' "$file"
}

pins_store() {
  local file=$1 src
  src="$(mktemp)"
  cat > "$src"
  if [ ! -s "$src" ]; then
    jq -n '{packages: []}' > "$file"
    rm -f "$src"
    return 0
  fi
  jq -R -s '
    split("\n")
    | map(select(length > 0 and (startswith("#") | not)))
    | map(split("\t"))
    | map(select(length >= 8))
    | {
        packages: map({
          abi: .[0],
          gtk: .[1],
          release: .[2],
          name: .[3],
          track: .[4],
          resolved: .[5],
          inputs: .[6],
          url: .[7]
        })
      }
  ' "$src" > "$file"
  rm -f "$src"
}

pins_upsert() {
  local file=$1
  local abi=$2 gtk=$3 release=$4 name=$5 track=$6 resolved=$7 inputs=$8 url=$9
  local tmp row
  row="$(jq -n \
    --arg abi "$abi" --arg gtk "$gtk" --arg release "$release" --arg name "$name" \
    --arg track "$track" --arg resolved "$resolved" --arg inputs "$inputs" --arg url "$url" \
    '{abi:$abi, gtk:$gtk, release:$release, name:$name, track:$track, resolved:$resolved, inputs:$inputs, url:$url}')"
  tmp="$(mktemp)"
  if [ ! -f "$file" ]; then
    jq -n --argjson row "$row" '{packages: [$row]}' > "$tmp"
  else
    jq --argjson row "$row" '
      def same: .abi == $row.abi and .gtk == $row.gtk and .name == $row.name;
      if any(.packages[]; same) then
        .packages |= map(if same then $row else . end)
      else
        .packages += [$row]
      end
    ' "$file" > "$tmp"
  fi
  mv "$tmp" "$file"
}
