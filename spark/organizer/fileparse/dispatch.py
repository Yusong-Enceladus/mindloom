"""Route one file (or a nested entry / attachment) to its parser. Runs inside the sandboxed worker."""

from __future__ import annotations

from .core import MAX_ARCHIVE_DEPTH, MEDIA_SKIPPED_FMT, Budget, ParseError, Parsed, ext_of, is_media_name, sniff

FMT_TYPE = {
    "pdf": "pdf", "docx": "document", "odt": "document", "doc": "document", "rtf": "document", "iwork": "document",
    "xlsx": "spreadsheet", "xls": "spreadsheet", "ods": "spreadsheet", "csv": "spreadsheet", "tsv": "spreadsheet",
    "pptx": "slides", "ppt": "slides", "odp": "slides", "epub": "ebook", "eml": "email", "msg": "email",
    "mbox": "email", "ics": "calendar", "vcf": "contact", "zip": "archive", "tar": "archive", "gzip": "archive",
    "bz2": "archive", "xz": "archive", "7z": "archive", "rar": "archive", "html": "web", "mht": "web",
    "webarchive": "web", "webloc": "web", "url": "web", "code": "code", "ipynb": "code", "json": "data",
    "xml": "data", "yaml": "data", "plist": "data", "text": "text", "image": "image", "heic": "image",
    "media": "data", "binary": "data", "ole": "data", "sqlite": "data", "xmind": "document",
}
EXT_TYPE = {"docx": "document", "docm": "document", "dotx": "document", "doc": "document", "xlsx": "spreadsheet",
            "xlsm": "spreadsheet", "xls": "spreadsheet", "pptx": "slides", "pptm": "slides", "ppt": "slides",
            "pages": "document", "numbers": "spreadsheet", "key": "slides", "pdf": "pdf",
            "wps": "document", "wpt": "document", "et": "spreadsheet", "ett": "spreadsheet", "dps": "slides",
            "dpt": "slides", "xmind": "document"}


def type_for(fmt: str, name: str) -> str:
    return EXT_TYPE.get(ext_of(name)) or FMT_TYPE.get(fmt, "data")


def parse_bytes(data: bytes, name: str, mime: str, budget: Budget, depth: int = 0) -> Parsed:
    fmt = sniff(data, name, mime)
    try:
        parsed = _parse(fmt, data, name, mime, budget, depth)
    except ParseError as exc:
        parsed = Parsed(type_for(fmt, name), error=exc.code)
        if exc.detail:
            budget.note(f"{name or '文件'}：{exc.detail}"[:200])
    except MemoryError:
        parsed = Parsed(type_for(fmt, name), error="too_large")
    except RecursionError:
        parsed = Parsed(type_for(fmt, name), error="corrupt")
    except Exception as exc:  # noqa: BLE001 - a parser bug or a malformed file: report, never crash the item
        parsed = Parsed(type_for(fmt, name), error="corrupt")
        budget.note(f"{name or '文件'}：{type(exc).__name__}"[:200])
    parsed.fmt = parsed.fmt or fmt
    return parsed


