# Local pixie files

This is a plan. Nothing here is built yet.

Publishing stays as it is. A project such as OLLMchat uploads `.pixie` files to the GitHub release for that day.

An application build expects the libraries to already be in the local directories. It does not download them. The end-user tool is one shell script, `pixie`. The Debian package, the RPM, and a GitHub build of an application all use that script.

## Where the tools live

Anything an end user runs is installed under `share/pixie`.

- A user install uses `~/.local/share/pixie`.
- The Debian package and the RPM use `/usr/share/pixie`.

That directory holds the `pixie` command and the helper scripts the build calls: the Meson wrapper and the runtime stage script. `~/.local/bin/pixie` and `/usr/bin/pixie` point at the command.

## Where the libraries live

- A user install uses `~/.local/lib/pixie`.
- The packages use `/usr/lib/pixie`.

```
lib/pixie/release/
lib/pixie/snapshot/
```

`release` is the set from `release.pins`. `snapshot` is the set from `snapshot.pins`. Each directory is the unpacked tree: `lib/arm64-v8a`, `lib/x86_64`, headers, and `share/pixiewood`. Both ABIs can sit in the same directory.

Each directory has a file named `pulled`. It contains one UTC time, the moment the last pull of that whole set finished. One fresh `pulled` file means every package from that pull is present. A half-written directory is not used.

Downloaded archives sit in `~/.cache/pixie` for a user, and in `/var/cache/pixie` for the packages.

## Commands

```bash
pixie install
pixie install --snapshot
pixie pull
pixie pull --snapshot
pixie pull --force
pixie apply
pixie apply --snapshot
```

`pixie install` puts one whole set into the library directory and activates it. A GitHub build of an application runs this so the libraries are on the machine before the build. The Debian package and the RPM run it for `/usr/lib/pixie`. A user run writes to `~/.local/lib/pixie`.

`pixie pull` is the online check. Run it when you want a later set. It downloads the pin list and writes `pulled` only after every file has arrived. `--force` downloads again even when `pulled` is under 24 hours old. A build does not run `pull` on its own.

`pixie apply` sets up the library for a build. It looks at the user directory, then the system directory, and activates the one it finds. The Meson wrapper and the runtime stage script in `share/pixie` then use that directory.

The published release is the day. A pull from the last 24 hours is the active set.

- `pulled` is under 24 hours old: `apply` uses that directory.
- `pulled` is missing or older: `apply` stops. Run `pixie pull` while online, then `pixie install`, then `apply` again.
- A later upload on the same day is picked up by `pixie pull --force`.

`PIXIEWOOD_PIXIE` is `~/.local/lib/pixie/release` or `/usr/lib/pixie/release`, and the same with `snapshot`.
