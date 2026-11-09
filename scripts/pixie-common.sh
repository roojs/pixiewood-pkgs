# Shared helpers for the sysroot scripts. Source this file; do not execute it.

sysroot_json_escape() {
  local s=$1 i c out
  out=
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      '\\') out+='\\' ;;
      '"') out+='\"' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      *) out+=$c ;;
    esac
  done
  printf '%s' "$out"
}

# Print the string or number stored at "key". null prints an empty string.
# Returns 1 when the key is absent.
sysroot_json_get() {
  local key=$1 file=$2 value
  if ! value="$(awk -v key="$key" '
    function extract(line,    re, s, i, c, out, esc) {
      re = "\"" key "\"[[:space:]]*:[[:space:]]*"
      if (line !~ re) return 0
      if (match(line, re "null")) {
        print ""
        return 1
      }
      if (line ~ re "-?[0-9]+" && line !~ re "\"") {
        if (match(line, re "-?[0-9]+")) {
          s = substr(line, RSTART, RLENGTH)
          sub(/^.*:[[:space:]]*/, "", s)
          print s
          return 1
        }
      }
      if (!match(line, re "\"")) return 0
      s = substr(line, RSTART + RLENGTH)
      out = ""
      esc = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (esc) {
          if (c == "n") out = out "\n"
          else if (c == "r") out = out "\r"
          else if (c == "t") out = out "\t"
          else out = out c
          esc = 0
        } else if (c == "\\") esc = 1
        else if (c == "\"") {
          print out
          return 1
        } else out = out c
      }
      return 0
    }
    { if (extract($0)) { ok = 1; exit } }
    END { if (!ok) exit 1 }
  ' "$file")"; then
    echo "JSON file $file has no \"$key\"" >&2
    return 1
  fi
  printf '%s' "$value"
}

sysroot_set_activated_prefix() {
  local file=$1 prefix=$2 escaped tmp
  escaped="$(sysroot_json_escape "$prefix")"
  tmp="$(mktemp)"
  ESCAPED="$escaped" awk '
    function replace_prefix(line, prefix,    re, pre, rest, i, c, esc) {
      re = "\"activated_prefix\"[[:space:]]*:[[:space:]]*"
      if (match(line, re "null")) {
        pre = substr(line, 1, RSTART - 1)
        rest = substr(line, RSTART + RLENGTH)
        return pre "\"activated_prefix\": \"" prefix "\"" rest
      }
      if (match(line, re "\"")) {
        pre = substr(line, 1, RSTART - 1)
        rest = substr(line, RSTART + RLENGTH)
        esc = 0
        for (i = 1; i <= length(rest); i++) {
          c = substr(rest, i, 1)
          if (esc) { esc = 0; continue }
          if (c == "\\") { esc = 1; continue }
          if (c == "\"") {
            rest = substr(rest, i + 1)
            return pre "\"activated_prefix\": \"" prefix "\"" rest
          }
        }
      }
      return line
    }
    BEGIN { prefix = ENVIRON["ESCAPED"] }
    {
      if ($0 ~ /"activated_prefix"/) print replace_prefix($0, prefix)
      else print
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

sysroot_rewrite_prefix() {
  local old=$1 new=$2 root=$3 pc tmp
  [ -d "$root" ] || return 0
  while IFS= read -r -d '' pc; do
    tmp="$(mktemp)"
    OLD="$old" NEW="$new" awk '
      BEGIN { old = ENVIRON["OLD"]; newp = ENVIRON["NEW"] }
      $0 == "prefix=" old { print "prefix=" newp; next }
      { print }
    ' "$pc" > "$tmp"
    mv "$tmp" "$pc"
  done < <(find "$root" -name '*.pc' -type f -print0)
}

sysroot_pc_contains() {
  local dir=$1 text=$2
  [ -d "$dir" ] || return 1
  find "$dir" -name '*.pc' -type f -print0 | xargs -0 grep -F -q -- "$text"
}

# Two-column name map: "from to". Comments start with #.
sysroot_map() {
  local file=$1 key=$2 from to
  if [ ! -f "$file" ]; then
    echo "Missing name map: $file" >&2
    return 1
  fi
  while read -r from to _; do
    if [ -z "$from" ] || [ "${from#\#}" != "$from" ]; then
      continue
    fi
    if [ "$from" = "$key" ] && [ -n "$to" ]; then
      printf '%s\n' "$to"
      return 0
    fi
  done < "$file"
  echo "Unknown name: $key" >&2
  return 1
}
