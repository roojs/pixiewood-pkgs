# pixiewood-pkgs

Prebuilt Android libraries for the GTK stack [Pixiewood](https://github.com/sp1ritCS/gtk-android-builder) links. Each library is a `.pixie` file.

- [Using pixie libraries](docs/using-pixie-libraries.md) — point an Android build at a repository, a branch, and release or snapshot.
- [Sharing your library](docs/sharing-your-library.md) — publish `release.pins` and, when you have snapshots, `snapshot.pins`.
- [What a pixie file is](docs/pixie-file.md) — the file name and what is inside.

This repository publishes the GTK libraries an Android app links, OpenSSL through glib-networking, in `build-order.txt`. `release.pins` lists the official releases. `snapshot.pins` lists the snapshots.

```bash
git clone --depth 1 --branch main https://github.com/roojs/pixiewood-pkgs.git
scripts/pixie.sh latest --dest "$HOME/pixiewood"
```

## This repository

Wrap files live in `packages/`. Cross files live in `cross/`. NDK and API levels are in `android-distro.conf`.

```bash
scripts/install-sdk.sh
scripts/build-sysroot.sh --arch aarch64
```

`scripts/build-sysroot.sh --only gtk` builds the GTK library. **Prove package** publishes each finished library before the next one starts. **Monitor upstreams** publishes a library when its upstream revision or its recipe changes.

## Tests

```bash
bash tests/test-sysroot-tree.sh
bash tests/test-pins-and-wrapper.sh
bash tests/test-index.sh
```

These cover packing, activation, runtime staging, wrap pins, and the index. They do not cross-compile GTK.
