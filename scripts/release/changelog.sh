#!/usr/bin/env bash
# Read and date CHANGELOG.md. The first heading is the release version.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHANGELOG_MD="${CHANGELOG_MD:-$ROOT/CHANGELOG.md}"

die() {
  echo "$*" >&2
  exit 1
}

first_heading() {
  [[ -f "$CHANGELOG_MD" ]] || die "error: missing CHANGELOG.md"
  local heading
  heading="$(grep -E '^## \[' "$CHANGELOG_MD" | head -n 1 || true)"
  [[ -n "$heading" ]] || die "CHANGELOG.md: no ## [version] sections found"
  [[ "$heading" =~ ^##\ \[([^]]+)\]([[:space:]]*-[[:space:]]*(Unreleased|[0-9]{4}-[0-9]{2}-[0-9]{2}))?[[:space:]]*$ ]] \
    || die "CHANGELOG.md: cannot read the first heading: ${heading}"
  printf '%s\n' "${BASH_REMATCH[1]}"
  printf '%s\n' "${BASH_REMATCH[3]:-}"
}

section_body() {
  awk '
    /^## \[/ {
      if (seen) {
        exit
      }
      seen = 1
      next
    }
    seen {
      print
    }
  ' "$CHANGELOG_MD"
}

trim_body() {
  awk '
    { lines[++n] = $0 }
    END {
      start = 1
      end = n
      while (start <= end && lines[start] ~ /^[[:space:]]*$/) {
        start++
      }
      while (end >= start && lines[end] ~ /^[[:space:]]*$/) {
        end--
      }
      for (i = start; i <= end; i++) {
        print lines[i]
      }
    }
  '
}

cmd_version() {
  local title date
  {
    read -r title
    read -r date
  } < <(first_heading)
  if [[ "$title" == "Unreleased" ]]; then
    die "CHANGELOG.md: set the version in the first heading (## [X.Y.Z] - Unreleased) before releasing"
  fi
  if [[ "$date" != "Unreleased" ]]; then
    die "CHANGELOG.md: first section [${title}] is already dated; add ## [next] - Unreleased"
  fi
  printf '%s\n' "$title"
}

cmd_notes() {
  local body
  body="$(section_body | trim_body)"
  [[ -n "$body" ]] || die "CHANGELOG.md: empty notes for the first section"
  printf '%s\n' "$body"
}

cmd_finalize() {
  local tag="${1:-}"
  local version today tmp
  [[ -n "$tag" ]] || die "finalize requires a tag"
  version="${tag#v}"
  today="$(date -u '+%Y-%m-%d')"
  grep -qE "^## \\[${version}\\] - Unreleased[[:space:]]*$" "$CHANGELOG_MD" \
    || die "CHANGELOG.md: missing [${version}] - Unreleased"
  tmp="$(mktemp)"
  awk -v version="$version" -v today="$today" '
    $0 ~ ("^## \\[" version "\\] - Unreleased[[:space:]]*$") {
      print "## [Unreleased]"
      print ""
      print "## [" version "] - " today
      next
    }
    { print }
  ' "$CHANGELOG_MD" > "$tmp"
  mv "$tmp" "$CHANGELOG_MD"
  echo "Finalized ${version} in CHANGELOG.md"
}

usage() {
  cat <<EOF
Usage:
  $(basename "$0") version
  $(basename "$0") notes
  $(basename "$0") finalize TAG
EOF
}

main() {
  [[ $# -ge 1 ]] || {
    usage >&2
    exit 1
  }
  case "$1" in
    version) cmd_version ;;
    notes) cmd_notes ;;
    finalize)
      [[ $# -ge 2 ]] || die "Usage: $(basename "$0") finalize TAG"
      cmd_finalize "$2"
      ;;
    -h|--help) usage ;;
    *) die "Unknown command: $1" ;;
  esac
}

main "$@"
