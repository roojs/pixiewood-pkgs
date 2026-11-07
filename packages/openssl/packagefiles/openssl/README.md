# OpenSSL for Meson

Android builds use the generated configs already in `generated-config/` for
`linux-aarch64` and `linux-x86_64`. Configure does not run a generator, and
this package does not call Perl or Python.

`cpu` family selects the directory:

| CPU | Config |
| --- | --- |
| `aarch64` | `generated-config/archs/linux-aarch64` |
| `x86_64` | `generated-config/archs/linux-x86_64` |

Those files were produced from the Meson WrapDB OpenSSL 3.0.8-3 patch. The
top-level `meson.build` wires the selected directory into `libcrypto` and
`libssl`.
