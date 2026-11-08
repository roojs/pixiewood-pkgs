# Using pixie libraries

An Android build names three things: the repository, the branch, and release or snapshot.

`release.pins` on that branch lists the official releases. `snapshot.pins` lists the snapshots. A project can leave `snapshot.pins` out.

```bash
git clone --depth 1 --branch main https://github.com/roojs/pixiewood-pkgs.git "$distro"
"$distro/scripts/integrate-sysroot.sh" latest --dest "$HOME/pixiewood"
"$distro/scripts/integrate-sysroot.sh" latest --snapshot --dest "$HOME/pixiewood"
```

`latest` reads `release.pins`. `latest --snapshot` reads `snapshot.pins`. Each line is one `.pixie` file. The download unpacks those files into the directory you named. See [What a pixie file is](pixie-file.md).

To stay on one set, keep `share/pixiewood/INDEX.json` from that directory and pass it to `pin`:

```bash
"$distro/scripts/integrate-sysroot.sh" pin path/to/index.json --dest "$HOME/pixiewood"
```

## From Pixiewood

`integration/0001-pixie-libraries.patch` applies to gtk-android-builder `00b1862b6434a8778557dc3d3074f43f5fdead1b`. From a checkout of that revision:

```bash
patch -p1 < /path/to/pixiewood-pkgs/integration/0001-pixie-libraries.patch
pixiewood prepare \
  --sdk "$ANDROID_SDK_ROOT" \
  --pixie "$HOME/pixiewood" \
  android/app.xml
pixiewood generate
pixiewood build
```

`--pixie` is the directory from `latest`. Libraries listed in `share/pixiewood/MANIFEST.json` are used as they are. Anything absent from that list is still built from a wrap. Icons, the CA bundle, shared-mime-info, and the application's own Java classes stay with the app.
