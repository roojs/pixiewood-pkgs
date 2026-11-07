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
   extracted tree (that directory contains `org/gtk/android`, including the
   OLLMchat Android patches).

Activate the extracted tarball first (`scripts/activate-sysroot.sh`). That
rewrites `prefix=@PIXIEWOOD_SYSROOT@` in the `.pc` files and writes
`share/pixiewood/sysroot.cross`.

## Patch Pixiewood

`integration/0001-sysroot-prebuilt-dependencies.patch` applies to
gtk-android-builder `00b1862b6434a8778557dc3d3074f43f5fdead1b` (the revision
OLLMchat pins). From a checkout of that revision:

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
  android/pixiewood-chat-poc.xml
pixiewood generate
pixiewood build
```

Dependencies the sysroot does not list are still built from wraps. An
application can keep a wrap for something that is not in the tarball.

## Without waiting for the patch

OLLMchat already passes `--meson` and reconfigures with its own cross file.
Point that Meson at `scripts/meson-wrapper.sh` and set two variables:

```bash
export PIXIEWOOD_SYSROOT="$HOME/pixiewood-sysroot"
export PIXIEWOOD_REAL_MESON="$(command -v meson)"
pixiewood prepare \
  --sdk "$ANDROID_SDK_ROOT" \
  --meson /path/to/pixiewood-pkgs/scripts/meson-wrapper.sh \
  android/pixiewood-chat-poc.xml
```

The wrapper inserts `--cross-file $PIXIEWOOD_SYSROOT/share/pixiewood/sysroot.cross`
into `meson setup`. Stock Pixiewood still writes wraps. Meson prefers
pkg-config when the `.pc` file satisfies the dependency, so those wraps are
not compiled. Delete `subprojects/*.wrap` for the provided names if a version
check would otherwise fall back to building them.

OLLMchat runs Meson a second time from `reconfigure_pixiewood_build` in
`scripts/android/build-pixiewood-apk.sh`, and that call does not go through
Pixiewood's `--meson`. Add the same `--cross-file` there, after
`android/pixiewood-extra.cross`, and pass it on every reconfigure. A
reconfigure that omits the file drops the sysroot and Meson goes back to the
wraps. With the sysroot file last, its `glib-mkenums` entry overrides the
extra cross file's path into `subprojects/glib`.

Stock Pixiewood does not copy external libraries into `.pixiewood/root` and
does not know the Java glue path. Set the glue on the manifest `<build>`
element:

```xml
<build
  target="ollmchat-android-poc"
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

## What an app such as OLLMchat changes

In `android/pixiewood-chat-poc.xml`, the `<dependencies>` entries that
`MANIFEST.json` lists (`glib`, `fontconfig`, `gtk`, `libadwaita`,
`gtksourceview`, `libxml2`, `sqlite3`, `gee`, `json-glib`, `nghttp2`,
`libsoup`, `openssl`, `glib-networking`, and the extra wraps `libpsl` and
`webkitgtk-android`) no longer need source wraps. The application meson
targets stay as they are: `dependency('gtk4')`, `dependency('gioopenssl')`,
`dependency('webkitgtk-android-1')`, and the others resolve through pkg-config.

Stop pointing `glib-mkenums` at `subprojects/glib` once GLib is not a
subproject. The activated cross file uses the script from the sysroot when
that file is a host script. Drop the app's `android/pixiewood-extra.cross`
`glib-mkenums` line, or let `sysroot.cross` come last so it wins.

Keep the app-specific pieces Pixiewood already does not build: Adwaita icon
subset, shared-mime-info, CA certificates, the application Java classes, and
the webkitgtk-android Java classes installed by
`scripts/android/install-webview-java.sh`.

`g_set_user_dirs` and the GTK Android bug patch are already compiled into the
sysroot. The app does not need `android/pixiewood-wraps/gtk/android-bugs.patch`
or the GLib hack at prepare time for this profile.

## Why the pkg-config wrapper exists

Pixiewood's `android.cross` sets `sys_root` to the NDK sysroot. Meson exports
that as `PKG_CONFIG_SYSROOT_DIR`. pkg-config would then turn
`-I$SYSROOT/include` into `-I$NDK/sysroot/$SYSROOT/include`. The wrapper
clears `PKG_CONFIG_SYSROOT_DIR` and sets `PKG_CONFIG_LIBDIR` to
`lib/<abi>/pkgconfig`. Do not set Meson's `sys_root` to the GTK prefix.
