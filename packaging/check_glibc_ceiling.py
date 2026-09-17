"""Fail the build if a shipped ELF demands a glibc newer than the target distro provides.

The frozen CPython, every extension module, and every binary wheel carry the glibc of the
machine that produced them, and glibc versions only go forward. A binary that needs
`GLIBC_2.34` prints `version 'GLIBC_2.34' not found` and refuses to start on a host with
2.31 — which is exactly the failure a "works on my runner" build ships to the user. So the
ceiling is asserted at build time against the OLDEST distro we claim, and the failure names
the offending files.

Why this parses the ELF instead of grepping the bytes: a naive `GLIBC_(\\d+)\\.(\\d+)` scan
over the whole file is wrong in both directions. Version strings sit in a shared string table
where entries can run together without a NUL (`GLIBC_2.17` immediately followed by `38`
scans as the nonexistent version `2.1738`), and a compressed payload's raw literal runs are
full of near-misses. The authoritative source is `.gnu.version_r` (SHT_GNU_verneed) — the
table the dynamic loader itself consults — reached through the section headers and read
through its linked string table, the same data `readelf -V` reports.

Files without section headers or without a verneed table are counted and reported (never
silently skipped): a stripped binary would otherwise pass by default.

Usage:
    check_glibc_ceiling.py --max 2.31 <dir-or-file> [more…]
Exit status is 1 when anything exceeds the ceiling, so CI stops the release.
"""

from __future__ import annotations

import argparse
import os
import re
import struct
import sys

# ELF / section-header constants (64-bit only; these bundles are aarch64/x86-64).
SHT_GNU_VERNEED = 0x6FFFFFFE
VERNEED = "<HHIII"  # vn_version, vn_cnt, vn_file, vn_aux, vn_next
VERNAUX = "<IHHII"  # vna_hash, vna_flags, vna_other, vna_name, vna_next

# libc itself must NOT travel inside the bundle: the loader and libc are a matched pair with
# the kernel, so shipping one copy that suits every target is what turns "portable" into
# "version 'GLIBC_2.39' not found".
FORBIDDEN = ("libc.so.6", "ld-linux", "ld.so.", "libpthread.so", "libm.so.6", "libdl.so.2")

# One pattern per version namespace; only GLIBC_ gates the ceiling, the rest are reported.
NAMESPACES = {
    "glibc": re.compile(r"^GLIBC_(\d+(?:\.\d+)*)$"),
    "glibcxx": re.compile(r"^GLIBCXX_(\d+(?:\.\d+)*)$"),
    "cxxabi": re.compile(r"^CXXABI_(\d+(?:\.\d+)*)$"),
}


def parse_version(text: str) -> tuple[int, int, int]:
    """`2.31`/`2.2.5`/`3.4.29` → a 3-tuple so comparisons never straddle formats."""
    parts = [int(p) for p in text.split(".")][:3]
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts)  # type: ignore[return-value]


def fmt(v: tuple[int, int, int]) -> str:
    return "%d.%d%s" % (v[0], v[1], ".%d" % v[2] if v[2] else "")


def _cstr(blob: bytes, off: int) -> str:
    end = blob.find(b"\0", off)
    if end < 0:
        return ""
    return blob[off:end].decode("ascii", "replace")


class ScanResult:
    __slots__ = ("names", "note")

    def __init__(self, names: list[str], note: str = ""):
        self.names = names
        self.note = note


def scan_bytes(data: bytes) -> ScanResult | None:
    """Required version symbols of an in-memory ELF image, or None when it is not a 64-bit LE ELF."""
    if len(data) < 64 or data[:4] != b"\x7fELF":
        return None
    if data[4] != 2 or data[5] != 1:  # not ELFCLASS64 / not little-endian
        return None

    e_shoff, = struct.unpack_from("<Q", data, 0x28)
    e_shentsize, e_shnum = struct.unpack_from("<HH", data, 0x3A)
    if e_shoff == 0 or e_shnum == 0 or e_shoff + e_shnum * e_shentsize > len(data):
        return ScanResult([], "no section headers")

    verneed = None
    strtab_off = strtab_size = 0
    sections = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        sh_type, = struct.unpack_from("<I", data, off + 4)
        sh_offset, sh_size = struct.unpack_from("<QQ", data, off + 24)
        sh_link, = struct.unpack_from("<I", data, off + 40)
        sections.append((sh_type, sh_offset, sh_size, sh_link))
    for sh_type, sh_offset, sh_size, sh_link in sections:
        if sh_type == SHT_GNU_VERNEED:
            verneed = (sh_offset, sh_size)
            if sh_link < len(sections):
                strtab_off, strtab_size = sections[sh_link][1], sections[sh_link][2]
            break
    if verneed is None:
        # Statically linked or versionless: nothing for the loader to check at startup.
        return ScanResult([], "no version-needs table")
    if strtab_size == 0 or strtab_off + strtab_size > len(data):
        return ScanResult([], "version-needs table has no linked string table")

    strtab = data[strtab_off:strtab_off + strtab_size]
    names: list[str] = []
    base, size = verneed
    pos = 0
    # vn_next/vna_next are 0-terminated forward offsets; bound the walk defensively.
    while pos + struct.calcsize(VERNEED) <= size:
        _ver, cnt, _file, aux, nxt = struct.unpack_from(VERNEED, data, base + pos)
        a = base + pos + aux
        for _ in range(cnt):
            if a + struct.calcsize(VERNAUX) > base + size:
                break
            _hash, _flags, _other, name_off, a_next = struct.unpack_from(VERNAUX, data, a)
            if name_off < len(strtab):
                name = _cstr(strtab, name_off)
                if name:
                    names.append(name)
            if a_next == 0:
                break
            a += a_next
        if nxt == 0:
            break
        pos += nxt
    return ScanResult(names)


