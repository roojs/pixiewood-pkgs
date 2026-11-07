# pixiewood-pkgs

Prebuilt Android packages for the GTK stack [Pixiewood](https://github.com/sp1ritCS/gtk-android-builder) links. This is a distribution of those libraries, not an application profile. Each upstream project is its own package. A published index lists a URL for every package. Packages that did not change keep the URL of the earlier release. If nothing changed, no release is published.

## GTK targets

| Target | Source | What it tracks |
| --- | --- | --- |
| `gnome` (default) | https://gitlab.gnome.org/GNOME/gtk.git | pinned upstream commit, no Android patch |
| `Knowles.android-ime` | https://gitlab.gnome.org/Knowles/gtk.git | branch `android-ime` |

`packages/gtk/targets` is the list. A branch target is named `owner.branch`, so another fork is another line. Native GTK stays the default and is built as upstream publishes it. Android fixes come from `Knowles.android-ime`.

## Fetch a sysroot

`latest` reads `current.pins` and downloads the index named there. `pin` uses one index file and does not look for a newer set. [How releases work](docs/releases.md) explains the source archive, `current.pins`, and the generated release file.

```bash
scripts/integrate-sysroot.sh latest --dest "$HOME/pixiewood-sysroot"
scripts/integrate-sysroot.sh latest --gtk Knowles.android-ime --dest "$HOME/pixiewood-sysroot"
scripts/integrate-sysroot.sh pin path/to/index.json --dest "$HOME/pixiewood-sysroot"
```

The default target is native GTK (`gnome`), with no Android patch. `--gtk Knowles.android-ime` fetches that owner and branch, which is where the Android fixes live. Copy `share/pixiewood/INDEX.json` out of an assembled tree and pass it to `pin` to stay on that set.

A day that publishes packages is release `1.yymmdd` in UTC. 7 November 2026 is `1.261107`. See [docs/releases.md](docs/releases.md).

## What a package contains

Headers, shared libraries, pkg-config files, and GSettings schemas for one upstream project, installed with `prefix=/` and `libdir=lib/<abi>`. The `gtk` package also carries the Android Java glue. `glib-networking` carries the static `gioopenssl` module.

Other packages in the default set: GLib, fontconfig, GTK, libadwaita, GtkSourceView, libxml2, sqlite, libgee, json-glib, nghttp2, libpsl, libsoup, OpenSSL, and webkitgtk-android. Pango and HarfBuzz are built with GTK. Icons, the CA bundle, shared-mime-info, and application Java classes stay with the app.

## Build

```bash
scripts/install-sdk.sh
scripts/build-sysroot.sh --arch aarch64
scripts/build-sysroot.sh --gtk Knowles.android-ime --arch aarch64
```

`scripts/build-sysroot.sh --only gtk` builds one package of native GTK. `--gtk Knowles.android-ime` selects that owner and branch. Pins live in `packages/`. Cross files live in `cross/`. NDK and API levels are in `android-distro.conf`.

A push does not publish packages. Once a day, **Monitor upstreams** resolves every package for each name in `packages/gtk/targets`. It uploads tarballs only for packages whose upstream revision or local inputs changed, writes an index that reuses the previous URL for the rest, and skips the release entirely when nothing changed. **Build Android sysroot** can still be started by hand for one combined tree.

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
