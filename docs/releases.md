# How releases work

This repository publishes prebuilt Android libraries. Two archives show up on a release, and they are not the same file.

A distribution that keeps its pins in git uses a different layout: the pin names a release, and the bundle on that release is a `.pixie` file. That contract is [Implement your own distribution](own-distribution.md). The steps below are what this repository's publisher does today.

## Repository source archive

GitHub builds a source archive from the git tag with `git archive`. `.gitattributes` at the repository root controls that archive:

```
* export-ignore
/current.pins !export-ignore
```

Every path is dropped except `current.pins`. That file is the package list. Each line is one package and the tarball URL to download:

```
# abi gtk release name track resolved inputs url
arm64-v8a gnome 1.261107000000 gtk ae709f96... ae709f96... 40415ca3... https://github.com/roojs/pixiewood-pkgs/releases/download/1.261107000000/gtk-arm64-v8a-v31-snapshot.pixie
```

A package that did not change keeps the tarball URL from the earlier release. The line is not a pointer at `index-<abi>-<gtk>.json`.

`scripts/integrate-sysroot.sh latest` reads this list and downloads those tarballs. `pin path/to/index.json` uses the file you pass.

## What a publishing day does

On a day when something upstream changed, **Monitor upstreams** does this in order:

1. Resolve every package for each name in `packages/gtk/targets`.
2. Build the first GTK target in `packages/gtk/targets`. That is `gnome`, and it builds the shared libraries. When that build stops, every tarball it finished is uploaded and that package's line in `current.pins` is committed. A later package can fail. The packages already built stay on the release, so the next run downloads them.
3. `packages/gtk/targets` lists `gnome` only. A distribution that publishes a later GTK target uses `packages/gtk/replaces`: `gtk` is that target's own build, and `gdk` is built only when `gdk/` or `gtk/css` differs from gnome.
4. The release tag points at the commit that was current when the run started. `current.pins` on the branch names the tarballs that were actually uploaded.

A hand-started **Build Android sysroot** run does not publish and does not rewrite `current.pins`.

## Release file

The release name is `1.yymmddHHMMSS` in UTC. 7 November 2026 at 00:00:00 UTC is `1.261107000000`. A later run the same day gets its own name.

`1.yymmddHHMMSS.tgz` is generated at publish time and uploaded as a release asset. It holds the package lists, one `index-<abi>-<gtk>.json` per list. It does not hold the packages. Each package is a separate `.pixie` asset, an xz-compressed tar named `{name}-{abi}-v{api}-{version}.pixie`. `arm64-v8a` is the ABI. `v31` is API 31 from `android-distro.conf`. `{version}` is the upstream release, such as `3.0.8`. A branch or a commit is `snapshot`. Each index entry is the URL of one of them. A package that did not change keeps the URL of the release that built it. A package that was not built in this run is left out of the upload.

That `.tgz` is not a file in the git tree. `.gitattributes` and `.gitignore` do not name it.

The same index JSON is also uploaded on its own, and copied onto the moving GitHub release called `latest`.

## What you download

From a clone:

```bash
scripts/integrate-sysroot.sh latest --dest "$HOME/pixiewood-sysroot"
```

The target is `gnome`, upstream GTK with no Android patch.

To stay on one set, keep the index you already downloaded and pass it to `pin`.
