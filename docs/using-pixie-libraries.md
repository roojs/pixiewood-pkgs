# Using pixie libraries

An Android build names three things: the repository, the branch, and release or snapshot.

`release.pins` on that branch lists the official releases. `snapshot.pins` lists the snapshots. A project can leave `snapshot.pins` out.

```bash
git clone --depth 1 --branch main https://github.com/roojs/pixiewood-pkgs.git "$distro"
"$distro/scripts/pixie.sh" latest --dest "$HOME/pixiewood"
"$distro/scripts/pixie.sh" latest --snapshot --dest "$HOME/pixiewood"
```

`latest` reads `release.pins`. `latest --snapshot` reads `snapshot.pins`. Each package object names one `.pixie` file. The download unpacks those files into the directory you named. See [What a pixie file is](pixie-file.md).

To stay on one set, keep `share/pixiewood/INDEX.json` from that directory and pass it to `pin`:

```bash
"$distro/scripts/pixie.sh" pin path/to/index.json --dest "$HOME/pixiewood"
```

## From Pixiewood

Leave the Pixiewood checkout as it is. `prepare` already accepts another Meson program. Point that at `scripts/meson-wrapper.sh`, and point the wrapper at the directory from `latest`:

```bash
export PIXIEWOOD_PIXIE="$HOME/pixiewood"
export PIXIEWOOD_REAL_MESON="$(command -v meson)"
pixiewood prepare \
  --sdk "$ANDROID_SDK_ROOT" \
  --meson "$distro/scripts/meson-wrapper.sh" \
  android/app.xml
```

The wrapper adds `share/pixiewood/pixie.cross` to `meson setup`. Pass that same `--cross-file` again on every later reconfigure.

Set the Java glue on the manifest:

```xml
<build
  target="app"
  java-sources="/home/you/pixiewood/share/pixiewood/gtk-android-java">
```

Copy the libraries and GSettings schemas into the app tree before Gradle, and before Pixiewood runs `glib-compile-schemas`:

```bash
"$distro/scripts/stage-runtime.sh" \
  "$HOME/pixiewood" \
  /path/to/app/.pixiewood/root
```

Libraries named in `share/pixiewood/MANIFEST.json` are already built. Remove `subprojects/<name>.wrap` for those names so Meson keeps the pixie copy. Anything absent from that list is still built from a wrap. Icons, the CA bundle, shared-mime-info, and the application's own Java classes stay with the app.
