#!/usr/bin/env bash
# Android packages build the library. Tests, examples, demos, and docs stay off.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
android="$ROOT/cross/android.cross"
extra="$ROOT/cross/extra.cross"

require() {
  local file=$1 text=$2
  if ! grep -qxF "$text" "$file"; then
    echo "missing from $file: $text" >&2
    exit 1
  fi
}

require "$extra" "tests = false"
require "$extra" "conformance = false"
require "$extra" "installed_tests = false"
require "$extra" "vapi = 'disabled'"
require "$android" "docs = false"
require "$android" "build-examples = false"
require "$android" "build-testsuite = false"
require "$android" "demos = 'disabled'"
require "$android" "gpu_demo = 'disabled'"
require "$android" "thumbnailer = 'disabled'"
require "$android" "examples = false"

echo "library options: ok"
