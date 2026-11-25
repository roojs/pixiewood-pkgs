#!/usr/bin/env bash
# Spec for versioned .pixie artifacts.
# These checks fail while a release asset can be replaced at the URL recorded
# in the pin file and a later download still accepts the new bytes.
#
# The pin must store sha256 of the uploaded .pixie (packages[].sha256, lowercase
# hex, no prefix). That digest is of the archive bytes, not the upstream source
# hash in .resolved and not the recipe hash in .inputs.
# A second publish of a versioned asset must leave the first bytes in place.
# After an out-of-band replacement of those bytes, prove-package and
# build-changed must not keep or unpack the replacement. A download that is
# checked and then fetched again must not unpack the second body either: the
# local release server swaps in a different archive after the first full GET.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

repo="fixture/pixiewood-pkgs"
abi="arm64-v8a"
good_marker="GOOD_OPENSSL_MARKER"
bad_marker="BACKDOOR_OPENSSL_MARKER"
race_marker="RACE_OPENSSL_MARKER"
pixie_sha="9185866330e0d463b54be54b6343880ee4593c55"
failures=0

note() {
  printf '%s\n' "$*" >&2
}

fail() {
  note "FAIL: $*"
  failures=$((failures + 1))
}

make_pixie() {
  local dest=$1 marker=$2
  local dir="$tmp/tree-$marker"
  rm -rf "$dir"
  mkdir -p "$dir/lib/$abi/pkgconfig" "$dir/lib/$abi"
  printf '%s\n' 'prefix=/' 'Name: OpenSSL' 'Version: 3.0.8' > "$dir/lib/$abi/pkgconfig/openssl.pc"
  printf '%s\n' 'prefix=/' 'Name: OpenSSL-libssl' 'Version: 3.0.8' > "$dir/lib/$abi/pkgconfig/libssl.pc"
  printf '%s\n' 'prefix=/' 'Name: OpenSSL-libcrypto' 'Version: 3.0.8' > "$dir/lib/$abi/pkgconfig/libcrypto.pc"
  printf '%s\n' "$marker" > "$dir/lib/$abi/libssl.so"
  printf 'crypto\n' > "$dir/lib/$abi/libcrypto.so"
  tar -C "$dir" -cJf "$dest" .
}

file_sha() {
  sha256sum "$1" | awk '{ print $1 }'
}

# gh 2.103.0 deletes an existing asset and uploads the new bytes when --clobber
# is set. Without it, upload fails and the existing asset stays.
# pkg/cmd/release/upload/upload.go and pkg/cmd/release/shared/upload.go.
mkdir -p "$tmp/bin" "$tmp/store" "$tmp/home"
cat > "$tmp/bin/gh" << 'EOF'
#!/usr/bin/env python3
import os, shutil, sys
from pathlib import Path

store = Path(os.environ["RELEASE_STORE"])
log = Path(os.environ["GH_LOG"])
args = sys.argv[1:]
with log.open("a") as fh:
    fh.write(" ".join(args) + "\n")
if len(args) < 2 or args[0] != "release":
    sys.stderr.write("unsupported gh command\n")
    sys.exit(2)
cmd = args[1]
rest = args[2:]
positional = []
flags = {}
i = 0
while i < len(rest):
    item = rest[i]
    if item == "--clobber":
        flags["clobber"] = "1"
        i += 1
        continue
    if item.startswith("--"):
        key = item[2:]
        if i + 1 < len(rest) and not rest[i + 1].startswith("--"):
            flags[key] = rest[i + 1]
            i += 2
        else:
            flags[key] = "1"
            i += 1
        continue
    positional.append(item)
    i += 1
if not positional or "repo" not in flags:
    sys.stderr.write("gh release needs a tag and --repo\n")
    sys.exit(2)
tag = positional[0]
files = positional[1:]
dest_dir = store.joinpath(*flags["repo"].split("/"), tag)

def names():
    return [os.path.basename(path) for path in files]

if cmd == "view":
    sys.exit(0 if dest_dir.is_dir() else 1)
if cmd not in ("upload", "create"):
    sys.stderr.write("unsupported gh release command\n")
    sys.exit(2)
if cmd == "upload" and not dest_dir.is_dir():
    sys.stderr.write("release not found\n")
    sys.exit(1)
existing = []
if dest_dir.is_dir():
    for name in names():
        if (dest_dir / name).exists():
            existing.append(name)
