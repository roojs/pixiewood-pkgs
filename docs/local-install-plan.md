# Local pixie files

This is a plan. Nothing here is built yet.

Publishing stays as it is. A project such as OLLMchat uploads `.pixie` files to the GitHub release for that day.

A local application build does not download during the build. It uses a set already installed on the machine. A Debian package owns that directory, pulls the set when the machine is online, and can refresh it on demand.

## Directory

`/usr/lib/pixie` is the install path.

```
/usr/lib/pixie/release/
/usr/lib/pixie/snapshot/
```

`release` is the set from `release.pins`. `snapshot` is the set from `snapshot.pins`. Each directory is the unpacked tree `scripts/pixie.sh` already writes: `lib/arm64-v8a`, `lib/x86_64`, headers, and `share/pixiewood`. Both ABIs can sit in the same directory.

Each directory also has a file named `pulled`. It contains one UTC time, the moment the last pull of that whole set finished.

## When a build may use the local set

The check is for the whole set. One fresh `pulled` file means every package from that pull is present. A half-written directory is not used.

The published release is the day, `1.yymmdd`. A pull from the last 24 hours is the active set.

- `pulled` is under 24 hours old: the build uses that directory.
- `pulled` is missing or older, and the machine is online: pull the set again, then use it.
- `pulled` is missing or older, and the machine is offline: the build stops. There is no older set to fall back to.
- A later upload on the same day is not seen until the next pull. `pixie install` forces that pull.

An application sets `PIXIEWOOD_PIXIE` to `/usr/lib/pixie/release` or `/usr/lib/pixie/snapshot`. The rest of the Pixiewood setup stays the same.

## Commands

`scripts/pixie.sh install` pulls one set into `/usr/lib/pixie` and writes `pulled` only after every file in the pin list is unpacked.

```bash
scripts/pixie.sh install
scripts/pixie.sh install --snapshot
scripts/pixie.sh install --force
```

`--force` pulls again even when `pulled` is under 24 hours old.

The Debian package runs `install` when it is installed or upgraded. A later `install --force` is how a machine catches a same-day upload without waiting for the package.
