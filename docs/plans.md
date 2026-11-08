# What this distro builds, and what other projects release

The GNOME Android stack through GTK is proved as packages in this repository. The packages after GTK, and the Android IME branch of GTK, raise a different question: this repository can keep compiling them, or those projects can publish their own tarballs with a small toolkit from here.

## What stays in this repository

This repository is the distribution of the shared Android libraries an app links: OpenSSL through GTK in `build-order.txt`, for the `gnome` target. That includes Pango, Cairo, HarfBuzz, GDK, and GTK from upstream GNOME. Those projects do not publish an Android sysroot package. The release `1.yymmdd` holds the `.pixie` packages. `current.pins` in git names that release.

**Prove package** for `gnome` and aarch64, through `glib-networking`, publishes each package when it finishes. A later failure leaves the finished packages on the release. The next run downloads those pins and continues from the package that failed.

## What other projects can release themselves

`Knowles.android-ime` and `webkitgtk-android` are not packages in this repository. Their Android package is built in the project that owns the code and uploaded to that project's releases.

- The Android IME branch lives at `Knowles/gtk` branch `android-ime`. A workflow there can build the `gdk` and `gtk` packages against a pixiewood-pkgs sysroot and upload `gdk-*.pixie` and `gtk-*.pixie`.
- webkitgtk-android lives at `roojs/webkitgtk-android`. A workflow there can build that one package and upload its `.pixie` bundle.

This repository's `current.pins` names the release that holds each `.pixie` bundle for the GNOME stack. It does not name the IME target or webkitgtk-android. [How to implement your own distribution](own-distribution.md) is the checkout, pin, and release layout.

`packages/gtk/targets` lists `gnome` only. `build-order.txt` ends at glib-networking.

## Release or snapshot

`gnome` is the reference target for the shared libraries. The package file names the upstream release version. A branch or a commit is `snapshot`.

| What was built | Bundle |
| --- | --- |
| Upstream release `3.0.8` | `{name}-arm-v31-3.0.8.pixie` |
| A branch tip or a commit | `{name}-arm-v31-snapshot.pixie` |

The GitHub release that holds the file is still `1.yymmdd`. `snapshot` is the file name for a tip, in place of `main` or `head`.