def scan(path: str) -> ScanResult | None:
    """Required version symbols of one file, or None when it is not a 64-bit little-endian ELF."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return None
    return scan_bytes(data)


def appimage_runtime(path: str):
    """Inspect ONLY the AppImage runtime — the ELF stub before the squashfs payload.

    Returns (magic_bytes, has_interp, ScanResult-of-runtime) or None when the file is not an
    AppImage-shaped ELF. We deliberately slice the runtime out instead of scanning the whole
    file, so the bundled GUI stack (already asserted in the AppDir pass) is not double-counted
    and a 150 MB squashfs is never read into memory.

    Why the runtime is checked separately at all: an AppImage's container half is itself an ELF.
    If IT needs a newer glibc than the target, the whole bundle dies before FUSE/mount ever runs
    — for any payload. Whether the runtime is statically linked (no PT_INTERP) or dynamically
    linked (PT_INTERP present) is irrelevant to correctness as long as its own GLIBC_* demand is
    ≤ the ceiling; AppImageKit's `appimagetool` ships a dynamic runtime that only needs very old
    symbols, so it runs fine on glibc 2.31. We therefore report PT_INTERP but only FAIL on the
    actual version demand.
    """
    try:
        with open(path, "rb") as f:
            size = os.fstat(f.fileno()).st_size
            if size < 16:
                return None
            f.seek(-8, 2)
            sqoff, = struct.unpack("<Q", f.read(8))  # squashfs filesystem offset
            f.seek(0)
            head = f.read(min(size, max(sqoff + 8192, 1 << 22)))
    except OSError:
        return None
    if head[:4] != b"\x7fELF":
        return None
    magic = head[8:11]
    e_phoff, = struct.unpack_from("<Q", head, 0x20)
    e_phentsize, e_phnum = struct.unpack_from("<HH", head, 0x36)
    has_interp = False
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        if off + 4 > len(head):
            break
        if struct.unpack_from("<I", head, off)[0] == 3:  # PT_INTERP
            has_interp = True
            break
    # The runtime ELF occupies bytes [0, sqoff); scan just that span.
    blob = head if sqoff > len(head) else head[:sqoff]
    return (magic, has_interp, scan_bytes(blob))


def walk(targets: list[str]):
    for target in targets:
        if os.path.isfile(target):
            yield target
            continue
        for root, _dirs, files in os.walk(target):
            for name in files:
                yield os.path.join(root, name)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="check_glibc_ceiling")
    parser.add_argument("--max", required=True, help="oldest glibc the artifact must run on")
    parser.add_argument("--appimage", action="store_true",
                        help="targets are AppImage files; check only the runtime ELF, not the payload")
    parser.add_argument("targets", nargs="+")
    args = parser.parse_args(argv)

    if args.appimage:
        return main_appimage(args)

    ceiling = parse_version(args.max)
    offenders: list[tuple[tuple[int, int, int], list[str], str]] = []
    maxima = {"glibc": (0, 0, 0), "glibcxx": (0, 0, 0), "cxxabi": (0, 0, 0)}
    parsed = no_table = no_sections = not_elf = 0
    libc_hits: list[str] = []
    samples: list[str] = []

    for path in walk(args.targets):
        got = scan(path)
        if got is None:
            not_elf += 1
            continue
        if got.note:
            if got.note == "no section headers":
                no_sections += 1
            else:
                no_table += 1
            continue
        parsed += 1
        hit = {k: (0, 0, 0) for k in maxima}
        for name in got.names:
            for key, pattern in NAMESPACES.items():
                m = pattern.match(name)
                if m:
                    v = parse_version(m.group(1))
                    if v > hit[key]:
                        hit[key] = v
                    break
        for key in maxima:
            if hit[key] > maxima[key]:
                maxima[key] = hit[key]
        if len(samples) < 5:
            samples.append("%s -> %s" % (os.path.basename(path), ", ".join(sorted(set(got.names))[:6])))
        base = os.path.basename(path)
        if any(base.startswith(p) for p in FORBIDDEN):
            libc_hits.append(path)
        if hit["glibc"] > ceiling:
            offenders.append((hit["glibc"], sorted(set(got.names))[:8], path))

    print("glibc ceiling check: ceiling GLIBC_%s" % fmt(ceiling))
    print("  ELF with a version-needs table : %d" % parsed)
    print("  ELF without one (nothing to check): %d" % no_table)
    print("  ELF without section headers    : %d" % no_sections)
    print("  non-ELF files                  : %d" % not_elf)
    print("  highest demand: GLIBC_%s" % fmt(maxima["glibc"]), end="")
    for key in ("glibcxx", "cxxabi"):
        if maxima[key] != (0, 0, 0):
            print("  %s_%s" % (key.upper(), fmt(maxima[key])), end="")
    print()

    for s in samples:
        print("  e.g. %s" % s)

    if libc_hits:
        # Not fatal (a bundled libc can be deliberate), but never silent: it is the classic
        # cause of "runs on the build host only".
        print("  WARNING: libc/loader shipped in the bundle:")
        for p in libc_hits[:10]:
            print("    %s" % p)

    if not offenders:
        print("  OK — nothing exceeds the ceiling")
        return 0

    offenders.sort(key=lambda r: (-r[0][0], -r[0][1], r[2]))
    print("  FAIL — %d file(s) demand a newer glibc:" % len(offenders))
    for v, _names, path in offenders[:60]:
        print("    GLIBC_%-8s %s" % (fmt(v), path))
    if len(offenders) > 60:
        print("    … and %d more" % (len(offenders) - 60))
    return 1


def main_appimage(args) -> int:
    """`--appimage`: assert each AppImage's runtime ELF is satisfiable by the glibc ceiling.

    The payload is checked separately (the build runs this over the AppDir too), so here we only
    look at the container's own ELF — the thing that must run before the squashfs is ever mounted.
    """
    ceiling = parse_version(args.max)
    offenders: list[str] = []
    print("AppImage runtime glibc check: ceiling GLIBC_%s" % fmt(ceiling))

    for path in args.targets:
        info = appimage_runtime(path)
        if info is None:
            print("  %s" % path)
            print("    NOT an AppImage-shaped ELF — refusing to guess")
            offenders.append(path)
            continue
        magic, has_interp, res = info
        print("  %s" % path)
        print("    type-2 magic : %s  (%s)" % (
            "OK" if magic in (b"AI\x01", b"AI\x02") else "NOT AppImage!", magic.hex()))
        print("    runtime PT_INTERP: %s" % (
            "present — runtime links the host loader (fine if its GLIBC demand is low)"
            if has_interp else "absent — runtime is statically linked"))
        if res is None:
            print("    runtime is not a parseable 64-bit LE ELF")
            offenders.append(path)
            continue
        if res.note:
            if res.note == "no version-needs table":
                # Statically linked / versionless runtime: the loader has nothing to check.
                print("    runtime version needs: none — no GLIBC demand, OK")
            else:
                # Stripped runtime: version_needs is only reachable through section headers, so we
                # cannot prove its GLIBC demand here. Say so rather than pretend; the smoke-appimage
                # job actually launches the bundle on glibc 2.31 and is the real gate.
                print("    WARNING: %s — cannot statically verify the runtime's GLIBC demand" % res.note)
                print("             (smoke-appimage runs it on glibc %s to confirm)" % args.max)
            continue
        hit = (0, 0, 0)
        for name in res.names:
            m = NAMESPACES["glibc"].match(name)
            if m:
                v = parse_version(m.group(1))
                if v > hit:
                    hit = v
        print("    runtime demands: GLIBC_%s" % fmt(hit))
        if hit > ceiling:
            print("    FAIL — runtime needs newer glibc than %s" % args.max)
            offenders.append(path)

    if not offenders:
        print("  OK — every AppImage runtime is satisfiable by glibc %s" % args.max)
        return 0
    print("  FAIL — %d AppImage(s) fail the runtime check:" % len(offenders))
    for p in offenders:
        print("    %s" % p)
    return 1


if __name__ == "__main__":
    sys.exit(main())
