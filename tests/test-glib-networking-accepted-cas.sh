#!/usr/bin/env bash
# Build the glib-networking wrap the way the Android sysroot enables it, then
# perform a TLS handshake against a server that sends a CertificateRequest.
# The client reads accepted-cas during certificate selection and frees the
# returned buffers. Those bytes must be the DER names the server advertised.
# This fails while the pinned OpenSSL backend keeps the pointer i2d_X509_NAME
# has already advanced.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAP="$ROOT/packages/glib-networking/glib-networking.wrap"
CROSS="$ROOT/cross/extra.cross"
HARNESS="$ROOT/tests/accepted-cas-handshake.c"

for cmd in curl tar sha256sum meson ninja pkg-config cc openssl; do
  command -v "$cmd" >/dev/null
done

grep -q "^default_library = 'static'" "$CROSS"
grep -q "^gnutls = 'disabled'" "$CROSS"
grep -q "^openssl = 'enabled'" "$CROSS"

wrap_field() {
  local key=$1
  awk -F '=' -v key="$key" '
    /^\[/ { section = $0 }
    section == "[wrap-file]" {
      name = $1
      gsub(/[[:space:]]/, "", name)
      if (name == key) {
        value = substr($0, index($0, "=") + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
        exit
      }
    }
  ' "$WRAP"
}

directory="$(wrap_field directory)"
source_url="$(wrap_field source_url)"
source_filename="$(wrap_field source_filename)"
source_hash="$(wrap_field source_hash)"
diff_files="$(wrap_field diff_files || true)"
patch_directory="$(wrap_field patch_directory || true)"
[ -n "$directory" ] && [ -n "$source_url" ] && [ -n "$source_hash" ]

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/$source_filename" "$source_url"
echo "$source_hash  $tmp/$source_filename" | sha256sum -c -
tar -C "$tmp" -xf "$tmp/$source_filename"
src="$tmp/$directory"
[ -d "$src" ]

if [ -n "$diff_files" ]; then
  IFS=',' read -r -a patches <<< "$diff_files"
  for patch in "${patches[@]}"; do
    patch="${patch#"${patch%%[![:space:]]*}"}"
    patch="${patch%"${patch##*[![:space:]]}"}"
    [ -n "$patch" ] || continue
    patch -p1 -d "$src" < "$ROOT/packages/glib-networking/$patch"
  done
fi

if [ -n "$patch_directory" ]; then
  cp -a "$ROOT/packages/glib-networking/$patch_directory/." "$src/"
fi

meson setup "$tmp/build" "$src" \
  --default-library=static \
  --buildtype=debug \
  -Dgnutls=disabled \
  -Dopenssl=enabled \
  -Dlibproxy=disabled \
  -Dgnome_proxy=disabled \
  -Denvironment_proxy=disabled \
  -Dinstalled_tests=false
ninja -C "$tmp/build" tls/openssl/libgioopenssl.a

cc -o "$tmp/accepted-cas-handshake" "$HARNESS" \
  $(pkg-config --cflags gio-2.0 openssl) \
  -Wl,--whole-archive "$tmp/build/tls/openssl/libgioopenssl.a" -Wl,--no-whole-archive \
  $(pkg-config --libs gio-2.0 gmodule-2.0 openssl) \
  -pthread

openssl req -x509 -newkey rsa:2048 -keyout "$tmp/server.key" -out "$tmp/server.pem" \
  -days 1 -nodes -subj /CN=localhost >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -keyout "$tmp/ca1.key" -out "$tmp/ca1.pem" \
  -days 1 -nodes -subj /CN=pixiewood-test-ca-one >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -keyout "$tmp/ca2.key" -out "$tmp/ca2.pem" \
  -days 1 -nodes -subj /CN=pixiewood-test-ca-two >/dev/null 2>&1

"$tmp/accepted-cas-handshake" tls12 "$tmp/server.pem" "$tmp/server.key" "$tmp/ca1.pem" "$tmp/ca2.pem"
"$tmp/accepted-cas-handshake" tls13 "$tmp/server.pem" "$tmp/server.key" "$tmp/ca1.pem" "$tmp/ca2.pem"
