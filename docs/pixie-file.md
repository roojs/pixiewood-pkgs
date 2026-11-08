# What a pixie file is

A `.pixie` file is one prebuilt Android library. It is an xz-compressed tar.

The file name is `{name}-arm-v{api}-{version}.pixie` or `{name}-x86-v{api}-{version}.pixie`.

- `arm` is `arm64-v8a`. `x86` is `x86_64`. The libraries inside stay in `lib/arm64-v8a` and `lib/x86_64`.
- `v31` is Android API 31.
- An official release uses its version, such as `openssl-arm-v31-3.0.8.pixie`.
- Anything else uses `snapshot`, such as `fontconfig-arm-v31-snapshot.pixie`.

The GitHub release that holds the file is named `1.yymmdd` in UTC. 7 November 2026 is `1.261107`. A later upload the same day goes onto that same release.

Inside the archive: headers, libraries, and pkg-config files for one upstream project, with `prefix=/` and `libdir=lib/<abi>`. The `gtk` package also carries the Android Java glue under `share/pixiewood/gtk-android-java`. `glib-networking` carries the static `gioopenssl` module.

The `.pc` files contain `prefix=@PIXIEWOOD_SYSROOT@`. `scripts/activate-sysroot.sh` rewrites that to the directory the files were unpacked into, and writes `share/pixiewood/sysroot.cross`.

The URL for a file looks like:

```
https://github.com/roojs/pixiewood-pkgs/releases/download/1.261108/openssl-arm-v31-3.0.8.pixie
```

That URL is the last column of a pin line. [Sharing your library](sharing-your-library.md) is the pin file. [Using pixie libraries](using-pixie-libraries.md) is how a build downloads it.
