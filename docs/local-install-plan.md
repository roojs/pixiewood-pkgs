# Local pixie files

This is a plan. Nothing here is built yet.

Publishing stays as it is. A project such as OLLMchat uploads `.pixie` files to the GitHub release for that day.

A local application build does not download on its own. It runs `pixie`, a regular shell script. The same script is what a Debian package and an RPM run.

## Directory

A user install lives at `~/.local/lib/pixie`. The Debian package and the RPM use `/usr/lib/pixie`.

```
lib/pixie/release/
lib/pixie/snapshot/
```

`release` is the set from `release.pins`. `snapshot` is the set from `snapshot.pins`. Each directory is the unpacked tree: `lib/arm64-v8a`, `lib/x86_64`, headers, and `share/pixiewood`. Both ABIs can sit in the same directory.

Each directory also has a file named `pulled`. It contains one UTC time, the moment the last pull of that whole set finished. One fresh `pulled` file means every package from that pull is present. A half-written directory is not used.

Downloaded archives sit in `~/.cache/pixie` for a user, and in `/var/cache/pixie` for the packages.

## Commands

```bash
pixie pull
pixie pull --snapshot
pixie install
pixie install --snapshot
pixie apply
pixie apply --snapshot
```

`pixie pull` downloads the whole set. It writes `pulled` only after every file in the pin list has arrived. `--force` downloads again even when `pulled` is under 24 hours old.

`pixie install` unpacks that set into the install directory and activates it. The Debian package and the RPM run `pull` and `install` for `/usr/lib/pixie`. A user run writes to `~/.local/lib/pixie`.

`pixie apply` is what an application build runs. It looks at the user directory, then the system directory.

The published release is the day. A pull from the last 24 hours is the active set.

- `pulled` is under 24 hours old: the build uses that directory.
- `pulled` is missing or older, and the machine is online: `pull`, then `install`, then use it.
- `pulled` is missing or older, and the machine is offline: the build stops.
- A later upload on the same day is picked up by `pixie pull --force`.

`apply` sets the build at that directory. `PIXIEWOOD_PIXIE` is `~/.local/lib/pixie/release` or `/usr/lib/pixie/release`, and the same with `snapshot`.
