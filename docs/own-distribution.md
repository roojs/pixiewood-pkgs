# Implement your own distribution

An Android build names three things: the repository, the branch, and release or snapshot.

That repository is the distribution. It has `release.pins`. It can also have `snapshot.pins`. The build checks out the branch and reads one of those files. Each line is one package and the URL of its `.pixie` file.

`snapshot.pins` is optional. A project that only publishes numbered releases ships `release.pins`.

```bash
git clone --depth 1 --branch main https://github.com/roojs/pixiewood-pkgs.git "$distro"
"$distro/scripts/integrate-sysroot.sh" latest --dest "$HOME/pixiewood-sysroot"
"$distro/scripts/integrate-sysroot.sh" latest --snapshot --dest "$HOME/pixiewood-sysroot"
```

`latest` reads `release.pins` on that checkout. `latest --snapshot` reads `snapshot.pins`. The pins are not a separate download. [How releases work](releases.md) is what this repository publishes. [The plan](plans.md) says which projects stay here.

## What a pin line names

`release.pins`:

```
# abi gtk release name track resolved inputs url
arm64-v8a	gnome	1.261108	openssl	openssl-3.0.8.tar.gz	6c13d2bf...	<inputs>	https://github.com/roojs/pixiewood-pkgs/releases/download/1.261108/openssl-arm-v31-3.0.8.pixie
```

`snapshot.pins` uses the same columns:

```
arm64-v8a	gnome	1.261108	fontconfig	main	cbf1db7f...	<inputs>	https://github.com/roojs/pixiewood-pkgs/releases/download/1.261108/fontconfig-arm-v31-snapshot.pixie
```

| Column | Meaning |
| --- | --- |
| `abi` | Android ABI directory, `arm64-v8a` or `x86_64`. The file name says `arm` or `x86` |
| `gtk` | Target. `gnome` for this stack |
| `release` | GitHub release name, `1.yymmdd` |
| `name` | Package name |
| `track` | Upstream version, tag, branch, or commit that was built |
| `resolved` | Commit or tarball identity that was built |
| `inputs` | Hash of the recipe that produced the bundle |
| `url` | Download URL of the `.pixie` file |

An official release is named with its version, such as `3.0.8`. Anything else is named `snapshot`.

The file name is `{name}-arm-v{api}-{version}.pixie` or `{name}-x86-v{api}-{version}.pixie`. `v31` is API 31. The libraries inside the archive stay in `lib/arm64-v8a` and `lib/x86_64`.

## How the bundle is fetched

The `url` column is the file:

```
https://github.com/roojs/pixiewood-pkgs/releases/download/1.261108/openssl-arm-v31-3.0.8.pixie
```

A `.pixie` file is an xz-compressed tar of one package: headers, libraries, and pkg-config under `prefix=/` and `lib/<abi>`, with `prefix=@PIXIEWOOD_SYSROOT@` in the `.pc` files. Extract the packages into one directory, then run `scripts/activate-sysroot.sh` from the checkout.

## Publish a distribution

1. Put `release.pins` in the git repository applications clone. Add `snapshot.pins` when you publish snapshots.
2. Create a GitHub release named `1.yymmdd` in UTC.
3. Upload one `.pixie` per package. An official release uses the version. Anything else uses `snapshot`.
4. Commit the pin file you updated so each line matches the uploaded file.
5. The release holds the bundles. The pin files stay in git.

Another project is its own repository, with its own branch and its own `release.pins`. A line's URL can point at a bundle published here.

The build that produces a `.pixie` is the toolkit in this repository: `cross/`, `android-distro.conf`, `scripts/build-sysroot.sh --only` against a sysroot assembled from the pins, and `scripts/sysroot-tree.sh` for the archive layout. Rename the archive to `.pixie` when you upload it.
