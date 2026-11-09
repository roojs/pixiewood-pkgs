# pixiewood-pkgs

This repository builds the Android libraries for the GTK stack [Pixiewood](https://github.com/sp1ritCS/gtk-android-builder) links, and publishes each one as a `.pixie` file.

[pixie](https://github.com/roojs/pixie-pkg) installs those files and is what an application build runs. The pin lists are `release.pins` and `snapshot.pins` in this repository. The libraries run from OpenSSL through glib-networking, in `build-order.txt`.

## This repository

Wrap files live in `packages/`. Cross files live in `cross/`. NDK and API levels are in `android-distro.conf`.

```bash
scripts/install-sdk.sh
scripts/build-pixie.sh --only gtk --arch aarch64
```

**Prove package** publishes each finished library before the next one starts. **Monitor upstreams** moves a wrap to the newest release on that version line. A release version that already has a published file is kept. A newer version is built once. If that build fails, the published file stays in use until the version or the recipe changes. A snapshot is published again when its commit or its recipe changes. A dependency set is unpacked with `pixie-pkg fetch`.

## Tests

```bash
bash tests/test-pins-and-wrapper.sh
bash tests/test-index.sh
```

These cover wrap pins and the package index. They do not cross-compile GTK.

## Artificial intelligence usage

This project was developed with the assistance of artificial intelligence.

- Design overview is by the author
- Almost all of the code was written by AI
- Review of that code was light
