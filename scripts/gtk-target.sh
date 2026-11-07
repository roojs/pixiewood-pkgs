# GTK source targets. Source this file; do not execute it.

gtk_target_read() {
  local file=$1 name=$2 line
  if [ ! -f "$file" ]; then
    echo "GTK target list missing: $file" >&2
    return 1
  fi
  if ! line="$(awk -v name="$name" '
    /^#/ || NF == 0 { next }
    $1 == name {
      if (NF < 4) {
        exit 2
      }
      print $2, $3, $4
      found = 1
      exit 0
    }
    END { if (!found) exit 1 }
  ' "$file")"; then
    echo "Unknown GTK target: $name" >&2
    echo "Known targets:" >&2
    awk 'NF && $1 !~ /^#/ { print "  " $1 }' "$file" >&2
    return 1
  fi
  printf '%s\n' "$line"
}

gtk_target_apply_wrap() {
  local wrap=$1 url=$2 rev=$3 tmp
  tmp="$(mktemp)"
  awk -v url="$url" -v rev="$rev" '
    /^url[[:space:]]*=/ { print "url = " url; next }
    /^revision[[:space:]]*=/ { print "revision = " rev; next }
    { print }
  ' "$wrap" > "$tmp"
  if ! grep -q '^url[[:space:]]*=' "$tmp" || ! grep -q '^revision[[:space:]]*=' "$tmp"; then
    echo "gtk wrap is missing url or revision: $wrap" >&2
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$wrap"
}
