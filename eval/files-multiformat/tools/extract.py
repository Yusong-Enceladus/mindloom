"""Non-ML text extraction for every text-bearing type (used to verify the corpus and to build container truth).

Image-only content (photos, scans, video frames, GIF frames, picture-only slides) has no text layer and returns "".
macOS textutil is used for rtf/doc/odt when present; everything else is pure Python.
"""

from __future__ import annotations

import datetime as dt
import email
import html
import html.parser
import io
import json
import mailbox
import os
import plistlib
import quopri
import re
import shutil
import subprocess
import tempfile
import unicodedata
import zipfile
from email import policy
from email.utils import format_datetime, parseaddr

TEXT_EXT = {"txt", "md", "csv", "json", "xml", "svg"}


# ----------------------------------------------------------------------------- normalisation

_STRIP = re.compile(r"[\s,，、|*#>`_:：;；\-–—•·()（）\[\]【】\"'“”‘’]+")


def norm(s: str) -> str:
    return _STRIP.sub("", unicodedata.normalize("NFKC", str(s)).lower())


def num_variants(v) -> list[str]:
    out = []
    def fmt(x):
        if abs(x - round(x)) < 1e-9:
            return [str(int(round(x)))]
        r = [f"{x:.3f}".rstrip("0").rstrip("."), f"{x:.2f}", f"{x:.1f}"]
        return [s for s in r if abs(float(s) - x) < 1e-9] or r[:1]
    x = float(v)
    out += fmt(x)
    if x < 1.5:
        out += fmt(x * 100)
    return list(dict.fromkeys(out))


def has_number(text: str, v) -> bool:
    """Is the number v written in raw text (thousands separators ignored, 0.962 also as 96.2)?"""
    t = re.sub(r"(?<![\d,.])\d{1,3}(?:,\d{3})+(?!\d|,\d)", lambda m: m.group(0).replace(",", ""),
               unicodedata.normalize("NFKC", str(text)))
    for s in num_variants(v):
        if re.search(r"(?<![0-9.])" + re.escape(s) + r"(?![0-9])", t):
            return True
    return False


# ----------------------------------------------------------------------------- helpers

def decode_bytes(b: bytes) -> tuple[str, str]:
    for enc in ("utf-8-sig", "utf-8", "gb18030", "utf-16"):
        try:
            return b.decode(enc), enc
        except UnicodeDecodeError:
            continue
    return b.decode("latin-1"), "latin-1"