if existing and flags.get("clobber") != "1":
    sys.stderr.write("asset under the same name already exists: %s\n" % existing)
    sys.exit(1)
if cmd == "create" and dest_dir.is_dir():
    sys.stderr.write("release already exists\n")
    sys.exit(1)
dest_dir.mkdir(parents=True, exist_ok=True)
for name in existing:
    (dest_dir / name).unlink()
for path in files:
    shutil.copyfile(path, dest_dir / os.path.basename(path))
sys.exit(0)
EOF
chmod 0755 "$tmp/bin/gh"

cat > "$tmp/bin/curl" << 'EOF'
#!/usr/bin/env bash
real="/usr/bin/curl"
rewritten=()
for arg in "$@"; do
  case "$arg" in
    https://github.com/*/releases/download/*)
      path="${arg#https://github.com}"
      arg="http://127.0.0.1:${RELEASE_PORT}${path}"
      ;;
  esac
  rewritten+=("$arg")
done
exec "$real" "${rewritten[@]}"
EOF
chmod 0755 "$tmp/bin/curl"

cat > "$tmp/server.py" << 'EOF'
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

store = Path(os.environ["RELEASE_STORE"])

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        parts = [item for item in path.split("/") if item]
        # /owner/repo/releases/download/tag/name
        if len(parts) != 6 or parts[2:4] != ["releases", "download"]:
            self.send_error(404)
            return
        owner, repo, tag, name = parts[0], parts[1], parts[4], parts[5]
        asset = store / owner / repo / tag / name
        if not asset.is_file():
            self.send_error(404)
            return
        data = asset.read_bytes()
        start = 0
        end = len(data) - 1
        status = 200
        ranged = False
        header = self.headers.get("Range")
        if header and header.startswith("bytes="):
            spec = header.split("=", 1)[1].split(",", 1)[0]
            left, _, right = spec.partition("-")
            if left != "":
                start = int(left)
            if right != "":
                end = int(right)
            end = min(end, len(data) - 1)
            status = 206
            ranged = True
        body = data[start:end + 1] if data else b""
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "application/octet-stream")
        if ranged:
            self.send_header("Content-Range", "bytes %s-%s/%s" % (start, end, len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        if ranged:
            return
        race = asset.with_name(asset.name + ".race")
        if race.is_file():
            asset.write_bytes(race.read_bytes())
            race.unlink()

    def log_message(self, fmt, *args):
        return

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.environ["PORT_FILE"], "w") as fh:
    fh.write(str(server.server_address[1]))
server.serve_forever()
EOF
PORT_FILE="$tmp/port" RELEASE_STORE="$tmp/store" python3 "$tmp/server.py" > "$tmp/server.log" 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if [ -s "$tmp/port" ]; then
    break
  fi
  sleep 0.1
done
port="$(cat "$tmp/port")"
export RELEASE_STORE="$tmp/store" RELEASE_PORT="$port" GH_LOG="$tmp/gh.log" HOME="$tmp/home"
export PATH="$tmp/bin:$PATH"
unset GITHUB_SHA RELEASE_SHA GH_TOKEN GITHUB_TOKEN PROVE_PUBLISH || true

git clone --quiet https://github.com/roojs/pixie-pkg.git "$tmp/pixie-src"
git -C "$tmp/pixie-src" checkout --quiet "$pixie_sha"
PREFIX="$tmp/pixie-prefix" "$tmp/pixie-src/scripts/install-local.sh" > "$tmp/pixie-install.out"
export PATH="$tmp/bin:$tmp/pixie-prefix/bin:$PATH"

make_pixie "$tmp/good.pixie" "$good_marker"
make_pixie "$tmp/bad.pixie" "$bad_marker"
make_pixie "$tmp/race.pixie" "$race_marker"
good_hash="$(file_sha "$tmp/good.pixie")"
bad_hash="$(file_sha "$tmp/bad.pixie")"
race_hash="$(file_sha "$tmp/race.pixie")"
source_hash="6c13d2bf38fdf31eac3ce2a347073673f5d63263398f1f69d0df4a41253e4b3e"
inputs_hash="fe298dadd882c42a4809283f6f872a9ecb88594edb6802338290380720548c99"

rm -f "$tmp/pins"
if ! "$ROOT/scripts/publish-package.sh" \
  --name openssl \
  --tarball "$tmp/good.pixie" \
  --arch aarch64 \
  --gtk gnome \
  --track openssl-3.0.8.tar.gz \
  --resolved "$source_hash" \
  --inputs "$inputs_hash" \
  --created 2026-11-08T01:02:03Z \
  --repo "$repo" \
  --file "$tmp/pins" > "$tmp/publish.out" 2> "$tmp/publish.err"; then
  note "publish of the first openssl archive failed"
  cat "$tmp/publish.err" >&2
  exit 1
fi
tag="1.261108"
asset="openssl-arm-v31-3.0.8.pixie"
stored="$tmp/store/fixture/pixiewood-pkgs/$tag/$asset"
if [ ! -f "$stored" ] || [ "$(file_sha "$stored")" != "$good_hash" ]; then
  note "first publish did not store the archive bytes"
  exit 1
fi
pin_sha="$(jq -r '.packages[] | select(.name == "openssl") | .sha256 // empty' "$tmp/pins")"
if [ "$pin_sha" != "$good_hash" ]; then
  fail "pin sha256 is '$pin_sha', not the sha256 of the uploaded .pixie ($good_hash)"
fi
if jq -e --arg resolved "$source_hash" '.packages[] | select(.name == "openssl" and .sha256 == $resolved)' "$tmp/pins" >/dev/null; then
  fail "pin sha256 repeats the upstream source hash"
fi
cp "$tmp/pins" "$tmp/pins-published"

make_pixie "$tmp/second.pixie" "SECOND_PUBLISH_MARKER"
second_hash="$(file_sha "$tmp/second.pixie")"
if "$ROOT/scripts/publish-package.sh" \
  --name openssl \
  --tarball "$tmp/second.pixie" \
  --arch aarch64 \
  --gtk gnome \
  --track openssl-3.0.8.tar.gz \
  --resolved "$source_hash" \
  --inputs "$inputs_hash" \
  --created 2026-11-08T01:02:03Z \
  --repo "$repo" \
  --file "$tmp/pins" > "$tmp/republish.out" 2> "$tmp/republish.err"; then
  fail "publishing a different archive over a versioned asset succeeded"
else
  note "second publish-package exited $(wc -c < "$tmp/republish.err" | tr -d ' ') bytes of stderr"
fi
if [ "$(file_sha "$stored")" != "$good_hash" ]; then
  fail "versioned asset bytes changed on a second publish ($(file_sha "$stored"))"
fi
cp "$tmp/pins-published" "$tmp/pins"
cp "$tmp/bad.pixie" "$stored"
cp "$tmp/race.pixie" "$stored.race"

# publish-index uploads the same way, with --clobber, and does not rewrite the pin.
index_dir="$tmp/index-tarballs"
mkdir -p "$index_dir"
cp "$tmp/good.pixie" "$index_dir/openssl-${abi}.tar.xz"
cat > "$tmp/index-plan.tsv" << EOF
# publish=1
# build=1
# gtk_target=gnome
build	openssl	file	openssl-3.0.8.tar.gz	$source_hash	$inputs_hash	-
EOF
if ! "$ROOT/scripts/publish-index.sh" \
  --plan "$tmp/index-plan.tsv" \
  --tarball-dir "$index_dir" \
  --arch aarch64 \
  --gtk gnome \
  --repo "$repo" \
  --created 2026-11-10T00:00:00Z > "$tmp/index.out" 2> "$tmp/index.err"; then
  note "first publish-index failed"
  cat "$tmp/index.err" >&2
  exit 1
fi
index_asset="$tmp/store/fixture/pixiewood-pkgs/1.261110/$asset"
if [ ! -f "$index_asset" ] || [ "$(file_sha "$index_asset")" != "$good_hash" ]; then
  note "publish-index did not store the first archive"
  exit 1
fi
cp "$tmp/bad.pixie" "$index_dir/openssl-${abi}.tar.xz"
if "$ROOT/scripts/publish-index.sh" \
  --plan "$tmp/index-plan.tsv" \
  --tarball-dir "$index_dir" \
  --arch aarch64 \
  --gtk gnome \
  --repo "$repo" \
  --created 2026-11-10T00:00:00Z > "$tmp/index2.out" 2> "$tmp/index2.err"; then
  fail "publish-index replaced a versioned asset"
fi
if [ "$(file_sha "$index_asset")" != "$good_hash" ]; then
  fail "publish-index left replacement bytes at the versioned asset"
fi

prove_out="$tmp/prove-out"
mkdir -p "$prove_out"
set +e
"$ROOT/scripts/prove-package.sh" \
  --arch aarch64 \
  --gtk gnome \
  --packages openssl \
  --pins "$tmp/pins-published" \
  --cache "$tmp/empty-cache" \
  --out "$prove_out" > "$tmp/prove.out" 2> "$tmp/prove.err"
prove_status=$?
set -e
proved="$prove_out/openssl-${abi}.tar.xz"
if ! grep -qx 'pin openssl alone' "$tmp/prove.out"; then
  note "prove did not select the release pin"
  cat "$tmp/prove.out" >&2
  cat "$tmp/prove.err" >&2
  exit 1
fi
if [ -f "$proved" ] && [ "$(file_sha "$proved")" != "$good_hash" ]; then
  fail "prove-package kept openssl bytes $(file_sha "$proved")"
elif [ "$prove_status" -eq 0 ] && { [ ! -f "$proved" ] || [ "$(file_sha "$proved")" != "$good_hash" ]; }; then
  fail "prove-package accepted the release pin without the published archive"
fi

builder="$tmp/bin/record-build"
cat > "$builder" << EOF
#!/usr/bin/env bash
set -euo pipefail
tarball=""
sysroot=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --tarball) tarball=\$2; shift 2 ;;
    --deps-sysroot) sysroot=\$2; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$tmp"
