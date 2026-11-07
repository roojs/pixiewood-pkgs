#!/usr/bin/env python3
"""Pack and activate a pixiewood Android sysroot tree.

`finalize` rewrites installed pkg-config files so their prefix is a token,
synthesizes the static gioopenssl .pc OLLMchat links, and writes MANIFEST.json.

`activate` binds that token to the directory the tarball was extracted into
and writes the Meson cross file consumers pass to pixiewood.
"""

from __future__ import annotations

import argparse
import json
import stat
from pathlib import Path

TOKEN = "@PIXIEWOOD_SYSROOT@"
FORMAT = 1


def read_pc(path: Path) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line or line.startswith("#") or ":" not in line and "=" not in line:
            continue
        if line.startswith("prefix=") or line.startswith("Name:") or line.startswith("Version:"):
            key, value = line.split(":", 1) if line.startswith(("Name:", "Version:")) else ("prefix", line.split("=", 1)[1])
            if line.startswith("prefix="):
                fields["prefix"] = line.split("=", 1)[1].strip()
            else:
                fields[key.strip().lower()] = value.strip()
    return fields


def rewrite_prefix_lines(text: str, old: str, new: str) -> str:
    lines = []
    for line in text.splitlines(keepends=True):
        newline = "\n" if line.endswith("\n") else ""
        body = line[:-1] if newline else line
        if body == f"prefix={old}":
            lines.append(f"prefix={new}{newline}")
        else:
            lines.append(line)
    return "".join(lines)


def rewrite_tree_prefixes(root: Path, old: str, new: str) -> int:
    changed = 0
    for path in root.rglob("*.pc"):
        original = path.read_text(encoding="utf-8", errors="replace")
        updated = rewrite_prefix_lines(original, old, new)
        if updated != original:
            path.write_text(updated, encoding="utf-8")
            changed += 1
    return changed


def collect_components(pkgconfig: Path) -> list[dict[str, str]]:
    components = []
    if not pkgconfig.is_dir():
        return components
    for path in sorted(pkgconfig.glob("*.pc")):
        fields = read_pc(path)
        components.append(
            {
                "pc": path.name[: -len(".pc")],
                "name": fields.get("name", path.stem),
                "version": fields.get("version", ""),
            }
        )
    return components


def write_gioopenssl_pc(destdir: Path, abi: str) -> None:
    archive = destdir / "lib" / abi / "gio" / "modules" / "libgioopenssl.a"
    if not archive.is_file():
        return
    pkgconfig = destdir / "lib" / abi / "pkgconfig"
    pkgconfig.mkdir(parents=True, exist_ok=True)
    # glib-networking's generated .pc describes the shared GIO module.
    # OLLMchat links the static archive and calls g_io_openssl_load().
    pc = pkgconfig / "gioopenssl.pc"
    pc.write_text(
        "\n".join(
            [
                "prefix=/",
                "libdir=${prefix}/lib/" + abi,
                "",
                "Name: gioopenssl",
                "Description: Static GIO OpenSSL TLS backend",
                "Version: 2.80.1",
                "Requires: gio-2.0",
                "Requires.private: libssl libcrypto",
                "Libs: ${libdir}/gio/modules/libgioopenssl.a",
                "Cflags:",
                "",
            ]
        ),
        encoding="utf-8",
    )


def copy_tree(src: Path, dest: Path) -> None:
    if not src.is_dir():
        raise SystemExit(f"Java glue directory missing: {src}")
    for path in src.rglob("*"):
        rel = path.relative_to(src)
        target = dest / rel
        if path.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        if not path.is_file():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(path.read_bytes())


def load_provided(path: Path) -> list[str]:
    names = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            names.append(line)
    if not names:
        raise SystemExit(f"No provided dependencies in {path}")
    return names


def finalize(args: argparse.Namespace) -> None:
    destdir = Path(args.destdir).resolve()
    abi = args.abi
    write_gioopenssl_pc(destdir, abi)
    rewrite_tree_prefixes(destdir, "/", TOKEN)
    glue_dest = destdir / "share" / "pixiewood" / "gtk-android-java"
    copy_tree(Path(args.java_glue).resolve(), glue_dest)
    pkgconfig_rel = f"lib/{abi}/pkgconfig"
    manifest = {
        "format": FORMAT,
        "name": "pixiewood-android-sysroot",
        "profile": args.profile,
        "version": args.version,
        "abi": abi,
        "arch": args.arch,
        "api": args.api,
        "ndk": args.ndk,
        "pixiewood_revision": args.pixiewood_revision,
        "ollmchat_wraps_revision": args.ollmchat_wraps_revision,
        "pkgconfig_dir": pkgconfig_rel,
        "java_glue": "share/pixiewood/gtk-android-java",
        "prefix_token": TOKEN,
        "provided_dependencies": load_provided(Path(args.provided)),
        "components": collect_components(destdir / pkgconfig_rel),
        "activated_prefix": None,
    }
    meta_dir = destdir / "share" / "pixiewood"
    meta_dir.mkdir(parents=True, exist_ok=True)
    (meta_dir / "MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {meta_dir / 'MANIFEST.json'} ({len(manifest['components'])} pkg-config files)")


