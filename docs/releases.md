# How releases work

This repository publishes prebuilt Android libraries. Two archives show up on a release, and they are not the same file.

## Repository source archive

GitHub builds a source archive from the git tag with `git archive`. `.gitattributes` at the repository root controls that archive:

```
* export-ignore
/current.pins !export-ignore
```

Every path is dropped except `current.pins`. That file is the package list. Each line is one package and the tarball URL to download:

```
# abi gtk release name track resolved inputs url
arm64-v8a gnome 1.261107 gtk ae709f96... ae709f96... 40415ca3... https://github.com/roojs/pixiewood-pkgs/releases/download/1.261107/gtk-arm64-v8a-gnome.tar.xz
```

A package that did not change keeps the tarball URL from the earlier release. The line is not a pointer at `index-<abi>-<gtk>.json`.

`scripts/integrate-sysroot.sh latest` reads this list and downloads those tarballs. `pin path/to/index.json` uses the file you pass.

## What a publishing day does

On a day when something upstream changed, **Monitor upstreams** does this in order:

1. Resolve every package for each name in `packages/gtk/targets`.
2. Write `current.pins` for the packages that will be published and commit it.
3. Build the first GTK target in `packages/gtk/targets`. That is `gnome`, and it builds the shared libraries.
4. Build each later target. `packages/gtk/replaces` names what that target may build. `gtk` is always its own build. `gdk` is built for that target only when `gdk/` or `gtk/css` differs from the first target; otherwise the later target links the first target's GDK. Every other library stays on the first target. `webkitgtk-android` is the roojs project, so its pin is `roojs` rather than `gnome`.
5. Upload the release. The release tag points at the pins commit, so the source archive of the tag is that list.

A hand-started **Build Android sysroot** run does not publish and does not rewrite `current.pins`.

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
