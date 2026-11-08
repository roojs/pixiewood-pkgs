# Sharing your library

A project that shares Android libraries keeps the pin files in git. Applications clone a branch and choose release or snapshot. See [Using pixie libraries](using-pixie-libraries.md).

Release or snapshot is the pin file. `release.pins` is the release list. `snapshot.pins` is optional.

```json
{
  "packages": [
    {
      "abi": "arm64-v8a",
      "repo": "https://gitlab.gnome.org/GNOME/gtk.git",
      "release": "1.261108",
      "name": "openssl",
      "track": "openssl-3.0.8.tar.gz",
      "resolved": "6c13d2bf...",
      "inputs": "<inputs>",
      "url": "https://github.com/roojs/pixiewood-pkgs/releases/download/1.261108/openssl-arm-v31-3.0.8.pixie"
    }
  ]
}
```

`snapshot.pins` uses the same objects. The file name ends in `-snapshot.pixie`.

| Field | Meaning |
| --- | --- |
| `abi` | Android ABI directory, `arm64-v8a` or `x86_64`. The file name says `arm` or `x86` |
| `repo` | Full git URL of the GTK checkout, `https://gitlab.gnome.org/GNOME/gtk.git` |
| `release` | Published release, `1.yymmdd` |
| `name` | Package name |
| `track` | Upstream version, tag, branch, or commit that was built |
| `resolved` | Commit or tarball identity that was built |
| `inputs` | Hash of the recipe that produced the file |
| `url` | Download URL of the `.pixie` file |

## Publish

1. Put `release.pins` in the repository applications clone. Add `snapshot.pins` when you publish snapshots.
2. Create a GitHub release named `1.yymmdd` in UTC. 7 November 2026 is `1.261107`. A later run the same day uploads onto that release.
3. Upload one `.pixie` per library. An official release uses its version, such as `3.0.8`. Anything else uses `snapshot`. The file name is `{name}-arm-v{api}-{version}.pixie` or `{name}-x86-v{api}-{version}.pixie`.
4. Commit the pin file so the package object matches the uploaded file.
5. The GitHub release holds the `.pixie` files. The pin files stay in git.

A line's URL can point at a `.pixie` file published by another repository. The Android IME branch and webkitgtk-android are separate projects, with their own branches and their own pin files.

`.gitattributes` can limit the git source archive to the pin files:

```
* export-ignore
/release.pins !export-ignore
/snapshot.pins !export-ignore
```
