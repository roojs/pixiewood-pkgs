# How releases work

This repository publishes prebuilt Android libraries. Two archives show up on a release, and they are not the same file.

## Repository source archive

GitHub builds a source archive from the git tag with `git archive`. `.gitattributes` at the repository root controls that archive:

```
* export-ignore
/current.pins !export-ignore
```

Every path is dropped except `current.pins`. The source archive contains that one file. It does not contain the build scripts, the package wraps, or the generated release file.

`current.pins` is a text table:

```
# abi gtk release url
arm64-v8a gnome 1.261107 https://github.com/roojs/pixiewood-pkgs/releases/download/1.261107/index-arm64-v8a-gnome.json
```

Each line is one ABI and one GTK target. The URL is the package index to download for that pair. `scripts/integrate-sysroot.sh latest` reads this file and fetches that index. `pin path/to/index.json` ignores `current.pins` and uses the file you pass.

## Generated before the build

On a day when something upstream changed, **Monitor upstreams** does this in order:

1. Resolve every package for each name in `packages/gtk/targets`.
2. If that target needs a release, rewrite the matching `current.pins` lines to today's release and commit them.
3. Start the build from that commit.
4. Upload the release.

The commit lands before compilation starts. The release tag points at that commit, so the source archive of the tag is the `current.pins` that names this release. A target that is not published keeps its previous line. An arch that is not built is left alone.

A hand-started **Build Android sysroot** run does not publish and does not rewrite `current.pins`.

## Release file

The release name is `1.yymmdd` in UTC. 7 November 2026 is `1.261107`.

`1.yymmdd.tgz` is generated at publish time and uploaded as a release asset. It holds the package lists, one `index-<abi>-<gtk>.json` per list. It does not hold the package tarballs. Those are separate assets, and each index entry is the URL of one of them. A package that did not change keeps the URL of the release that built it.

That `.tgz` is not a file in the git tree. `.gitattributes` and `.gitignore` do not name it.

The same index JSON is also uploaded on its own, and copied onto the moving GitHub release called `latest`. `current.pins` points at the dated release, so a source archive keeps naming that day after a newer day is published.

## What you download

From the source archive, read `current.pins` and fetch the index URL for the ABI and GTK target you want.

From a clone, the same file is at the repository root:

```bash
scripts/integrate-sysroot.sh latest --dest "$HOME/pixiewood-sysroot"
scripts/integrate-sysroot.sh latest --gtk Knowles.android-ime --dest "$HOME/pixiewood-sysroot"
```

The default target is `gnome`, upstream GTK with no Android patch. `Knowles.android-ime` is the owner and branch that carries the Android fixes. Another fork is another line in `packages/gtk/targets`, named `owner.branch`.

To stay on one set, keep the index you already downloaded and pass it to `pin`.
