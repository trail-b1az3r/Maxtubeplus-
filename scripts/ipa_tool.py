#!/usr/bin/env python3
"""MaxTubePlus IPA helper used by the GitHub Actions workflows.

Subcommands
  inspect  IPA [--expect-version V] [--expect-bundle B] [--require-decrypted]
           Prints app metadata; fails on version/bundle mismatch or an
           encrypted (FairPlay) main binary.
  locate   IPA NAME [--github-output FILE]
           Reports whether NAME (e.g. MaxTubePlus.dylib) is bundled, where,
           and whether the main executable loads it. Never fails on absence.
  patch-plist INFO_PLIST
           Adds the keys MaxTubePlus needs (120Hz on iPhone, Files access to
           the downloads folder). Idempotent.
  verify   IPA --dylib NAME [--dylib NAME ...] [--plist-key KEY ...]
           Fails unless every dylib is inside the app AND referenced by a
           LC_LOAD(_WEAK)_DYLIB command of the main executable (i.e. it will
           actually load), and the Info.plist keys are present.

Pure standard library; works on macOS and Linux runners. Never prints or
stores signing material.
"""
import argparse
import plistlib
import struct
import sys
import zipfile

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_ENCRYPTION_INFO_64 = 0x2C
CPU_TYPE_ARM64 = 0x0100000C

REQUIRED_PLIST_KEYS = {
    "CADisableMinimumFrameDurationOnPhone": True,  # allow >60Hz on ProMotion iPhones
    "UIFileSharingEnabled": True,                  # downloads visible in Files
    "LSSupportsOpeningDocumentsInPlace": True,
}


def fail(message):
    # GitHub Actions error annotation + non-zero exit.
    print(f"::error::{message}")
    sys.exit(1)


def find_app_root(names):
    roots = sorted({n.split("/")[1] for n in names if n.startswith("Payload/") and n.count("/") >= 2 and n.split("/")[1].endswith(".app")})
    if len(roots) != 1:
        fail(f"Expected exactly one Payload/*.app, found {roots or 'none'}")
    return f"Payload/{roots[0]}/"


def parse_macho(data):
    """Returns (dylibs, cryptid or None) for the arm64 slice."""
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        count = struct.unpack_from(">I", data, 4)[0]
        for i in range(count):
            if magic == FAT_MAGIC:
                cputype, _, offset, size, _ = struct.unpack_from(">iiIII", data, 8 + i * 20)
            else:
                cputype, _, offset, size, _, _ = struct.unpack_from(">iiQQII", data, 8 + i * 32)
            if cputype == CPU_TYPE_ARM64:
                return parse_macho(data[offset:offset + size])
        fail("No arm64 slice in main executable")
    if struct.unpack_from("<I", data, 0)[0] != MH_MAGIC_64:
        fail("Main executable is not a 64-bit Mach-O")
    ncmds = struct.unpack_from("<I", data, 16)[0]
    offset = 32
    dylibs, cryptid = [], None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            raw = data[offset + name_offset:offset + size]
            dylibs.append(raw.split(b"\0", 1)[0].decode("utf-8", "replace"))
        elif cmd == LC_ENCRYPTION_INFO_64:
            cryptid = struct.unpack_from("<I", data, offset + 16)[0]
        offset += size
    return dylibs, cryptid


def load_app(path):
    try:
        archive = zipfile.ZipFile(path)
    except zipfile.BadZipFile:
        fail(f"{path} is not a valid IPA (zip) file")
    names = archive.namelist()
    root = find_app_root(names)
    try:
        info = plistlib.loads(archive.read(root + "Info.plist"))
    except KeyError:
        fail("Info.plist missing from app bundle")
    executable = info.get("CFBundleExecutable")
    if not executable or root + executable not in names:
        fail(f"Main executable '{executable}' missing")
    dylibs, cryptid = parse_macho(archive.read(root + executable))
    return archive, names, root, info, dylibs, cryptid


