# pixiewood-pkgs

Prebuilt Android packages for the GTK stack [Pixiewood](https://github.com/sp1ritCS/gtk-android-builder) links. This is a distribution of those libraries, not an application profile. Each upstream project is its own package. A published index lists a URL for every package. Packages that did not change keep the URL of the earlier release. If nothing changed, no release is published.

## GTK targets

| Target | Source | What it tracks |
| --- | --- | --- |
| `gnome` | https://gitlab.gnome.org/GNOME/gtk.git | pinned upstream commit, no Android patch |

`packages/gtk/targets` lists that one target. The Android IME branch and webkitgtk-android are separate distributions. [docs/plans.md](docs/plans.md) records that split. [docs/own-distribution.md](docs/own-distribution.md) is how an application checks out a distribution and downloads its `.pixie` bundles, and how another project publishes its own.

## Fetch a sysroot

`latest` reads `current.pins` and downloads the package tarballs named there. `pin` uses one index file and does not look for a newer set. [How releases work](docs/releases.md) explains the source archive, the package list, and the generated release file.

```bash
scripts/integrate-sysroot.sh latest --dest "$HOME/pixiewood-sysroot"
scripts/integrate-sysroot.sh pin path/to/index.json --dest "$HOME/pixiewood-sysroot"
```

The target is native GTK (`gnome`), with no Android patch. Copy `share/pixiewood/INDEX.json` out of an assembled tree and pass it to `pin` to stay on that set.

A publish is release `1.yymmddHHMMSS` in UTC, so several releases can land on the same day. 7 November 2026 at 00:00:00 UTC is `1.261107000000`. Each finished package is uploaded as a `.pixie` file named with its ABI, Android SDK, and upstream version, such as `openssl-arm64-v8a-android31-3.0.8.pixie`. A branch or a commit uses `snapshot` instead of a version. Its line in `current.pins` is committed before the next package starts. See [docs/releases.md](docs/releases.md).

## What a package contains

Headers, shared libraries, pkg-config files, and GSettings schemas for one upstream project, installed with `prefix=/` and `libdir=lib/<abi>`. The `gtk` package also carries the Android Java glue. `glib-networking` carries the static `gioopenssl` module.

Other packages in the set: GLib, fontconfig, GDK, GTK, libadwaita, GtkSourceView, libxml2, sqlite, libgee, json-glib, nghttp2, libpsl, libsoup, OpenSSL, Pango, Cairo, HarfBuzz, and the other libraries in `build-order.txt`. Icons, the CA bundle, shared-mime-info, and application Java classes stay with the app. webkitgtk-android and the Android IME branch are not in this set.

## Build

```bash
scripts/install-sdk.sh
scripts/build-sysroot.sh --arch aarch64
```

`scripts/build-sysroot.sh --only gtk` builds one package of native GTK. Pins live in `packages/`. Cross files live in `cross/`. NDK and API levels are in `android-distro.conf`.

A push does not publish packages. Once a day, **Monitor upstreams** resolves every package for each name in `packages/gtk/targets`. It uploads tarballs only for packages whose upstream revision or local inputs changed, writes an index that reuses the previous URL for the rest, and skips the release entirely when nothing changed. **Build Android sysroot** can still be started by hand for one combined tree.

**Prove package** walks `build-order.txt` through `glib-networking` and publishes each package as soon as it finishes. A later failure leaves the finished packages on that run's release, and the next run downloads them. Each package is taken from `current.pins` when that package's recipe has not changed, otherwise from the GitHub package cache, and otherwise built from source. A cache hit or a source build is uploaded too, so the pin names a real asset. Pango, Cairo, HarfBuzz, and the other GTK libraries are packages in that list, so a GTK build links those tarballs. A source build reuses a stored checkout when it is already at the wanted revision. Set `through` to an earlier name, such as `libadwaita`, to stop there. **Monitor upstreams** uses the same rule: a package is uploaded when its tarball exists, and a later failure does not drop the packages already uploaded. **Build Android sysroot** uses the same order. Pass `packages=sqlite3` to prove that package alone.

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
