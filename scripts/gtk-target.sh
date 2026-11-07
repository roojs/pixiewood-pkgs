# GTK source targets. Source this file; do not execute it.
# A branch target is named <repo-owner>.<branch>. A pinned commit may use a short name.

gtk_target_owner() {
  local url=$1 owner
  owner="$(printf '%s\n' "$url" | sed -n 's#^.*/\([^/][^/]*\)/[^/][^/]*$#\1#p')"
  if [ -z "$owner" ]; then
    echo "Cannot read repo owner from $url" >&2
    return 1
  fi
  printf '%s\n' "$owner"
}

gtk_target_check() {
  local file=$1 line name url rev patch extra owner expect found=0
  if [ ! -f "$file" ]; then
    echo "GTK target list missing: $file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    extra=""
    read -r name url rev patch extra <<< "$line"
    if [ -n "$extra" ] || [ -z "$name" ] || [ -z "$url" ] || [ -z "$rev" ] || [ -z "$patch" ]; then
      echo "GTK target line needs name url revision patch: $line" >&2
      return 1
    fi
    found=1
    if [[ "$rev" =~ ^[0-9a-f]{40}$ ]]; then
      continue
    fi
    owner="$(gtk_target_owner "$url")" || return 1
    expect="${owner}.${rev}"
    if [ "$name" != "$expect" ]; then
      echo "GTK branch target must be named ${expect} (repo owner.branch), not ${name}" >&2
      return 1
    fi
  done < "$file"
  if [ "$found" -eq 0 ]; then
    echo "GTK target list is empty: $file" >&2
    return 1
  fi
}

gtk_target_names() {
  awk 'NF && $1 !~ /^#/ { print $1 }' "$1"
}

# The first target owns the shared libraries. Later targets reuse them.
gtk_target_base() {
  local file=$1 name
  name="$(awk 'NF && $1 !~ /^#/ { print $1; exit }' "$file")"
  if [ -z "$name" ]; then
    echo "GTK target list is empty: $file" >&2
    return 1
  fi
  printf '%s\n' "$name"
}

gtk_target_read() {
  local file=$1 name=$2 line
  if [ ! -f "$file" ]; then
    echo "GTK target list missing: $file" >&2
    return 1
  fi
  if ! gtk_target_check "$file"; then
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

distro_owner() {
  local repo=${1:-${GITHUB_REPOSITORY:-roojs/pixiewood-pkgs}}
  printf '%s\n' "${repo%%/*}"
}

package_wrap_owner() {
  local name=$1 wrap url
  wrap="$ROOT/packages/$name/$name.wrap"
  [ -f "$wrap" ] || return 1
  url="$(sed -n 's/^url[[:space:]]*=[[:space:]]*//p' "$wrap" | head -n1 | tr -d '[:space:]')"
  [ -n "$url" ] || return 1
  gtk_target_owner "$url"
}

# Column in current.pins. gtk and gdk follow the GTK target. A package whose
# git owner is this distribution (roojs/webkitgtk-android) is pinned as that
# owner. Everything else stays on the first GTK target.
package_pin_label() {
  local name=$1 gtk_variant=$2 repo=${3:-${GITHUB_REPOSITORY:-roojs/pixiewood-pkgs}} owner
  if [ "$name" = gtk ] || [ "$name" = gdk ]; then
    printf '%s\n' "$gtk_variant"
    return 0
  fi
  if owner="$(package_wrap_owner "$name")" && [ "$owner" = "$(distro_owner "$repo")" ]; then
    printf '%s\n' "$owner"
    return 0
  fi
  gtk_target_base "$ROOT/packages/gtk/targets"
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
