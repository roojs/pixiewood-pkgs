# pixiewood-pkgs

Prebuilt Android packages for the GTK stack [Pixiewood](https://github.com/sp1ritCS/gtk-android-builder) links. This is a distribution of those libraries, not an application profile. Each upstream project is its own package. A published index lists a URL for every package. Packages that did not change keep the URL of the earlier release. If nothing changed, no release is published.

## GTK targets

| Target | Source | What it tracks |
| --- | --- | --- |
| `ime` (default) | https://gitlab.gnome.org/Knowles/gtk.git | branch `android-ime` |
| `gnome` | https://gitlab.gnome.org/GNOME/gtk.git | pinned upstream commit, plus `packages/gtk/android-bugs.patch` |

`packages/gtk/targets` is the list. The IME branch is the Android input-method tree. Standard GTK stays available as `gnome`.

## Fetch a sysroot

`latest` reads the current index for one GTK target and downloads every package. `pin` uses one index file and does not look for a newer set.

```bash
scripts/integrate-sysroot.sh latest --gtk ime --dest "$HOME/pixiewood-sysroot"
scripts/integrate-sysroot.sh pin path/to/index.json --dest "$HOME/pixiewood-sysroot"
```

The default target is `ime`. `--gtk gnome` fetches the standard GTK set. Copy `share/pixiewood/INDEX.json` out of an assembled tree and pass it to `pin` to stay on that set.

The index URL for the moving release is:

`https://github.com/roojs/pixiewood-pkgs/releases/download/latest/index-<abi>-<gtk>.json`

Unchanged package entries in a new index still point at the tarball from the release that built them.

## What a package contains

Headers, shared libraries, pkg-config files, and GSettings schemas for one upstream project, installed with `prefix=/` and `libdir=lib/<abi>`. The `gtk` package also carries the Android Java glue. `glib-networking` carries the static `gioopenssl` module.

Other packages in the default set: GLib, fontconfig, GTK, libadwaita, GtkSourceView, libxml2, sqlite, libgee, json-glib, nghttp2, libpsl, libsoup, OpenSSL, and webkitgtk-android. Pango and HarfBuzz are built with GTK. Icons, the CA bundle, shared-mime-info, and application Java classes stay with the app.

## Build

```bash
scripts/install-sdk.sh
scripts/build-sysroot.sh --gtk ime --arch aarch64
scripts/build-sysroot.sh --gtk gnome --arch aarch64
```

`scripts/build-sysroot.sh --only gtk --gtk ime` builds one package. Pins and Android patches live in `packages/`. Cross files live in `cross/`. NDK and API levels are in `distro.conf`.

A push does not publish packages. Once a day, **Monitor upstreams** resolves every package for `ime` and for `gnome`. It uploads tarballs only for packages whose upstream revision or local inputs changed, writes an index that reuses the previous URL for the rest, and skips the release entirely when nothing changed. **Build Android sysroot** can still be started by hand for one combined tree.

## Use the sysroot from Pixiewood

See [docs/pixiewood-sysroot.md](docs/pixiewood-sysroot.md).

## Tests

```bash
bash tests/test-sysroot-tree.sh
bash tests/test-pins-and-wrapper.sh
bash tests/test-pixiewood-patch.sh
bash tests/test-index.sh
```

These cover packing, activation, runtime staging, wrap pins, both GTK targets, and the index. They do not cross-compile GTK.
