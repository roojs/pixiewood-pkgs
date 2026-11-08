# How releases work

This repository publishes prebuilt Android libraries. The pin files live in git. The `.pixie` packages live on the GitHub release. [Implement your own distribution](own-distribution.md) is the same layout for another project.

## Repository source archive

GitHub builds a source archive from the git tag with `git archive`. `.gitattributes` at the repository root controls that archive:

```
* export-ignore
/release.pins !export-ignore
/snapshot.pins !export-ignore
```

Every path is dropped except the pin files. `release.pins` lists official releases. `snapshot.pins` lists snapshots, and a project can leave that file out. Each line is one package and the file URL to download:

```
# abi gtk release name track resolved inputs url
arm64-v8a	gnome	1.261108	openssl	openssl-3.0.8.tar.gz	6c13d2bf...	17b68711...	https://github.com/roojs/pixiewood-pkgs/releases/download/1.261108/openssl-arm-v31-3.0.8.pixie
```

A snapshot line is the same columns in `snapshot.pins`, and the file name ends in `-snapshot.pixie`. A package that did not change keeps the URL from the earlier release. The line is not a pointer at `index-<abi>-<gtk>.json`.

## What a publishing day does

On a day when something upstream changed, **Monitor upstreams** does this in order:

1. Resolve every package for each name in `packages/gtk/targets`.
2. Build the first GTK target in `packages/gtk/targets`. That is `gnome`, and it builds the shared libraries. When that build stops, every tarball it finished is uploaded and that package's line in `release.pins` is committed. A snapshot build writes `snapshot.pins`. A later package can fail. The packages already built stay on the release, so the next run downloads them.
3. `packages/gtk/targets` lists `gnome` only. A distribution that publishes a later GTK target uses `packages/gtk/replaces`: `gtk` is that target's own build, and `gdk` is built only when `gdk/` or `gtk/css` differs from gnome.
4. The release tag points at the commit that was current when the run started. `release.pins` and `snapshot.pins` on the branch name the files that were actually uploaded.

A hand-started **Build Android sysroot** run does not publish and does not rewrite the pin files.

## Release file

The release name is `1.yymmdd` in UTC. 7 November 2026 is `1.261107`. A later run the same day uploads onto that release.

`1.yymmdd.tgz` is generated at publish time and uploaded as a release asset. It holds the package lists, one `index-<abi>-<gtk>.json` per list. It does not hold the packages. Each package is a separate `.pixie` asset, an xz-compressed tar named `{name}-arm-v{api}-{version}.pixie` for 64-bit ARM and `{name}-x86-v{api}-{version}.pixie` for 64-bit x86. `v31` is API 31 from `android-distro.conf`. The libraries inside the archive stay in `lib/arm64-v8a` and `lib/x86_64`. An official release uses its version, such as `3.0.8`. Anything else uses `snapshot`. Each index entry is the URL of one of them. A package that did not change keeps the URL of the release that built it. A package that was not built in this run is left out of the upload.

That `.tgz` is not a file in the git tree. `.gitattributes` and `.gitignore` do not name it.

The same index JSON is also uploaded on its own, and copied onto the moving GitHub release called `latest`.

## What you download

An Android build names the repository, the branch, and release or snapshot.

```bash
git clone --depth 1 --branch main https://github.com/roojs/pixiewood-pkgs.git
scripts/integrate-sysroot.sh latest --dest "$HOME/pixiewood-sysroot"
scripts/integrate-sysroot.sh latest --snapshot --dest "$HOME/pixiewood-sysroot"
```

`latest` reads `release.pins`. `latest --snapshot` reads `snapshot.pins`. The target is `gnome`, upstream GTK with no Android patch.

To stay on one set, keep the index you already downloaded and pass it to `pin`.