class _Strip(html.parser.HTMLParser):
    BLOCK = {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "dt", "dd", "table", "caption", "header", "footer", "section", "title", "figcaption"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out, self.skip = [], 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self.skip += 1
        if tag in self.BLOCK:
            self.out.append("\n")
        if tag in ("td", "th"):
            self.out.append("\t")

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self.skip -= 1
        if tag in self.BLOCK:
            self.out.append("\n")

    def handle_data(self, data):
        if not self.skip:
            self.out.append(data)


def html_text(s: str) -> str:
    p = _Strip()
    p.feed(s)
    txt = "".join(p.out)
    return re.sub(r"\n\s*\n+", "\n", txt).strip()


def textutil_txt(path: str) -> str:
    try:
        r = subprocess.run(["/usr/bin/textutil", "-convert", "txt", "-stdout", path], capture_output=True, timeout=60)
        return r.stdout.decode("utf-8", "replace")
    except (OSError, subprocess.TimeoutExpired):
        return ""


# ----------------------------------------------------------------------------- office

def docx_text(path: str) -> str:
    import docx
    d = docx.Document(path)
    out = []
    for s in d.sections:
        out += [p.text for p in s.header.paragraphs] + [p.text for p in s.footer.paragraphs]
    body = d.element.body
    for child in body.iterchildren():
        tag = child.tag.split("}")[-1]
        if tag == "p":
            out.append("".join(t.text or "" for t in child.iter() if t.tag.endswith("}t")))
        elif tag == "tbl":
            for tr in child.iter():
                if tr.tag.endswith("}tr"):
                    cells = []
                    for tc in tr:
                        if tc.tag.endswith("}tc"):
                            cells.append("".join(t.text or "" for t in tc.iter() if t.tag.endswith("}t")))
                    out.append("\t".join(cells))
    return "\n".join(out)


def xlsx_text(path: str) -> tuple[str, dict]:
    import openpyxl
    wb = openpyxl.load_workbook(path, data_only=True)
    wf = openpyxl.load_workbook(path, data_only=False)
    out, info = [], {"sheets": [], "formulas": 0, "formulas_without_cache": 0, "merged_ranges": 0}
    for ws in wb.worksheets:
        wsf = wf[ws.title]
        info["sheets"].append(ws.title)
        info["merged_ranges"] += len(ws.merged_cells.ranges)
        out.append(f"[{ws.title}]")
        for row, rowf in zip(ws.iter_rows(), wsf.iter_rows()):
            vals = []
            for c, cf in zip(row, rowf):
                if isinstance(cf.value, str) and cf.value.startswith("="):
                    info["formulas"] += 1
                    if c.value is None:
                        info["formulas_without_cache"] += 1
                v = c.value
                if isinstance(v, float) and abs(v - round(v)) < 1e-9:
                    v = int(round(v))
                vals.append("" if v is None else str(v))
            if any(vals):
                out.append("\t".join(vals))
    return "\n".join(out), info


def ods_text(path: str) -> tuple[str, dict]:
    from odf.opendocument import load
    from odf.table import Table, TableRow, TableCell, CoveredTableCell
    from odf import teletype
    doc = load(path)
    out, info = [], {"sheets": [], "formulas": 0, "formulas_without_cache": 0, "merged_ranges": 0}
    for t in doc.spreadsheet.getElementsByType(Table):
        name = t.getAttribute("name")
        info["sheets"].append(name)
        out.append(f"[{name}]")
        for tr in t.getElementsByType(TableRow):
            vals = []
            for c in tr.childNodes:
                if c.qname[1] == "covered-table-cell":
                    vals.append("")
                    continue
                if c.qname[1] != "table-cell":
                    continue
                if c.getAttribute("numbercolumnsspanned") and int(c.getAttribute("numbercolumnsspanned") or 1) > 1 or \
                        (c.getAttribute("numberrowsspanned") and int(c.getAttribute("numberrowsspanned") or 1) > 1):
                    info["merged_ranges"] += 1
                if c.getAttribute("formula"):
                    info["formulas"] += 1
                    if not c.getAttribute("value") and not teletype.extractText(c):
                        info["formulas_without_cache"] += 1
                v = c.getAttribute("value")
                if v not in (None, ""):
                    fv = float(v)
                    v = str(int(fv)) if abs(fv - round(fv)) < 1e-9 else str(fv)
                else:
                    v = teletype.extractText(c)
                rep = int(c.getAttribute("numbercolumnsrepeated") or 1)
                vals += [v] * min(rep, 50)
            if any(vals):
                out.append("\t".join(vals).rstrip("\t"))
    return "\n".join(out), info


def pptx_text(path: str) -> tuple[str, dict]:
    from pptx import Presentation
    prs = Presentation(path)
    out, info = [], {"slides": 0, "picture_only_slides": [], "notes_slides": []}
    for i, s in enumerate(prs.slides, 1):
        info["slides"] += 1
        texts, pics = [], 0
        for sh in s.shapes:
            if sh.shape_type == 13:
                pics += 1
            if sh.has_text_frame and sh.text_frame.text.strip():
                texts.append(sh.text_frame.text)
            if getattr(sh, "has_table", False) and sh.has_table:
                for r in sh.table.rows:
                    texts.append("\t".join(c.text for c in r.cells))
        real = [t for t in texts if t.strip() not in ("合成数据",)]
        if pics and not real:
            info["picture_only_slides"].append(i)
        out.append(f"[slide {i}]")
        out += texts
        if s.has_notes_slide and s.notes_slide.notes_text_frame.text.strip():
            info["notes_slides"].append(i)
            out.append("[notes] " + s.notes_slide.notes_text_frame.text)
    return "\n".join(out), info


def odp_text(path: str) -> tuple[str, dict]:
    from odf.opendocument import load
    from odf.draw import Page, Frame, Image as DImage
    from odf import teletype
    from odf.text import P
    doc = load(path)
    out, info = [], {"slides": 0, "picture_only_slides": []}
    for i, pg in enumerate(doc.presentation.getElementsByType(Page), 1):
        info["slides"] += 1
        ps = [teletype.extractText(p) for p in pg.getElementsByType(P)]
        imgs = pg.getElementsByType(DImage)
        if imgs and not any(x.strip() for x in ps):
            info["picture_only_slides"].append(i)
        out.append(f"[slide {i}]")
        out += [x for x in ps if x.strip()]
    return "\n".join(out), info


def odt_text(path: str) -> str:
    from odf.opendocument import load
    from odf import teletype
    from odf.text import P, H
    doc = load(path)
    out = []
    for el in doc.text.getElementsByType(H) + doc.text.getElementsByType(P):
        pass
    # document order: walk the tree
    def walk(node):
        for ch in node.childNodes:
            if ch.nodeType == ch.ELEMENT_NODE and ch.qname[1] in ("p", "h"):
                out.append(teletype.extractText(ch))
            elif ch.nodeType == ch.ELEMENT_NODE and ch.qname[1] == "table-row":
                cells = [teletype.extractText(c) for c in ch.childNodes if c.nodeType == c.ELEMENT_NODE and c.qname[1] == "table-cell"]
                out.append("\t".join(cells))
            elif ch.nodeType == ch.ELEMENT_NODE:
                walk(ch)
    walk(doc.text)
    return "\n".join(out)


def pdf_text(path: str) -> tuple[str, dict]:
    import fitz
    d = fitz.open(path)
    out = [p.get_text() for p in d]
    info = {"pages": len(d), "images": sum(len(p.get_images()) for p in d)}
    d.close()
    return "\n".join(out), info


def epub_text(path: str) -> tuple[str, dict]:
    z = zipfile.ZipFile(path)
    names = z.namelist()
    info = {"mimetype_first": names[0] == "mimetype", "chapters": 0}
    opf_path = re.search(r'full-path="([^"]+)"', z.read("META-INF/container.xml").decode()).group(1)
    opf = z.read(opf_path).decode("utf-8")
    base = os.path.dirname(opf_path)
    manifest = dict(re.findall(r'<item id="([^"]+)" href="([^"]+)"', opf))
    spine = re.findall(r'<itemref idref="([^"]+)"', opf)
    title = re.search(r"<dc:title>(.*?)</dc:title>", opf)
    out = [html.unescape(title.group(1))] if title else []
    for sid in spine:
        info["chapters"] += 1
        out.append(html_text(z.read(os.path.join(base, manifest[sid]) if base else manifest[sid]).decode("utf-8")))
    return "\n".join(out), info


def webarchive_text(path: str) -> tuple[str, dict]:
    with open(path, "rb") as fh:
        pl = plistlib.load(fh)
    main = pl["WebMainResource"]
    subs = pl.get("WebSubresources", [])
    info = {"url": main.get("WebResourceURL"), "subresources": [s.get("WebResourceURL") for s in subs]}
    return html_text(main["WebResourceData"].decode(main.get("WebResourceTextEncodingName", "UTF-8"))), info


# ----------------------------------------------------------------------------- calendar / contacts

def _unfold(text: str) -> list[str]:
    return re.sub(r"\r?\n[ \t]", "", text).splitlines()


def _unescape(v: str) -> str:
    return v.replace("\\n", "\n").replace("\\N", "\n").replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\")


def _fmt_dt(v: str, params: str) -> str:
    if "VALUE=DATE" in params or re.fullmatch(r"\d{8}", v):
        return f"{v[:4]}-{v[4:6]}-{v[6:8]} (all day)"
    m = re.fullmatch(r"(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)", v)
    if not m:
        return v
    tz = "UTC" if m.group(7) else (re.search(r"TZID=([^;:]+)", params).group(1) if "TZID=" in params else "floating")
    return f"{m.group(1)}-{m.group(2)}-{m.group(3)} {m.group(4)}:{m.group(5)} ({tz})"


def ics_readable(text: str) -> tuple[str, dict]:
    out, info, inside, in_alarm = [], {"events": 0, "calname": None}, False, False
    for line in _unfold(text):
        if ":" not in line:
            continue
        head, val = line.split(":", 1)
        name, _, params = head.partition(";")
        if name == "X-WR-CALNAME":
            info["calname"] = val
            out.append(f"CALENDAR: {_unescape(val)}")
        if name == "BEGIN" and val == "VEVENT":
            inside = True
            info["events"] += 1
            out.append("")
            out.append(f"[event {info['events']}]")
        elif name == "END" and val == "VEVENT":
            inside = False
        elif name == "BEGIN" and val == "VALARM":
            in_alarm = True
        elif name == "END" and val == "VALARM":
            in_alarm = False
        elif inside and in_alarm and name == "TRIGGER":
            out.append(f"ALARM: {val}")
        elif inside and not in_alarm:
            if name in ("SUMMARY", "LOCATION", "DESCRIPTION"):
                out.append(f"{name}: {_unescape(val)}")
            elif name in ("DTSTART", "DTEND"):
                out.append(f"{name[2:]}: {_fmt_dt(val, params)}")
            elif name == "RRULE":
                out.append(f"RRULE: {val}")
            elif name in ("ORGANIZER", "ATTENDEE"):
                cn = re.search(r'CN="?([^;:"]+)"?', params)
                out.append(f"{name}: {cn.group(1) if cn else ''} <{val.replace('mailto:', '')}>")
    return "\n".join(out).strip(), info


def vcf_readable(text: str) -> tuple[str, dict]:
    raw = re.sub(r"=\r?\n", "", text)  # QP soft breaks (vCard 2.1)
    out, info = [], {"cards": 0, "versions": []}
    for line in _unfold(raw):
        if ":" not in line:
            continue
        head, val = line.split(":", 1)
        name, _, params = head.partition(";")
        name = name.upper()
        if "QUOTED-PRINTABLE" in params.upper():
            cs = re.search(r"CHARSET=([^;:]+)", params, re.I)
            val = quopri.decodestring(val.encode("ascii")).decode(cs.group(1) if cs else "utf-8")
        if name == "BEGIN":
            info["cards"] += 1
            out.append("")
            out.append(f"[contact {info['cards']}]")
        elif name == "VERSION":
            info["versions"].append(val)
        elif name in ("FN", "ORG", "TITLE", "NOTE", "URL", "EMAIL"):
            out.append(f"{name}: {_unescape(val)}")
        elif name == "TEL":
            out.append(f"TEL: {val.replace('tel:', '')}")
        elif name == "N":
            parts = val.split(";")
            out.append(f"N: {parts[0]} {parts[1] if len(parts) > 1 else ''}".rstrip())
        elif name == "ADR":
            parts = [p for p in val.split(";") if p]
            out.append("ADR: " + " ".join(parts))
    return "\n".join(out).strip(), info


# ----------------------------------------------------------------------------- mail

def _addr_list(v) -> str:
    return ", ".join(f"{a.display_name} <{a.addr_spec}>" for a in v.addresses) if hasattr(v, "addresses") else str(v)


def message_text(msg, tmp: str, depth: int = 0) -> tuple[str, dict]:
    out, info = [], {"attachments": [], "parts": []}
    for h in ("From", "To", "Cc", "Date", "Subject"):
        if msg[h]:
            out.append(f"{h}: {_addr_list(msg[h]) if h in ('From', 'To', 'Cc') else str(msg[h])}")
    body = msg.get_body(preferencelist=("plain", "html"))
    if body is not None:
        c = body.get_content()
        info["parts"].append(body.get_content_type())
        out.append(html_text(c) if body.get_content_type() == "text/html" else c)
    for part in msg.iter_attachments():
        fn = part.get_filename()
        if not fn:
            continue
        data = part.get_payload(decode=True)
        info["attachments"].append(fn)
        out.append(f"[attachment] {fn}")
        p = os.path.join(tmp, f"att{depth}_{len(info['attachments'])}{os.path.splitext(fn)[1]}")
        with open(p, "wb") as fh:
            fh.write(data)
        t, _ = extract(p, ext_type(p), tmp, depth + 1)
        out.append(t)
    return "\n".join(x for x in out if x), info


def eml_text(path: str, tmp: str, depth=0):
    with open(path, "rb") as fh:
        msg = email.message_from_binary_file(fh, policy=policy.default)
    return message_text(msg, tmp, depth)


def mbox_text(path: str, tmp: str, depth=0):
    mb = mailbox.mbox(path, factory=lambda f: email.message_from_binary_file(f, policy=policy.default), create=False)
    out, info = [], {"messages": 0, "attachments": []}
    for i, msg in enumerate(mb, 1):
        info["messages"] += 1
        t, inf = message_text(msg, tmp, depth)
        info["attachments"] += inf["attachments"]
        out += [f"[message {i}]", t]
    mb.close()
    return "\n".join(out), info


def zip_text(path: str, tmp: str, depth=0):
    z = zipfile.ZipFile(path)
    out, info = [], {"members": [], "nested_zips": []}
    for zi in z.infolist():
        if zi.is_dir():
            continue
        name = zi.filename
        try:
            name = zi.filename.encode("cp437").decode("utf-8") if not (zi.flag_bits & 0x800) else zi.filename
        except (UnicodeEncodeError, UnicodeDecodeError):
            pass
        info["members"].append(name)
        out.append(f"[member] {name}")
        sub = os.path.join(tmp, f"z{depth}_{len(info['members'])}{os.path.splitext(name)[1]}")
        with open(sub, "wb") as fh:
            fh.write(z.read(zi))
        if name.lower().endswith(".zip"):
            info["nested_zips"].append(name)
        t, inf = extract(sub, ext_type(sub), tmp, depth + 1)
        if isinstance(inf, dict) and inf.get("members"):
            info["members"] += [f"{name}/{m}" for m in inf["members"]]
        out.append(t)
    return "\n".join(x for x in out if x), info


# ----------------------------------------------------------------------------- dispatch

EXT_TYPE = {"txt": "txt", "md": "md", "rtf": "rtf", "html": "html", "htm": "html", "csv": "csv", "json": "json", "xml": "xml",
            "docx": "docx", "doc": "doc", "odt": "odt", "xlsx": "xlsx", "ods": "ods", "pptx": "pptx", "odp": "odp", "pdf": "pdf",
            "epub": "epub", "eml": "eml", "mbox": "mbox", "ics": "ics", "vcf": "vcf", "zip": "zip", "webarchive": "webarchive",
            "png": "png", "jpg": "jpg", "jpeg": "jpg", "heic": "heic", "webp": "webp", "gif": "gif", "tiff": "tiff", "tif": "tiff",
            "bmp": "bmp", "svg": "svg", "mp4": "mp4", "mov": "mov"}
IMAGE_LIKE = {"png", "jpg", "heic", "webp", "gif", "tiff", "bmp", "mp4", "mov"}


def ext_type(path: str) -> str:
    return EXT_TYPE.get(os.path.splitext(path)[1].lower().lstrip("."), "bin")


def extract(path: str, ftype: str, tmp: str | None = None, depth: int = 0) -> tuple[str, dict]:
    """Text layer of a file and a few structural facts. ftype pdf_scanned is read like pdf."""
    own = tmp is None
    tmp = tmp or tempfile.mkdtemp(prefix="xt")
    try:
        t = "pdf" if ftype == "pdf_scanned" else ftype
        if t in ("txt", "md", "csv", "json", "xml"):
            with open(path, "rb") as fh:
                s, enc = decode_bytes(fh.read())
            return s, {"encoding": enc}
        if t == "svg":
            with open(path, encoding="utf-8") as fh:
                s = fh.read()
            return "\n".join(html.unescape(x) for x in re.findall(r"<text[^>]*>(.*?)</text>", s, re.S)), {}
        if t == "html":
            with open(path, "rb") as fh:
                s, enc = decode_bytes(fh.read())
            return html_text(s), {"encoding": enc}
        if t in ("rtf", "doc"):
            return textutil_txt(path), {}
        if t == "odt":
            return odt_text(path), {}
        if t == "docx":
            return docx_text(path), {}
        if t == "xlsx":
            return xlsx_text(path)
        if t == "ods":
            return ods_text(path)
        if t == "pptx":
            return pptx_text(path)
        if t == "odp":
            return odp_text(path)
        if t == "pdf":
            return pdf_text(path)
        if t == "epub":
            return epub_text(path)
        if t == "webarchive":
            return webarchive_text(path)
        if t == "ics":
            with open(path, encoding="utf-8") as fh:
                return ics_readable(fh.read())
        if t == "vcf":
            with open(path, encoding="utf-8") as fh:
                return vcf_readable(fh.read())
        if t == "eml":
            return eml_text(path, tmp, depth)
        if t == "mbox":
            return mbox_text(path, tmp, depth)
        if t == "zip":
            return zip_text(path, tmp, depth)
        return "", {}
    finally:
        if own:
            shutil.rmtree(tmp, ignore_errors=True)