def meson_quote(value: str) -> str:
    return "'" + value.replace("'", "\\'") + "'"


def write_wrapper(path: Path, pkgconfig_dir: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "\n".join(
            [
                "#!/bin/sh",
                "# Meson sets PKG_CONFIG_SYSROOT_DIR from the NDK sysroot.",
                "# These .pc files already use absolute paths in the pixiewood sysroot.",
                "unset PKG_CONFIG_SYSROOT_DIR",
                f"export PKG_CONFIG_LIBDIR={sh_quote(str(pkgconfig_dir))}",
                "export PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1",
                "export PKG_CONFIG_ALLOW_SYSTEM_LIBS=1",
                'exec pkg-config "$@"',
                "",
            ]
        ),
        encoding="utf-8",
    )
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


def sh_quote(value: str) -> str:
    return "'" + value.replace("'", "'\\''") + "'"


def script_binary(sysroot: Path, abi: str, name: str) -> Path | None:
    candidate = sysroot / "bin" / abi / name
    if not candidate.is_file():
        return None
    head = candidate.read_bytes()[:2]
    if head != b"#!":
        return None
    return candidate


def write_cross(sysroot: Path, abi: str, wrapper: Path) -> None:
    pkgconfig = sysroot / "lib" / abi / "pkgconfig"
    lines = [
        "[binaries]",
        f"pkg-config = [{meson_quote(str(wrapper))}]",
    ]
    for tool in ("glib-mkenums", "glib-genmarshal", "gdbus-codegen"):
        script = script_binary(sysroot, abi, tool)
        if script is not None:
            lines.append(
                f"{tool} = [{meson_quote('python3')}, {meson_quote(str(script))}]"
            )
    lines += [
        "",
        "[properties]",
        f"pkg_config_libdir = [{meson_quote(str(pkgconfig))}]",
        "",
    ]
    dest = sysroot / "share" / "pixiewood" / "sysroot.cross"
    dest.write_text("\n".join(lines), encoding="utf-8")


def activate(args: argparse.Namespace) -> None:
    sysroot = Path(args.sysroot).resolve()
    manifest_path = sysroot / "share" / "pixiewood" / "MANIFEST.json"
    if not manifest_path.is_file():
        raise SystemExit(f"Sysroot manifest missing: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("format") != FORMAT:
        raise SystemExit(f"Unsupported sysroot format: {manifest.get('format')}")
    abi = manifest["abi"]
    token = manifest.get("prefix_token", TOKEN)
    previous = manifest.get("activated_prefix")
    target = str(sysroot)
    if previous == target and not any(TOKEN in path.read_text(encoding="utf-8", errors="replace") for path in (sysroot / "lib" / abi / "pkgconfig").glob("*.pc")):
        pass
    else:
        rewrite_tree_prefixes(sysroot, token, target)
        if previous and previous != target:
            rewrite_tree_prefixes(sysroot, previous, target)
    wrapper = sysroot / "share" / "pixiewood" / "pkg-config-wrapper"
    write_wrapper(wrapper, sysroot / "lib" / abi / "pkgconfig")
    write_cross(sysroot, abi, wrapper)
    manifest["activated_prefix"] = target
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Activated {sysroot}")
    print(f"Meson cross file: {sysroot / 'share' / 'pixiewood' / 'sysroot.cross'}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    fin = sub.add_parser("finalize", help="prepare an installed prefix for packing")
    fin.add_argument("--destdir", required=True)
    fin.add_argument("--profile", required=True)
    fin.add_argument("--version", required=True)
    fin.add_argument("--abi", required=True)
    fin.add_argument("--arch", required=True)
    fin.add_argument("--api", type=int, required=True)
    fin.add_argument("--ndk", required=True)
    fin.add_argument("--pixiewood-revision", required=True)
    fin.add_argument("--ollmchat-wraps-revision", required=True)
    fin.add_argument("--provided", required=True)
    fin.add_argument("--java-glue", required=True)
    fin.set_defaults(func=finalize)

    act = sub.add_parser("activate", help="bind a sysroot to its extract path")
    act.add_argument("sysroot")
    act.set_defaults(func=activate)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
