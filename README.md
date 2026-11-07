# pixiewood-pkgs

Prebuilt Android sysroots for the GTK stack an application such as
[OLLMchat](https://github.com/roojs/OLLMchat) links, plus the Pixiewood changes
that consume those sysroots instead of compiling every library from source.

Pixiewood (`gtk-android-builder`) currently writes Meson wraps for GLib, GTK,
libadwaita, and the rest, then builds them inside the application. That is the
slow part of an OLLMchat Android APK. This repository builds that stack once
per ABI and publishes it as a tarball.

## What a release contains

One tarball per Android ABI, named
`pixiewood-android-sysroot-<version>-<abi>.tar.xz`. The `ollmchat` profile
matches the libraries the remote-chat APK links:

- GLib (with the `g_set_user_dirs` hack), fontconfig, HarfBuzz, Pango, Cairo,
  gdk-pixbuf, GTK (Android backend plus the OLLMchat `android-bugs` patch),
  libadwaita, GtkSourceView
- libxml2, sqlite, libgee, json-glib, nghttp2, libpsl, libsoup, OpenSSL
- static glib-networking OpenSSL backend (`gioopenssl`)
- webkitgtk-android

The tree is a Meson prefix (`prefix=/`, `libdir=lib/<abi>`):

| Path | Role |
| --- | --- |
| `lib/<abi>/*.so` | Shared libraries Gradle packages from `jniLibs` |
| `lib/<abi>/gio/modules/libgioopenssl.a` | Static TLS backend the app links |
| `lib/<abi>/pkgconfig/*.pc` | Development files for `dependency()` |
| `include/` | Headers |
| `share/glib-2.0/schemas/` | Schemas Pixiewood compiles into the APK |
| `share/pixiewood/gtk-android-java/` | Patched GTK Android Java glue |
| `share/pixiewood/MANIFEST.json` | Versions, ABI, and the dependency names the sysroot replaces |

Icons, the CA bundle, shared-mime-info, and the webkitgtk-android Java host
classes stay with the application. They are not part of this stack.

## Build a tarball

Host packages are the same ones OLLMchat's Android job uses (compilers, Meson,
Ninja, Vala, `glslc`, `sassc`, `nasm`, JDK is not required for the sysroot
itself). Then:

```bash
scripts/install-sdk.sh
scripts/build-sysroot.sh --arch aarch64
```

The tarball is written to `out/`. `--arch x86_64` builds the other ABI
Pixiewood knows. Pins and patches live in `stack/ollmchat/wraps/` and follow
OLLMchat's Android wraps (GLib 2.90.0, Pango 1.58.2, the `android-bugs` patch).
`stack/cross/` is the cross files from gtk-android-builder
`00b1862b6434a8778557dc3d3074f43f5fdead1b`. Fontconfig still tracks that
checkout's `main` wrap; the tarball is the artifact that freezes the result.

A push to `main` runs **Build Android sysroot** for aarch64 and attaches the tarball to the `v<version>` GitHub Release. **Build Android sysroot** can also be started by hand for `aarch64` or `x86_64`.

## Use a tarball

Extract it and bind pkg-config to that directory. Paths inside the `.pc` files
are rewritten to the extract location, so run this again if you move the tree:

```bash
tar -C "$HOME/pixiewood-sysroot" -xJf pixiewood-android-sysroot-0.1.0-arm64-v8a.tar.xz
scripts/activate-sysroot.sh "$HOME/pixiewood-sysroot"
```

How to point Pixiewood at the result, including the patch against
gtk-android-builder and the wrapper that works before that patch is merged, is
in [docs/pixiewood-sysroot.md](docs/pixiewood-sysroot.md).

## Tests

```bash
bash tests/test-sysroot-tree.sh
bash tests/test-pins-and-wrapper.sh
bash tests/test-pixiewood-patch.sh
```

These cover packing, activation, runtime staging, wrap pins, and the Pixiewood
patch. They do not cross-compile GTK.
