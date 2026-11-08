# Implement your own distribution

An Android application's build points at one git repository. That repository is the distribution. The pins live in the git checkout. Each pin names the GitHub release that holds the bundle. The bundle file extension is `.pixie`.

`gnome` is the reference target for the shared libraries. Another distribution, such as the Android IME branch, reuses those `gnome` bundles and publishes only the packages it replaces.

The publisher writes each finished package as a `.pixie` asset. The file is an xz-compressed tar. It uploads that asset before the next package starts, and it still uploads a `1.yymmddHHMMSS.tgz` package list. The layout below is the contract for a distribution that keeps its pins in git. [How releases work](releases.md) describes the publisher as it runs today. [The plan](plans.md) says which projects stay here.

## What the application checks out

The build script takes one git URL. It clones that repository and reads `current.pins` from the checkout. It does not download a tarball to find the pins, and the distribution does not publish a pins-only archive.

```bash
git clone --depth 1 https://github.com/roojs/pixiewood-pkgs.git "$distro"
```

The origin of that checkout is where the bundles are downloaded from, unless a pin line names another repository.

## What a pin line names

```
# abi gtk channel release name resolved inputs file repo
arm64-v8a	gnome	release	1.261107000000	gtk	ae709f962a51f9108a1e6381bcfbd05bbaecc840	<inputs>	gtk-arm64-v8a-gnome.pixie	roojs/pixiewood-pkgs
arm64-v8a	gnome	main	main	fontconfig	cbf1db7f1bd01e641968ca0818e05b0819ce6c74	<inputs>	fontconfig-arm64-v8a-gnome.pixie	roojs/pixiewood-pkgs
arm64-v8a	Knowles.android-ime	release	1.261108000000	gtk	<ime-commit>	<inputs>	gtk-arm64-v8a-Knowles.android-ime.pixie	Knowles/gtk
```

| Column | Meaning |
| --- | --- |
| `abi` | Android ABI, `arm64-v8a` or `x86_64` |
| `gtk` | Target. `gnome` for the shared stack. A later target only on the packages that target replaces |
| `channel` | `release` or `main` |
| `release` | GitHub release name. `1.yymmddHHMMSS` for a dated release, `main` for the moving tip |
| `name` | Package name from `build-order.txt` |
| `resolved` | Upstream commit or tarball identity that was built |
| `inputs` | Hash of the recipe that produced the bundle |
| `file` | Asset name on that release |
| `repo` | `owner/name` of the GitHub repository that published the release |

`channel=release` means the package was built from a tag or a pinned commit. `channel=main` means it was built from the default branch tip. The IME branch uses `channel=main` and `release=main` when it publishes the `android-ime` tip, and `channel=release` with a `1.yymmddHHMMSS` name when it publishes a dated set.

The file name is `{name}-{abi}-{gtk}.pixie`. A release can hold one `.pixie` per package. The pin's `file` column is that name, so the checkout and the release asset are the same string.

## How the bundle is fetched

For each pin line the app wants (its ABI, and `gnome` unless it asked for another target):

```
https://github.com/<repo>/releases/download/<release>/<file>
```

A dated line becomes:

```
https://github.com/roojs/pixiewood-pkgs/releases/download/1.261107000000/gtk-arm64-v8a-gnome.pixie
```

A main line becomes:

```
https://github.com/roojs/pixiewood-pkgs/releases/download/main/fontconfig-arm64-v8a-gnome.pixie
```

The script lists that release's assets and keeps the one whose name equals the `file` column. A `.pixie` file is an xz-compressed tar of one package: headers, libraries, and pkg-config under `prefix=/` and `lib/<abi>`, with `prefix=@PIXIEWOOD_SYSROOT@` in the `.pc` files. Extract every selected bundle into one directory, then run `scripts/activate-sysroot.sh` from this repository, or the same rewrite from the distribution you checked out.

An app that wants the proved set uses every `channel=release` line for its ABI. An app that wants a tip uses each `channel=main` line and, where a package has no `main` line, the `release` line.

## Publish a distribution

1. Keep `current.pins` in the git repository you want applications to clone.
2. Create a GitHub release named `1.yymmddHHMMSS` in UTC for a dated set, or a moving release named `main` for a tip.
3. Upload one `.pixie` asset per package you built, named `{name}-{abi}-{gtk}.pixie`.
4. Commit `current.pins` so each line's `release` and `file` match those assets.
5. Leave the pins out of the release. The release holds the bundles.

Packages you did not build stay on the reference distribution. Their pin lines keep `gtk=gnome`, `repo=roojs/pixiewood-pkgs`, and the release name that published that `.pixie`. The Android IME distribution publishes `gdk` and `gtk` for `Knowles.android-ime` and points every other line at the gnome bundles.

The build that produces a `.pixie` is the toolkit in this repository: `cross/`, `android-distro.conf`, `scripts/build-sysroot.sh --only` against a sysroot assembled from the pins, and `scripts/sysroot-tree.sh` for the archive layout. Rename the archive to `.pixie` when you upload it.
