#!/usr/bin/env python3
"""Tests for scripts/ipa_tool.py using synthetic IPAs (no proprietary binaries)."""
import io
import os
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

TOOL = os.path.join(os.path.dirname(__file__), "..", "scripts", "ipa_tool.py")


def macho(dylibs, cryptid=0, fat=False):
    commands = b""
    for name in dylibs:
        raw = name.encode() + b"\0"
        size = (24 + len(raw) + 7) & ~7
        commands += struct.pack("<IIIIII", 0xC, size, 24, 2, 0x10000, 0x10000) + raw.ljust(size - 24, b"\0")
    commands += struct.pack("<IIIIII", 0x2C, 24, 0x4000, 0x1000, cryptid, 0)
    ncmds = len(dylibs) + 1
    thin = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, ncmds, len(commands), 0, 0) + commands
    if not fat:
        return thin
    header = struct.pack(">II", 0xCAFEBABE, 1) + struct.pack(">iiIII", 0x0100000C, 0, 4096, len(thin), 14)
    return header.ljust(4096, b"\0") + thin


def make_ipa(path, version="21.42.4", bundle="com.google.ios.youtube", dylibs=(), files=(), cryptid=0, fat=False, extra_plist=None):
    info = {"CFBundleExecutable": "YouTube", "CFBundleIdentifier": bundle, "CFBundleShortVersionString": version, "CFBundleVersion": version}
    info.update(extra_plist or {})
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("Payload/YouTube.app/Info.plist", plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        archive.writestr("Payload/YouTube.app/YouTube", macho(list(dylibs), cryptid, fat))
        for name in files:
            archive.writestr("Payload/YouTube.app/" + name, b"dylib")


def run(*args):
    return subprocess.run([sys.executable, "-I", TOOL, *args], capture_output=True, text=True)


class IPAToolTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.ipa = os.path.join(self.dir.name, "yt.ipa")

    def tearDown(self):
        self.dir.cleanup()

    def test_inspect_accepts_target(self):
        make_ipa(self.ipa)
        result = run("inspect", self.ipa, "--expect-version", "21.42.4", "--expect-bundle", "com.google.ios.youtube", "--require-decrypted")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("21.42.4", result.stdout)

    def test_inspect_rejects_wrong_version(self):
        make_ipa(self.ipa, version="20.21.6")
        result = run("inspect", self.ipa, "--expect-version", "21.42.4")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("::error::", result.stdout)

    def test_inspect_allows_other_version_with_flag(self):
        make_ipa(self.ipa, version="21.43.5")
        result = run("inspect", self.ipa, "--expect-version", "21.42.4", "--allow-other-version")
        self.assertEqual(result.returncode, 0)
        self.assertIn("::warning::", result.stdout)

    def test_inspect_rejects_encrypted_and_wrong_bundle(self):
        make_ipa(self.ipa, cryptid=1)
        self.assertNotEqual(run("inspect", self.ipa, "--require-decrypted").returncode, 0)
        make_ipa(self.ipa, bundle="com.example.app")
        self.assertNotEqual(run("inspect", self.ipa, "--expect-bundle", "com.google.ios.youtube").returncode, 0)

    def test_inspect_rejects_non_zip(self):
        with open(self.ipa, "wb") as handle:
            handle.write(b"<html>not an ipa</html>")
        self.assertNotEqual(run("inspect", self.ipa).returncode, 0)

    def test_verify_requires_loaded_dylibs(self):
        make_ipa(self.ipa, dylibs=["@rpath/MaxTubePlus.dylib", "@rpath/YTLite.dylib"],
                 files=["Frameworks/MaxTubePlus.dylib", "Frameworks/YTLite.dylib"], fat=True,
                 extra_plist={"CADisableMinimumFrameDurationOnPhone": True})
        ok = run("verify", self.ipa, "--dylib", "MaxTubePlus.dylib", "--dylib", "YTLite.dylib", "--plist-key", "CADisableMinimumFrameDurationOnPhone")
        self.assertEqual(ok.returncode, 0, ok.stdout)
        # Bundled but not loaded -> failure (silently skipped injection).
        make_ipa(self.ipa, dylibs=["@rpath/YTLite.dylib"], files=["Frameworks/MaxTubePlus.dylib", "Frameworks/YTLite.dylib"])
        bad = run("verify", self.ipa, "--dylib", "MaxTubePlus.dylib")
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn("not loaded", bad.stdout)
        # Missing plist key -> failure.
        make_ipa(self.ipa, dylibs=["@rpath/MaxTubePlus.dylib"], files=["Frameworks/MaxTubePlus.dylib"])
        self.assertNotEqual(run("verify", self.ipa, "--dylib", "MaxTubePlus.dylib", "--plist-key", "CADisableMinimumFrameDurationOnPhone").returncode, 0)

    def test_inspect_maxtube_ipa_with_custom_bundle(self):
        make_ipa(self.ipa, bundle="com.example.maxtube", dylibs=["@rpath/YTLite.dylib"], files=["Frameworks/YTLite.dylib"])
        ok = run("inspect", self.ipa, "--expect-executable", "YouTube", "--require-dylib", "YTLite.dylib", "--require-decrypted")
        self.assertEqual(ok.returncode, 0, ok.stdout)
        make_ipa(self.ipa)  # plain YouTube, no YTPlus
        bad = run("inspect", self.ipa, "--require-dylib", "YTLite.dylib")
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn("MaxTube/YTPlus IPA", bad.stdout)

    def test_locate_reports_existing_injection(self):
        out = os.path.join(self.dir.name, "out.txt")
        make_ipa(self.ipa, dylibs=["@rpath/MaxTubePlus.dylib"], files=["Frameworks/MaxTubePlus.dylib"])
        result = run("locate", self.ipa, "MaxTubePlus.dylib", "--github-output", out)
        self.assertEqual(result.returncode, 0)
        with open(out) as handle:
            data = dict(line.split("=", 1) for line in handle.read().splitlines())
        self.assertEqual(data["bundled"], "true")
        self.assertEqual(data["path"], "Frameworks/MaxTubePlus.dylib")
        self.assertEqual(data["loaded"], "true")
        os.remove(out)
        make_ipa(self.ipa)
        run("locate", self.ipa, "MaxTubePlus.dylib", "--github-output", out)
        with open(out) as handle:
            self.assertIn("bundled=false", handle.read())

    def test_patch_plist_is_idempotent_and_keeps_format(self):
        path = os.path.join(self.dir.name, "Info.plist")
        with open(path, "wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "com.google.ios.youtube"}, handle, fmt=plistlib.FMT_BINARY)
        self.assertEqual(run("patch-plist", path).returncode, 0)
        second = run("patch-plist", path)
        self.assertIn("already up to date", second.stdout)
        with open(path, "rb") as handle:
            data = handle.read()
        self.assertTrue(data.startswith(b"bplist"))
        info = plistlib.loads(data)
        self.assertTrue(info["CADisableMinimumFrameDurationOnPhone"])
        self.assertEqual(info["CFBundleIdentifier"], "com.google.ios.youtube")


if __name__ == "__main__":
    unittest.main(verbosity=2)