if [ -n "\$sysroot" ] && grep -R -a -q -e '$bad_marker' -e '$race_marker' "\$sysroot"; then
  printf '%s\n' "\$sysroot" > "$tmp/poisoned-files"
fi
if [ -n "\$tarball" ]; then
  mkdir -p "\$(dirname "\$tarball")"
  printf 'built\n' > "\$tarball"
fi
EOF
chmod 0755 "$builder"

plan="$tmp/build-plan.tsv"
{
  printf '%s\n' '# publish=0' '# build=1' '# gtk_target=gnome'
  while IFS= read -r name || [ -n "$name" ]; do
    name=${name%%#*}
    name=${name#"${name%%[![:space:]]*}"}
    name=${name%"${name##*[![:space:]]}"}
    [ -n "$name" ] || continue
    case "$name" in
      openssl)
        printf 'keep\topenssl\tfile\topenssl-3.0.8.tar.gz\t%s\t%s\t%s\n' \
          "$source_hash" "$inputs_hash" \
          "https://github.com/${repo}/releases/download/${tag}/${asset}"
        ;;
      libxml2)
        printf 'build\tlibxml2\tfile\tlibxml2-2.15.3.tar.xz\t%s\t%s\t-\n' \
          "78262a6e7ac170d6528ebfe2efccdf220191a5af6a6cd61ea4a9a9a5042c7a07" \
          "b723790d91d908a29f7d7ecadd715ff2afd261bc265db18266ee841148c06ee9"
        ;;
      *)
        printf 'keep\t%s\tfile\tkept\tkept\tkept\tfile://%s/good.pixie\n' "$name" "$tmp"
        ;;
    esac
  done < "$ROOT/build-order.txt"
} > "$plan"
: > "$tmp/poisoned-files"
set +e
BUILD_PIXIE="$builder" "$ROOT/scripts/build-changed.sh" \
  --plan "$plan" \
  --arch aarch64 \
  --gtk gnome \
  --tarball-dir "$tmp/built" > "$tmp/build.out" 2> "$tmp/build.err"
build_status=$?
set -e
if [ -s "$tmp/poisoned-files" ]; then
  fail "build-changed unpacked the replaced openssl into the dependency sysroot"
fi
if [ "$build_status" -eq 0 ] && ! grep -qx 'build libxml2' "$tmp/build.out"; then
  fail "build-changed did not reach the package that links openssl"
fi

if [ "$failures" -ne 0 ]; then
  note "mutable release asset: $failures check(s) failed"
  note "--- publish stderr ---"
  cat "$tmp/publish.err" >&2 || true
  note "--- republish stderr ---"
  cat "$tmp/republish.err" >&2 || true
  note "--- prove stdout ---"
  cat "$tmp/prove.out" >&2 || true
  note "--- prove stderr ---"
  cat "$tmp/prove.err" >&2 || true
  note "--- build-changed stdout ---"
  cat "$tmp/build.out" >&2 || true
  note "--- build-changed stderr ---"
  cat "$tmp/build.err" >&2 || true
  exit 1
fi

echo "mutable release asset: ok"
