# What this distro builds, and what other projects release

The GNOME Android stack through GTK is proved as packages in this repository. The packages after GTK, and the Android IME branch of GTK, raise a different question: this repository can keep compiling them, or those projects can publish their own tarballs with a small toolkit from here.

## What stays in this repository

This repository is the distribution of the shared Android libraries an app links: OpenSSL through GTK in `build-order.txt`, for the `gnome` target. That includes Pango, Cairo, HarfBuzz, GDK, and GTK from upstream GNOME. Those projects do not publish an Android sysroot package. The dated release `1.yymmdd` holds the `.pixie` bundles. `current.pins` in git names that release.

The next run is **Prove package** for `gnome` and aarch64, through `glib-networking`. It reuses the package cache and builds what that cache does not already match, including GDK and GTK after the Android header install, then libadwaita, GtkSourceView, libsoup, and glib-networking. **Monitor upstreams** publishes the release after that prove is green.

## What other projects can release themselves

`Knowles.android-ime` and `webkitgtk-android` are not packages in this repository. Their Android package is built in the project that owns the code and uploaded to that project's releases.

- The Android IME branch lives at `Knowles/gtk` branch `android-ime`. A workflow there can build the `gdk` and `gtk` packages against a pixiewood-pkgs sysroot and upload `gdk-*.pixie` and `gtk-*.pixie`.
- webkitgtk-android lives at `roojs/webkitgtk-android`. A workflow there can build that one package and upload its `.pixie` bundle.

This repository's `current.pins` names the release that holds each `.pixie` bundle for the GNOME stack. It does not name the IME target or webkitgtk-android. [How to implement your own distribution](own-distribution.md) is the checkout, pin, and release layout.

`packages/gtk/targets` lists `gnome` only. `build-order.txt` ends at glib-networking.

## Release or main

`gnome` is the reference target for the shared libraries. A pin line records the channel in one column: `release` or `main`.

| Channel | Release name in the pin | Bundle |
| --- | --- | --- |
| `release` | `1.yymmdd`, the dated GitHub release | `{name}-{abi}-gnome.pixie` on that release |
| `main` | `main`, the moving GitHub release | the same file name on the `main` release |

GNOME GTK in a distro release stays on the proved commit. A package that follows a branch tip uses channel `main`. An app that wants a frozen set reads the `release` lines. An app that wants a tip reads the `main` lines and, for any package that has no `main` line, uses the `release` line.
