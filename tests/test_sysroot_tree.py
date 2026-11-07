#!/usr/bin/env python3
"""Pack, activate, and stage a fake sysroot without the Android NDK."""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PY = ROOT / "scripts" / "sysroot_tree.py"


class SysrootTreeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="pixiewood-sysroot-"))
        self.destdir = self.tmp / "destdir"
        abi = "arm64-v8a"
        pkg = self.destdir / "lib" / abi / "pkgconfig"
        pkg.mkdir(parents=True)
        (pkg / "gtk4.pc").write_text(
            "prefix=/\n"
            "libdir=${prefix}/lib/arm64-v8a\n"
            "includedir=${prefix}/include\n"
            "Name: gtk4\n"
            "Description: GTK\n"
            "Version: 4.18.0\n"
            "Libs: -L${libdir} -lgtk-4\n"
            "Cflags: -I${includedir}/gtk-4.0\n",
            encoding="utf-8",
        )
        (pkg / "glib-2.0.pc").write_text(
            "prefix=/\nName: glib\nVersion: 2.90.0\nLibs: -L${prefix}/lib/arm64-v8a -lglib-2.0\n",
            encoding="utf-8",
        )
        libdir = self.destdir / "lib" / abi
        (libdir / "libgtk-4.so").write_text("not-a-real-elf", encoding="utf-8")
        modules = libdir / "gio" / "modules"
        modules.mkdir(parents=True)
        (modules / "libgioopenssl.a").write_bytes(b"archive")
        schemas = self.destdir / "share" / "glib-2.0" / "schemas"
        schemas.mkdir(parents=True)
        (schemas / "org.gtk.Settings.gschema.xml").write_text("<schema/>", encoding="utf-8")
        glue = self.tmp / "java"
        java = glue / "org" / "gtk" / "android"
        java.mkdir(parents=True)
        (java / "ToplevelActivity.java").write_text("class ToplevelActivity {}", encoding="utf-8")
        provided = self.tmp / "provided.txt"
        provided.write_text("glib\ngtk\nopenssl\n", encoding="utf-8")
        subprocess.run(
            [
                "python3",
                str(PY),
                "finalize",
                "--destdir",
                str(self.destdir),
                "--profile",
                "ollmchat",
                "--version",
                "0.1.0",
                "--abi",
                abi,
                "--arch",
                "aarch64",
                "--api",
                "31",
                "--ndk",
                "28.2.13676358",
                "--pixiewood-revision",
                "abc",
                "--ollmchat-wraps-revision",
                "def",
                "--provided",
                str(provided),
                "--java-glue",
                str(glue),
            ],
            check=True,
        )

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp)

    def test_finalize_rewrites_prefix_and_records_manifest(self) -> None:
        gtk = (self.destdir / "lib/arm64-v8a/pkgconfig/gtk4.pc").read_text(encoding="utf-8")
        self.assertIn("prefix=@PIXIEWOOD_SYSROOT@", gtk)
        self.assertNotIn("prefix=/", gtk)
        gio = (self.destdir / "lib/arm64-v8a/pkgconfig/gioopenssl.pc").read_text(encoding="utf-8")
        self.assertIn("prefix=@PIXIEWOOD_SYSROOT@", gio)
        self.assertIn("libgioopenssl.a", gio)
        manifest = json.loads(
            (self.destdir / "share/pixiewood/MANIFEST.json").read_text(encoding="utf-8")
        )
        self.assertEqual(manifest["format"], 1)
        self.assertEqual(manifest["provided_dependencies"], ["glib", "gtk", "openssl"])
        names = {item["pc"] for item in manifest["components"]}
        self.assertIn("gtk4", names)
        self.assertIn("gioopenssl", names)
        java = self.destdir / "share/pixiewood/gtk-android-java/org/gtk/android/ToplevelActivity.java"
        self.assertTrue(java.is_file())

    def test_activate_and_stage(self) -> None:
        subprocess.run(["python3", str(PY), "activate", str(self.destdir)], check=True)
        gtk = (self.destdir / "lib/arm64-v8a/pkgconfig/gtk4.pc").read_text(encoding="utf-8")
        self.assertIn(f"prefix={self.destdir}", gtk)
        cross = (self.destdir / "share/pixiewood/sysroot.cross").read_text(encoding="utf-8")
        self.assertIn("pkg-config", cross)
        self.assertNotIn("sys_root", cross)
        wrapper = self.destdir / "share/pixiewood/pkg-config-wrapper"
        self.assertTrue(wrapper.stat().st_mode & 0o111)
        root = self.tmp / "pixiewood-root"
        subprocess.run(
            [str(ROOT / "scripts/stage-runtime.sh"), str(self.destdir), str(root)],
            check=True,
        )
        self.assertTrue((root / "lib/arm64-v8a/libgtk-4.so").is_file())
        self.assertTrue(
            (root / "share/glib-2.0/schemas/org.gtk.Settings.gschema.xml").is_file()
        )
        # Moving the tree and activating again rewrites the prefix.
        moved = self.tmp / "moved"
        shutil.move(str(self.destdir), moved)
        subprocess.run(["python3", str(PY), "activate", str(moved)], check=True)
        gtk = (moved / "lib/arm64-v8a/pkgconfig/gtk4.pc").read_text(encoding="utf-8")
        self.assertIn(f"prefix={moved}", gtk)
        self.assertNotIn(f"prefix={self.destdir}", gtk)


if __name__ == "__main__":
    unittest.main()