def _parse(fmt: str, data: bytes, name: str, mime: str, budget: Budget, depth: int) -> Parsed:
    ext = ext_of(name)

    def sub(inner: bytes, inner_name: str, inner_depth: int = depth + 1) -> Parsed:
        return parse_bytes(inner, inner_name, "", budget, inner_depth)

    if fmt == "pdf":
        from .pdf import parse_pdf
        return parse_pdf(data, budget)
    if fmt == "zip":
        from .office import detect_package, parse_docx, parse_epub, parse_iwork, parse_odf, parse_pptx, parse_xlsx
        from .pkg import Package
        pkg = Package(data)
        kind = detect_package(pkg, ext)
        if kind != "zip":
            # Audio / video embedded in a document package (a pptx's movie, a docx's recording) are never
            # read; only their number is recorded. A plain archive counts its media entries itself.
            budget.media_skipped += sum(1 for n in pkg.names() if is_media_name(n))
        if kind == "docx":
            return _fmt(parse_docx(pkg, budget), kind)
        if kind == "xlsx":
            return _fmt(parse_xlsx(data, pkg, budget), kind)
        if kind == "pptx":
            return _fmt(parse_pptx(pkg, budget), kind)
        if kind in ("odt", "ods", "odp"):
            return _fmt(parse_odf(pkg, kind, budget), kind)
        if kind == "epub":
            return _fmt(parse_epub(pkg, budget), kind)
        if kind == "xmind":
            from .textish import parse_xmind
            return _fmt(parse_xmind(pkg), kind)
        if kind == "iwork":
            from .pdf import parse_pdf
            return _fmt(parse_iwork(pkg, ext, budget, lambda b: parse_pdf(b, budget)), kind)
        if depth >= MAX_ARCHIVE_DEPTH:
            raise ParseError("too_large", "压缩包嵌套层数超过上限，未展开")
        from .archive import parse_zip
        infos = [i for i in pkg.zf.infolist() if not i.is_dir()]
        if infos and all(i.flag_bits & 0x1 for i in infos):
            raise ParseError("encrypted", "password-protected zip")
        return parse_zip(pkg, budget, sub, depth)
    if fmt == "ole":
        from . import ole as O
        doc = O.open_ole(data)
        try:
            kind = O.ole_kind(doc)
            if kind == "ooxml_encrypted":
                raise ParseError("encrypted", "password-protected Office file")
            if kind == "doc":
                return _fmt(O.parse_doc(doc), kind)
            if kind == "xls":
                return _fmt(O.parse_xls(data, budget), kind)
            if kind == "ppt":
                return _fmt(O.parse_ppt(doc), kind)
            if kind == "msg":
                return _fmt(O.parse_msg(doc, budget, lambda b, n: sub(b, n)), kind)
            raise ParseError("unsupported", "OLE file of an unknown kind")
        finally:
            doc.close()
    if fmt in ("gzip", "bz2", "xz", "tar"):
        if depth >= MAX_ARCHIVE_DEPTH:
            raise ParseError("too_large", "压缩包嵌套层数超过上限，未展开")
        from .archive import parse_compressed, parse_tar
        if fmt == "tar":
            return parse_tar(data, budget, sub, depth)
        return parse_compressed(data, name, fmt, budget, lambda b, n, d: parse_bytes(b, n, "", budget, d), depth)
    if fmt == "sqlite":
        from .textish import parse_sqlite
        return parse_sqlite(data)
    if fmt in ("7z", "rar"):
        raise ParseError("unsupported", f"{fmt} 压缩包无法在整理端展开")
    if fmt == "image":
        from .images import add_image
        top = depth == 0
        marker = add_image(budget, data, name or "图片", min_side=16 if top else 64, min_area=0 if top else 160 * 160)
        return Parsed("image", marker or "", "", {})
    if fmt == "heic":
        raise ParseError("unsupported", "HEIC 图片需要在 Mac 上转换")
    if fmt == "media":
        if depth > 0:
            # Inside an archive or an e-mail: skipped, counted, never decoded or transcribed here.
            budget.media_skipped += 1
            return Parsed("data", fmt=MEDIA_SKIPPED_FMT)
        raise ParseError("unsupported", "音视频只在 Mac 上处理")
    if fmt == "rtf":
        from .textish import parse_rtf
        return parse_rtf(data)
    if fmt in ("html",):
        from .textish import parse_html
        return parse_html(data)
    if fmt == "mht":
        from .mail import parse_mht
        return parse_mht(data)
    if fmt == "eml":
        from .mail import parse_eml
        return parse_eml(data, budget, lambda b, n: sub(b, n))
    if fmt == "mbox":
        from .mail import parse_mbox
        return parse_mbox(data, budget)
    if fmt == "ics":
        from .mail import parse_ics
        return parse_ics(data)
    if fmt == "vcf":
        from .mail import parse_vcf
        return parse_vcf(data)
    if fmt in ("csv", "tsv"):
        from .textish import parse_delimited
        return parse_delimited(data, fmt)
    if fmt == "json":
        from .textish import parse_json
        return parse_json(data)
    if fmt == "ipynb":
        from .textish import parse_ipynb
        return parse_ipynb(data)
    if fmt == "yaml":
        from .textish import parse_yaml
        return parse_yaml(data)
    if fmt == "xml":
        from .textish import parse_xml_file
        return parse_xml_file(data, name)
    if fmt in ("webarchive", "webloc", "plist"):
        from .textish import parse_plist
        return parse_plist(data, name)
    if fmt == "url":
        from .textish import parse_url_file
        return parse_url_file(data)
    if fmt in ("code", "text"):
        from .textish import parse_text
        return parse_text(data, name, fmt)
    raise ParseError("unsupported", "未知的文件格式")


def _fmt(p: Parsed, fmt: str) -> Parsed:
    p.fmt = fmt
    return p
