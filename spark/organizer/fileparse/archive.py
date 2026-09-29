"""Archives: zip, tar, gzip / bzip2 / xz. Each entry is read by its own type (recursively, depth <= 2),
at most 200 entries and 100 MB uncompressed per file; members are never written to disk and their
paths are never used for anything but a label.
"""

from __future__ import annotations

import bz2
import io
import lzma
import tarfile
import zlib
from typing import Callable

from .core import TEXT_CAP, Budget, ParseError, Parsed, clip, ext_of
from .pkg import Package, is_bomb

JUNK = ("__MACOSX/", ".DS_Store", "Thumbs.db", "desktop.ini", "._")


def _junk(name: str) -> bool:
    base = name.rsplit("/", 1)[-1]
    return name.startswith("__MACOSX/") or base in (".DS_Store", "Thumbs.db", "desktop.ini") or base.startswith("._")


def _summary(p: Parsed) -> str:
    from .mail import _attachment_summary
    return _attachment_summary(p)


def _render(entries: list[tuple[str, Parsed]], skipped: list[dict], total: int, kind: str) -> Parsed:
    readable = [e for e in entries if e[1].text]
    per = max(1500, TEXT_CAP // max(1, len(readable)))
    blocks = [f"{kind}，共 {total} 个文件"]
    listed = []
    for name, p in entries:
        listed.append({"filename": name, "type": p.type, "summary": _summary(p)})
        if p.text:
            t, cut = clip(p.text, per)
            blocks.append(f"## {name}\n{t}" + ("\n（已截断）" if cut else ""))
    listed += skipped
    if skipped:
        blocks.append("未读取：" + "、".join(f"{s['filename']}（{s['summary']}）" for s in skipped[:50]))
    return Parsed("archive", "\n\n".join(blocks), "", {"entries": total, "attachments": len(listed)}, listed)


def parse_zip(pkg: Package, budget: Budget, sub: Callable[[bytes, str, int], Parsed], depth: int) -> Parsed:
    infos = [i for i in pkg.zf.infolist() if not i.is_dir() and not _junk(i.filename)]
    entries, skipped = [], []
    for info in infos:
        name = info.filename
        if budget.archive_entries_left <= 0:
            budget.note("压缩包内文件超过 200 个，其余未读")
            skipped.append({"filename": name, "type": "data", "summary": "超过数量上限，未读取"})
            continue
        budget.archive_entries_left -= 1
        if info.flag_bits & 0x1:
            skipped.append({"filename": name, "type": "data", "summary": "加密，无法读取"})
            continue
        if is_bomb(info) or info.file_size > budget.archive_bytes_left:
            budget.note("压缩包解压后超过 100 MB 或压缩比异常，部分文件未读")
            skipped.append({"filename": name, "type": "data", "summary": "过大，未读取"})
            continue
        budget.archive_bytes_left -= info.file_size
        try:
            data = pkg.zf.read(info)
        except Exception:  # noqa: BLE001 - bad CRC, unsupported method
            skipped.append({"filename": name, "type": "data", "summary": "文件损坏，无法读取"})
            continue
        entries.append((name, sub(data, name, depth + 1)))
    return _render(entries, skipped[:200], len(infos), "压缩包")


def parse_tar(data: bytes, budget: Budget, sub: Callable[[bytes, str, int], Parsed], depth: int) -> Parsed:
    try:
        tf = tarfile.open(fileobj=io.BytesIO(data), mode="r:")
    except tarfile.TarError as exc:
        raise ParseError("corrupt", f"tar: {exc}") from exc
    entries, skipped, total = [], [], 0
    for member in tf:
        if not member.isfile() or _junk(member.name):
            continue
        total += 1
        if budget.archive_entries_left <= 0:
            skipped.append({"filename": member.name, "type": "data", "summary": "超过数量上限，未读取"})
            continue
        budget.archive_entries_left -= 1
        if member.size > budget.archive_bytes_left:
            budget.note("压缩包解压后超过 100 MB，部分文件未读")
            skipped.append({"filename": member.name, "type": "data", "summary": "过大，未读取"})
            continue
        budget.archive_bytes_left -= member.size
        f = tf.extractfile(member)
        if f is None:
            continue
        entries.append((member.name, sub(f.read(), member.name, depth + 1)))
    return _render(entries, skipped[:200], total, "压缩包")


def decompress_stream(data: bytes, fmt: str, budget: Budget) -> bytes:
    """gzip / bzip2 / xz with the output bounded by the archive budget (a bomb stops at the limit)."""
    limit = budget.archive_bytes_left
    if fmt == "gzip":
        d = zlib.decompressobj(wbits=47)
    elif fmt == "bz2":
        d = bz2.BZ2Decompressor()
    else:
        d = lzma.LZMADecompressor()
    try:
        out = d.decompress(data, limit + 1)
    except (zlib.error, OSError, lzma.LZMAError, EOFError, ValueError) as exc:
        raise ParseError("corrupt", f"{fmt}: {exc}") from exc
    if len(out) > limit:
        raise ParseError("too_large", f"{fmt} expands beyond {limit} bytes")
    budget.archive_bytes_left -= len(out)
    return out


def parse_compressed(data: bytes, name: str, fmt: str, budget: Budget,
                     sub: Callable[[bytes, str, int], Parsed], depth: int) -> Parsed:
    raw = decompress_stream(data, fmt, budget)
    inner_name = name.rsplit(".", 1)[0] if "." in name else name
    if ext_of(name) in ("tgz", "tbz", "tbz2", "txz"):
        inner_name += ".tar"
    if len(raw) > 262 and raw[257:262] == b"ustar":
        return parse_tar(raw, budget, sub, depth)
    inner = sub(raw, inner_name, depth)
    return inner
