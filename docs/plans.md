# What this distro builds, and what other projects release

The GNOME Android stack through GTK is proved as packages in this repository. The packages after GTK, and the Android IME branch of GTK, raise a different question: this repository can keep compiling them, or those projects can publish their own tarballs with a small toolkit from here.

## What stays in this repository

This repository is the distribution of the shared Android libraries an app links: OpenSSL through GTK in `build-order.txt`, for the `gnome` target. That includes Pango, Cairo, HarfBuzz, GDK, and GTK from upstream GNOME. Those projects do not publish an Android sysroot package. The dated release `1.yymmdd` and `current.pins` are the list of tarball URLs for that set.

A hand-started **Build Android sysroot** for `gnome` and aarch64 is the next build. It reuses the proved tarballs and compiles the packages that prove did not reach: libadwaita, GtkSourceView, libsoup, glib-networking, and webkitgtk-android. Those five stay here until the projects below publish their own packages.

## What other projects can release themselves

`Knowles.android-ime` and `webkitgtk-android` are forks we maintain. Their Android package can be built in the project that owns the code and uploaded to that project's releases.

- The Android IME branch lives at `Knowles/gtk` branch `android-ime`. A workflow there can build the `gdk` and `gtk` packages against a pixiewood-pkgs sysroot and upload `gdk-*.tar.xz` and `gtk-*.tar.xz`.
- webkitgtk-android lives at `roojs/webkitgtk-android`, currently wrap revision `v0.1.5`. A workflow there can build that one package and upload its tarball.

This repository then lists those URLs in `current.pins` the same way it lists a tarball built here. `scripts/integrate-sysroot.sh` already downloads whatever URL a pin line names. The IME target in `packages/gtk/targets` and the webkit wrap stay as the record of which revision the distro release uses. The compile moves to the project.

The toolkit those workflows need is the part of this repository that is not the GNOME package list:

- `cross/` and `android-distro.conf` for the NDK, API, prefix `/`, and `lib/<abi>`
- `scripts/build-sysroot.sh --only` against a dependency sysroot from `current.pins`
- the tarball layout from `scripts/sysroot-tree.sh`, so pkg-config files use `@PIXIEWOOD_SYSROOT@`
- one pin line: abi, gtk target, release, name, track, resolved revision, inputs, URL

Until those workflows exist, this repository keeps building the IME target and webkitgtk-android. Adding the toolkit to the other repository comes after the GNOME sysroot build, because that build is what their workflow consumes.

## Release or main

A project chooses which upstream revision a package is built from. The distro release records that choice. An app chooses which distro list to download.

Two tracks are enough:

| Track | What is built | Who selects it |
| --- | --- | --- |
| release | A tag or a pinned commit. OpenSSL `3.0.8`, webkitgtk-android `v0.1.5`, GNOME GTK `ae709f96`. | `current.pins` for `1.yymmdd`, and `integrate-sysroot.sh pin` for one saved index. |
| main | The default branch tip (`main`, or `android-ime` for the IME fork). | A separate list, published only for projects that opt in. |

`gnome` stays on a pinned commit in a distro release. Tracking GNOME `main` for GTK rebuilds the whole stack every time that commit moves, and the proved packages are a specific commit. A project that wants the tip publishes a `main` tarball from its own workflow and the distro can carry a second pins file for that track.

An app build picks one list:

- a dated release, when the app wants the set that was proved
- the `main` list, when the app wants the tip of a project that publishes one

Both lists use the same tarball layout. A package with no `main` build is taken from the dated release even when the app asked for the `main` list.
