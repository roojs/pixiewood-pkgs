# How releases work

This repository publishes prebuilt Android libraries. Two archives show up on a release, and they are not the same file.

## Repository source archive

GitHub builds a source archive from the git tag with `git archive`. `.gitattributes` at the repository root controls that archive:

```
* export-ignore
/current.pins !export-ignore
```

Every path is dropped except `current.pins`. That file is meant to be the package list itself. The copy that only stored index URLs was not the list, so it is not in the tree. Until `current.pins` is that list, the source archive is empty. It does not contain the build scripts, the package wraps, or the generated release file.

`scripts/integrate-sysroot.sh latest` downloads the index from the moving release. `pin path/to/index.json` uses the file you pass.

## What a publishing day does

On a day when something upstream changed, **Monitor upstreams** resolves every package for each name in `packages/gtk/targets`, builds the packages that changed, and uploads the release. A hand-started **Build Android sysroot** run does not publish.

## Release file

The release name is `1.yymmdd` in UTC. 7 November 2026 is `1.261107`.

`1.yymmdd.tgz` is generated at publish time and uploaded as a release asset. It holds the package lists, one `index-<abi>-<gtk>.json` per list. It does not hold the package tarballs. Those are separate assets, and each index entry is the URL of one of them. A package that did not change keeps the URL of the release that built it.

That `.tgz` is not a file in the git tree. `.gitattributes` and `.gitignore` do not name it.

The same index JSON is also uploaded on its own, and copied onto the moving GitHub release called `latest`.

## What you download

From a clone:

```bash
scripts/integrate-sysroot.sh latest --dest "$HOME/pixiewood-sysroot"
scripts/integrate-sysroot.sh latest --gtk Knowles.android-ime --dest "$HOME/pixiewood-sysroot"
```

The default target is `gnome`, upstream GTK with no Android patch. `Knowles.android-ime` is the owner and branch that carries the Android fixes. Another fork is another line in `packages/gtk/targets`, named `owner.branch`.

To stay on one set, keep the index you already downloaded and pass it to `pin`.
