# pixiewood-pkgs

This repository builds the Android libraries for the GTK stack [Pixiewood](https://github.com/sp1ritCS/gtk-android-builder) links, and publishes each one as a `.pixie` file.

The point is two pin lists.

`release.pins` is the released versions of the libraries. A git tag or a release tarball is the version on the pixie file, for example `openssl-arm-v31-3.0.8.pixie`. That version is the file name.

`snapshot.pins` is a branch, such as `main`. Those files are named `snapshot`.

The wrap in `packages/` is the upstream source the next build compiles. The daily monitor moves a numbered wrap to the newest release on that same version line. A branch or a commit stays as written. A build that succeeds replaces that library's pin. A build that fails leaves the published file as it is. The table on the project page is those published files, not every version the wrap has asked for.

Publishing either list can fail. Each list keeps the highest version that builds. A pin names a `.pixie` file that is on the release.

The published lists are at <https://roojs.github.io/pixiewood-pkgs/>. That page is the package list [pixie](https://github.com/roojs/pixie-pkg) reads. It links `release.pins` and `snapshot.pins`, and shows the version of each library in each list.

The libraries run from OpenSSL through glib-networking, in `build-order.txt`.

## This repository

Wrap files live in `packages/`. Cross files live in `cross/`. NDK and API levels are in `android-distro.conf`.

```bash
scripts/install-sdk.sh
scripts/build-pixie.sh --only gtk --arch aarch64
```

**Prove package** publishes each finished library before the next one starts. **Monitor upstreams** fills the two lists. A published file stays when a newer build fails. A dependency set is unpacked with `pixie-pkg fetch`.

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
