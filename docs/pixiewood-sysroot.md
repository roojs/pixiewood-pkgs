# Using a pixiewood-pkgs sysroot from Pixiewood

Pixiewood builds every library named in the manifest as a Meson subproject,
then `meson install --tags runtime` copies those libraries into
`.pixiewood/root`. Gradle packages `root/lib/<abi>/*.so`, and Pixiewood
compiles `root/share/glib-2.0/schemas` into the APK assets. The GTK Java glue
is symlinked from `subprojects/gtk/gdk/android/glue/java`.

A prebuilt sysroot replaces the subproject build. Three things still have to
happen, because Meson does not install external pkg-config dependencies and
the glue is not inside a wrap anymore:

1. `dependency('gtk4')` and the other names must resolve to the sysroot `.pc`
   files, without the NDK sysroot being prepended to those paths.
2. `lib/<abi>` and `share/glib-2.0/schemas` from the tarball must be copied
   into `.pixiewood/root` after the app install and before Gradle.
3. `java-sources` must point at `share/pixiewood/gtk-android-java` in the
   extracted tree (that directory contains `org/gtk/android`).

Fetch a set first. `latest` follows native GTK (`gnome`), which is upstream
GNOME with no Android patch. `pin` keeps a single index file:

```bash
scripts/integrate-sysroot.sh latest --dest "$HOME/pixiewood-sysroot"
scripts/integrate-sysroot.sh pin path/to/index.json --dest "$HOME/pixiewood-sysroot"
```

`latest` reads `current.pins` and downloads each package tarball named
there, including earlier release URLs for packages that did not change.
The fetch then activates the tree. See [releases.md](releases.md).
`scripts/activate-sysroot.sh` rewrites `prefix=@PIXIEWOOD_SYSROOT@` in the
`.pc` files and writes `share/pixiewood/sysroot.cross`.

## Patch Pixiewood

`integration/0001-sysroot-prebuilt-dependencies.patch` applies to
gtk-android-builder `00b1862b6434a8778557dc3d3074f43f5fdead1b` (the revision
in `android-distro.conf`). From a checkout of that revision:

```bash
patch -p1 < /path/to/pixiewood-pkgs/integration/0001-sysroot-prebuilt-dependencies.patch
```

`pixiewood prepare` gains `--sysroot DIR`. DIR is the activated tree.

- The manifest's `provided_dependencies` list is read from
  `share/pixiewood/MANIFEST.json`. Each listed dependency is not written as a
  wrap, and an existing `subprojects/<name>.wrap` for it is removed.
- `meson setup` gets a last extra `--cross-file` of
  `share/pixiewood/sysroot.cross`. That file sets `pkg-config` to a wrapper
  which clears `PKG_CONFIG_SYSROOT_DIR`. Pixiewood's own `android.cross` still
  supplies the NDK `sys_root`; overriding that with the GTK prefix would hide
  libc.
- The path is stored in `.pixiewood/pixiewood.ini`.
- `generate` uses the sysroot Java glue when the manifest does not set
  `java-sources`.
- `build`, after `meson install`, copies `lib/<abi>` and the GSettings schemas
  into `.pixiewood/root` before the asset copy and `glib-compile-schemas`.

Prepare then looks like:

```bash
pixiewood prepare \
  --sdk "$ANDROID_SDK_ROOT" \
  --sysroot "$HOME/pixiewood-sysroot" \
  android/app.xml
pixiewood generate
pixiewood build
```

Dependencies the sysroot does not list are still built from wraps. An
application can keep a wrap for something that is not in the tarball.

## Without waiting for the patch

If the application passes `--meson` and reconfigures with its own cross file,
point that Meson at `scripts/meson-wrapper.sh` and set two variables:

```bash
export PIXIEWOOD_SYSROOT="$HOME/pixiewood-sysroot"
export PIXIEWOOD_REAL_MESON="$(command -v meson)"
pixiewood prepare \
  --sdk "$ANDROID_SDK_ROOT" \
  --meson /path/to/pixiewood-pkgs/scripts/meson-wrapper.sh \
  android/app.xml
```

The wrapper inserts `--cross-file $PIXIEWOOD_SYSROOT/share/pixiewood/sysroot.cross`
into `meson setup`. Stock Pixiewood still writes wraps. Meson prefers
pkg-config when the `.pc` file satisfies the dependency, so those wraps are
not compiled. Delete `subprojects/*.wrap` for the provided names if a version
check would otherwise fall back to building them.

If the application runs Meson a second time outside Pixiewood's `--meson`,
add the same `--cross-file` there and pass it on every reconfigure. A
reconfigure that omits the file drops the sysroot and Meson goes back to the
wraps. With the sysroot file last, its `glib-mkenums` entry overrides an
extra cross file's path into `subprojects/glib`.

Stock Pixiewood does not copy external libraries into `.pixiewood/root` and
does not know the Java glue path. Set the glue on the manifest `<build>`
element:

```xml
<build
  target="app"
  java-sources="/home/you/pixiewood-sysroot/share/pixiewood/gtk-android-java">
```

After `pixiewood build --skip-gradle` (or after its `meson install`) and
before Gradle:

```bash
scripts/stage-runtime.sh \
  "$PIXIEWOOD_SYSROOT" \
  /path/to/app/.pixiewood/root
```

That is the same copy the patch performs inside `build`. Schemas must be in
`.pixiewood/root/share/glib-2.0/schemas` before Pixiewood runs
`glib-compile-schemas`, so stage them before `pixiewood build` if you are not
using the patch. Staging libraries before `meson install` is safe: install
does not delete extra files already in the destdir.

## What the application changes

Dependencies listed in `MANIFEST.json` no longer need source wraps. The
application meson targets stay as they are: `dependency('gtk4')`,
`dependency('gioopenssl')`, and the others in this sysroot resolve through
pkg-config. The manifest's `gtk_target` is `gnome`. webkitgtk-android is a
separate distribution.

Stop pointing `glib-mkenums` at `subprojects/glib` once GLib is not a
subproject. The activated cross file uses the script from the sysroot when
that file is a host script. Drop the app's `android/pixiewood-extra.cross`
`glib-mkenums` line, or let `sysroot.cross` come last so it wins.

Keep the pieces this distro does not build: icon themes, shared-mime-info,
CA certificates, and the application's own Java classes.

`g_set_user_dirs` is already compiled into the GLib package. Native GTK
(`gnome`) is upstream GNOME. Android IME fixes are published from that
project's own distribution.

## Why the pkg-config wrapper exists

Pixiewood's `android.cross` sets `sys_root` to the NDK sysroot. Meson exports
that as `PKG_CONFIG_SYSROOT_DIR`. pkg-config would then turn
`-I$SYSROOT/include` into `-I$NDK/sysroot/$SYSROOT/include`. The wrapper
clears `PKG_CONFIG_SYSROOT_DIR` and sets `PKG_CONFIG_LIBDIR` to
`lib/<abi>/pkgconfig`. Do not set Meson's `sys_root` to the GTK prefix.
