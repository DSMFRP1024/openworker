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


def scan(path: str) -> ScanResult | None:
    """Required version symbols of one file, or None when it is not a 64-bit little-endian ELF."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return None
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
    parser.add_argument("targets", nargs="+")
    args = parser.parse_args(argv)

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


if __name__ == "__main__":
    sys.exit(main())