def cmd_inspect(args):
    _, names, root, info, dylibs, cryptid = load_app(args.ipa)
    version = info.get("CFBundleShortVersionString", "?")
    bundle = info.get("CFBundleIdentifier", "?")
    print(f"App:        {root}")
    print(f"Bundle ID:  {bundle}")
    print(f"Version:    {version} (build {info.get('CFBundleVersion', '?')})")
    print(f"MinimumOS:  {info.get('MinimumOSVersion', '?')}")
    print(f"Encrypted:  {'yes' if cryptid else 'no'}")
    print(f"Injected:   {', '.join(d for d in dylibs if not d.startswith('/System') and not d.startswith('/usr/lib')) or 'none'}")
    if args.github_env:
        with open(args.github_env, "a") as env:
            env.write(f"YT_VERSION={version}\nYT_BUNDLE_ID={bundle}\n")
    if args.require_decrypted and cryptid:
        fail("The IPA's main binary is FairPlay-encrypted (cryptid=1). A decrypted IPA you are authorised to use is required.")
    executable = info.get("CFBundleExecutable", "")
    if args.expect_executable and executable != args.expect_executable:
        fail(f"Main executable is '{executable}', expected '{args.expect_executable}'. This is not the YouTube app.")
    for dylib in args.require_dylib:
        if not any(d.endswith("/" + dylib) for d in dylibs):
            fail(f"{dylib} is not injected in this IPA. Expected a MaxTube/YTPlus IPA (YTPlus provides {dylib}).")
    if args.expect_bundle and bundle != args.expect_bundle:
        fail(f"Bundle ID is {bundle}, expected {args.expect_bundle}. This is not the YouTube app.")
    if args.expect_version and version != args.expect_version:
        message = f"YouTube version is {version}, MaxTubePlus targets {args.expect_version}."
        if args.allow_other_version:
            print(f"::warning::{message} Continuing because allow_other_version is set; modules self-check at runtime.")
        else:
            fail(message + " Supply the target version or set allow_other_version.")


def cmd_locate(args):
    _, names, root, info, dylibs, cryptid = load_app(args.ipa)
    files = [n for n in names if n.startswith(root) and n.endswith("/" + args.name)]
    loaded = any(d.endswith("/" + args.name) for d in dylibs)
    path = files[0][len(root):] if files else ""
    print(f"{args.name}: {'bundled at ' + path if path else 'not bundled'}; {'loaded' if loaded else 'not loaded'} by the main executable")
    if args.github_output:
        with open(args.github_output, "a") as out:
            out.write(f"bundled={'true' if path else 'false'}\npath={path}\nloaded={'true' if loaded else 'false'}\napp_root={root}\n")


def cmd_patch_plist(args):
    with open(args.plist, "rb") as handle:
        data = handle.read()
    fmt = plistlib.FMT_BINARY if data.startswith(b"bplist") else plistlib.FMT_XML
    info = plistlib.loads(data)
    changed = []
    for key, value in REQUIRED_PLIST_KEYS.items():
        if info.get(key) != value:
            info[key] = value
            changed.append(key)
    with open(args.plist, "wb") as handle:
        plistlib.dump(info, handle, fmt=fmt)
    print(f"Patched {args.plist}: {', '.join(changed) if changed else 'already up to date'}")


def cmd_verify(args):
    _, names, root, info, dylibs, cryptid = load_app(args.ipa)
    problems = []
    for dylib in args.dylib:
        files = [n for n in names if n.startswith(root) and n.endswith("/" + dylib)]
        if not files:
            problems.append(f"{dylib} is not inside the app bundle")
            continue
        if not any(d.endswith("/" + dylib) for d in dylibs):
            problems.append(f"{dylib} is bundled but not loaded by the main executable (no LC_LOAD_DYLIB)")
        else:
            print(f"OK  {dylib}: {files[0][len(root):]} (loaded)")
    for key in args.plist_key:
        if not info.get(key):
            problems.append(f"Info.plist key {key} missing")
        else:
            print(f"OK  Info.plist {key}={info.get(key)}")
    if cryptid:
        problems.append("Main binary is encrypted; the IPA will not run with injected tweaks")
    if problems:
        for problem in problems:
            print(f"::error::{problem}")
        sys.exit(1)
    print(f"Verified {args.ipa}: {len(args.dylib)} dylib(s), {len(args.plist_key)} plist key(s)")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("inspect")
    p.add_argument("ipa")
    p.add_argument("--expect-version")
    p.add_argument("--expect-bundle")
    p.add_argument("--allow-other-version", action="store_true")
    p.add_argument("--require-decrypted", action="store_true")
    p.add_argument("--github-env")
    p.add_argument("--expect-executable")
    p.add_argument("--require-dylib", action="append", default=[])
    p.set_defaults(func=cmd_inspect)
    p = sub.add_parser("locate")
    p.add_argument("ipa")
    p.add_argument("name")
    p.add_argument("--github-output")
    p.set_defaults(func=cmd_locate)
    p = sub.add_parser("patch-plist")
    p.add_argument("plist")
    p.set_defaults(func=cmd_patch_plist)
    p = sub.add_parser("verify")
    p.add_argument("ipa")
    p.add_argument("--dylib", action="append", default=[])
    p.add_argument("--plist-key", action="append", default=[])
    p.set_defaults(func=cmd_verify)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
