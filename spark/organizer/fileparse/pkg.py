"""Reading members of a zip container (Office / ODF / EPUB / iWork packages and plain archives) safely.

A member is read only when its declared size is within the limit and its compression ratio is sane;
Python's zipfile never returns more than the declared size, so the declared size bounds the memory used.
XML is parsed with defusedxml (no DTD entities, no external references).
"""

from __future__ import annotations

import io
import zipfile
from typing import Optional

from defusedxml import ElementTree as DET  # noqa: N812

from .core import MAX_PACKAGE_PART, MAX_RATIO, ParseError


def open_zip(data: bytes) -> zipfile.ZipFile:
    try:
        return zipfile.ZipFile(io.BytesIO(data))
    except (zipfile.BadZipFile, ValueError, OSError) as exc:
        raise ParseError("corrupt", f"not a readable zip: {exc}") from exc


def is_bomb(info: zipfile.ZipInfo) -> bool:
    return info.file_size > 8 * 1024 * 1024 and info.file_size > MAX_RATIO * max(1, info.compress_size)


class Package:
    """A zip package whose members are looked up by name (case-insensitive fallback)."""

    def __init__(self, data: bytes):
        self.zf = open_zip(data)
        self.infos = {i.filename: i for i in self.zf.infolist()}
        self.lower = {n.lower(): n for n in self.infos}

    def names(self) -> list[str]:
        return list(self.infos)

    def has(self, name: str) -> bool:
        return self._resolve(name) is not None

    def _resolve(self, name: str) -> Optional[str]:
        name = name.lstrip("/")
        if name in self.infos:
            return name
        return self.lower.get(name.lower())

    def encrypted(self) -> bool:
        return any(i.flag_bits & 0x1 for i in self.infos.values())

    def read(self, name: str, limit: int = MAX_PACKAGE_PART) -> Optional[bytes]:
        real = self._resolve(name)
        if real is None:
            return None
        info = self.infos[real]
        if info.flag_bits & 0x1:
            raise ParseError("encrypted", f"{real} is encrypted")
        if info.file_size > limit or is_bomb(info):
            raise ParseError("too_large", f"{real}: {info.file_size} bytes uncompressed")
        try:
            return self.zf.read(real)
        except (zipfile.BadZipFile, EOFError, OSError, NotImplementedError, RuntimeError) as exc:
            raise ParseError("corrupt", f"{real}: {exc}") from exc

    def xml(self, name: str):
        raw = self.read(name)
        if raw is None:
            return None
        return parse_xml(raw)


def parse_xml(raw: bytes):
    try:
        return DET.fromstring(raw, forbid_dtd=False, forbid_entities=True, forbid_external=True)
    except DET.ParseError as exc:
        raise ParseError("corrupt", f"bad XML: {exc}") from exc
    except Exception as exc:  # defusedxml.EntitiesForbidden / ExternalReferenceForbidden / DTDForbidden
        raise ParseError("unsupported", f"XML with entities or external references refused: {type(exc).__name__}") from exc


def local(tag) -> str:
    """Element tag without its namespace."""
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""


def rels(pkg: Package, part: str) -> dict[str, str]:
    """OOXML relationships of `part`: rId -> resolved member path."""
    folder, _, base = part.rpartition("/")
    root = pkg.xml(f"{folder}/_rels/{base}.rels" if folder else f"_rels/{base}.rels")
    out: dict[str, str] = {}
    if root is None:
        return out
    for rel in root:
        rid, target, mode = rel.get("Id"), rel.get("Target") or "", rel.get("TargetMode") or ""
        if not rid or mode.lower() == "external":
            continue  # external links are never fetched
        out[rid] = resolve_path(folder, target)
    return out


def resolve_path(folder: str, target: str) -> str:
    if target.startswith("/"):
        return target.lstrip("/")
    parts = [p for p in folder.split("/") if p] if folder else []
    for seg in target.split("/"):
        if seg == "..":
            if parts:
                parts.pop()
        elif seg and seg != ".":
            parts.append(seg)
    return "/".join(parts)
