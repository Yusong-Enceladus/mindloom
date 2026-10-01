"""Shared pieces of the file parsers: the per-file budget, the result shape, routing and text helpers.

Everything here runs inside the sandboxed parser process (organizer/fileparse/worker.py): no network, no
shell-outs, no file writes, CPU / memory / time limits set by the parent. Parsers only read the bytes
they are given and return text plus image parts; nothing is interpreted as code (no macros, no scripts,
no external entities, no URL fetches).
"""

from __future__ import annotations

import codecs
import csv
import html
import io
import re
from dataclasses import dataclass, field
from html.parser import HTMLParser
from typing import Callable, Optional

# ---- limits (contract "file" item, 2026-09-29) --------------------------------------------------------

TEXT_CAP = 60_000                 # reading text, characters (after image readings are inserted)
PART_TEXT_CAP = 20_000            # one archive entry / attachment
MAX_SCANNED_PAGES = 20            # image-only PDF pages sent to image-read
MAX_EMBEDDED_IMAGES = 10          # images inside a docx / pptx / email / archive sent to image-read
MAX_ARCHIVE_ENTRIES = 200
MAX_ARCHIVE_BYTES = 100 * 1024 * 1024   # uncompressed, whole archive tree
MAX_ARCHIVE_DEPTH = 2             # an archive inside an archive inside the file
MAX_PACKAGE_PART = 200 * 1024 * 1024    # one XML part of an Office / ODF / EPUB package (declared size)
MAX_RATIO = 400                   # declared uncompressed / compressed size of one zip member
MAX_SHEET_ROWS = 400              # rows listed per sheet (the rest are counted)
MAX_SHEET_COLS = 40
MAX_SHEETS = 40
MAX_SHEET_CELLS_SCANNED = 400_000  # per workbook
MAX_MAILS = 20                    # messages read from an mbox
MAX_PDF_PAGES_TEXT = 500
IMAGE_MAX_SIDE = 2560
MIN_IMAGE_SIDE = 64               # smaller images are icons / bullets, not content
MIN_IMAGE_AREA = 160 * 160

READING_TYPES = ("text", "document", "spreadsheet", "slides", "pdf", "scanned_pdf", "email", "calendar",
                 "contact", "ebook", "archive", "web", "code", "data", "image")
ERRORS = ("encrypted", "unsupported", "too_large", "corrupt")


class ParseError(Exception):
    """A file that cannot be read; `code` is one of ERRORS."""

    def __init__(self, code: str, detail: str = ""):
        super().__init__(detail or code)
        self.code = code
        self.detail = detail


@dataclass
class Budget:
    """Shared by one file and everything nested in it."""
    images_left: int = MAX_EMBEDDED_IMAGES
    scanned_pages_left: int = MAX_SCANNED_PAGES
    archive_bytes_left: int = MAX_ARCHIVE_BYTES
    archive_entries_left: int = MAX_ARCHIVE_ENTRIES
    images: list = field(default_factory=list)      # [{"id", "data", "label"}]
    image_hashes: set = field(default_factory=set)
    notes: list = field(default_factory=list)       # what was skipped or capped, in plain words
    # Audio / video members of a document, archive or e-mail: never decoded here, only counted (contract v6:
    # "N 个媒体附件未读取（只在 Mac 上）").
    media_skipped: int = 0

    def note(self, text: str) -> None:
        if text not in self.notes and len(self.notes) < 40:
            self.notes.append(text)


@dataclass
class Parsed:
    type: str
    text: str = ""
    title: str = ""
    counts: dict = field(default_factory=dict)
    attachments: list = field(default_factory=list)   # [{"filename", "type", "summary"}]
    fields: list = field(default_factory=list)        # [{"key", "label", "value"}], values appear in text
    error: Optional[str] = None
    fmt: str = ""                                     # the routed format (docx, xlsx, eml, ...)

    def to_dict(self) -> dict:
        return {"type": self.type, "text": self.text, "title": self.title, "counts": self.counts,
                "attachments": self.attachments, "fields": self.fields, "error": self.error, "fmt": self.fmt}


# ---- routing -----------------------------------------------------------------------------------------

CODE_EXT = {
    "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "java", "kt", "kts", "swift", "m", "mm", "h", "hpp", "hh", "c",
    "cc", "cpp", "cxx", "cs", "go", "rs", "rb", "php", "pl", "pm", "lua", "r", "scala", "sh", "bash", "zsh",
    "fish", "ps1", "bat", "cmd", "sql", "css", "scss", "sass", "less", "vue", "svelte", "dart", "hs", "ex",
    "exs", "erl", "clj", "groovy", "gradle", "cmake", "makefile", "dockerfile", "tf", "proto", "graphql", "gql",
    "ini", "cfg", "conf", "toml", "env", "properties", "tex", "bib", "sty", "cls", "asm", "s", "v", "sv",
    "vhd", "vhdl", "jl", "nim", "zig", "f90", "f", "for", "pas", "vb", "vbs", "ipynb",
}
TEXT_EXT = {"txt", "text", "md", "markdown", "mdown", "rst", "adoc", "asciidoc", "org", "log", "srt", "vtt",
            "lrc", "nfo", "readme", "me", "todo", "diff", "patch"}
DATA_EXT = {"json", "jsonl", "ndjson", "geojson", "xml", "yaml", "yml", "plist", "opml", "rss", "atom", "kml",
            "gpx", "xsd", "xsl", "xslt", "svg"}
IMAGE_EXT = {"png", "jpg", "jpeg", "jpe", "gif", "webp", "tif", "tiff", "bmp", "dib", "ico"}
AUDIO_EXT = {"m4a", "mp3", "wav", "aac", "flac", "ogg", "opus", "amr", "caf", "aif", "aiff", "wma", "mid", "midi"}
VIDEO_EXT = {"mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "3gp", "mpg", "mpeg", "ts"}
IWORK_EXT = {"pages": "document", "numbers": "spreadsheet", "key": "slides"}
# WPS Office (common in China): .wps / .et / .dps are OLE files read like .doc / .xls / .ppt
WPS_EXT = {"wps": "document", "wpt": "document", "et": "spreadsheet", "ett": "spreadsheet", "dps": "slides",
           "dpt": "slides"}

OOXML_MAIN = {"word/document.xml": "docx", "xl/workbook.xml": "xlsx", "ppt/presentation.xml": "pptx"}
ODF_MIME = {"application/vnd.oasis.opendocument.text": "odt",
            "application/vnd.oasis.opendocument.text-template": "odt",
            "application/vnd.oasis.opendocument.spreadsheet": "ods",
            "application/vnd.oasis.opendocument.spreadsheet-template": "ods",
            "application/vnd.oasis.opendocument.presentation": "odp",
            "application/vnd.oasis.opendocument.presentation-template": "odp",
            "application/epub+zip": "epub"}


def is_media_name(name: str) -> bool:
    """An audio / video member by its name (never read, only counted)."""
    return ext_of(name) in AUDIO_EXT or ext_of(name) in VIDEO_EXT


MEDIA_SKIPPED_FMT = "media_skipped"   # Parsed.fmt of a nested audio / video part that was skipped


def ext_of(name: str) -> str:
    base = (name or "").rsplit("/", 1)[-1].lower()
    if base in ("makefile", "dockerfile", "readme", "license", "changelog"):
        return base if base in CODE_EXT else "txt"
    return base.rsplit(".", 1)[-1] if "." in base else ""


def sniff(data: bytes, name: str = "", mime: str = "") -> str:
    """The format to parse the bytes as: content signature first, then the extension, then the MIME type."""
    ext = ext_of(name)
    head = data[:8]
    if data.startswith(b"%PDF-") or b"%PDF-" in data[:1024]:
        return "pdf"
    if head.startswith(b"PK\x03\x04") or head.startswith(b"PK\x05\x06"):
        return "zip"  # refined by the zip reader (OOXML / ODF / EPUB / iWork / plain archive)
    if head.startswith(b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"):
        return "ole"
    if head.startswith(b"\x1f\x8b"):
        return "gzip"
    if head.startswith(b"BZh"):
        return "bz2"
    if head.startswith(b"\xfd7zXZ\x00"):
        return "xz"
    if head.startswith(b"7z\xbc\xaf\x27\x1c"):
        return "7z"
    if head.startswith(b"Rar!\x1a\x07"):
        return "rar"
    if len(data) > 262 and data[257:262] == b"ustar":
        return "tar"
    if head.startswith(b"bplist00"):
        return {"webarchive": "webarchive", "webloc": "webloc"}.get(ext, "plist")
    if head.startswith(b"\x89PNG") or head.startswith(b"\xff\xd8\xff") or head[:6] in (b"GIF87a", b"GIF89a") \
            or (head[:4] == b"RIFF" and data[8:12] == b"WEBP") or head[:4] in (b"II*\x00", b"MM\x00*") \
            or head[:2] == b"BM":
        return "image"
    if data.startswith(b"SQLite format 3\x00"):
        return "sqlite"
    if data[4:12] in (b"ftypheic", b"ftypheix", b"ftypmif1", b"ftyphevc", b"ftypavif"):
        return "heic"
    if data[4:8] == b"ftyp" or head[:4] in (b"RIFF", b"OggS", b"fLaC", b"ID3\x03", b"ID3\x04", b"#!AM", b"caff") \
            or ext in AUDIO_EXT or ext in VIDEO_EXT:
        return "media"
    if data.lstrip()[:5] == b"{\\rtf":
        return "rtf"
    if ext in ("eml", "emlx", "mht", "mhtml"):
        return "mht" if ext in ("mht", "mhtml") else "eml"
    if ext == "mbox" or ext == "mbx":
        return "mbox"
    if ext in ("ics", "ical", "ifb", "vcs"):
        return "ics"
    if ext in ("vcf", "vcard"):
        return "vcf"
    if ext == "url":
        return "url"
    if ext == "webloc":
        return "webloc"
    if ext in ("csv",):
        return "csv"
    if ext in ("tsv", "tab"):
        return "tsv"
    if ext in ("html", "htm", "xhtml", "shtml"):
        return "html"
    if ext == "ipynb":
        return "ipynb"
    if ext in ("json", "jsonl", "ndjson", "geojson"):
        return "json"
    if ext in ("yaml", "yml"):
        return "yaml"
    if ext in DATA_EXT:
        return "xml"
    if ext in CODE_EXT:
        return "code"
    if ext in TEXT_EXT:
        return "text"
    if ext in ("doc", "dot", "xls", "xlt", "ppt", "pps", "pot", "msg",
               "wps", "wpt", "et", "ett", "dps", "dpt"):  # WPS Office's own formats are OLE files like Office 97
        return "ole"
    # No extension we know: look at the content.
    sample = data[:4096]
    stripped = sample.lstrip()
    low = stripped[:200].lower()
    if low.startswith(b"<!doctype html") or low.startswith(b"<html"):
        return "html"
    if low.startswith(b"<?xml") or (low.startswith(b"<") and b">" in low):
        return "xml"
    if stripped[:15].upper().startswith(b"BEGIN:VCALENDAR"):
        return "ics"
    if stripped[:11].upper().startswith(b"BEGIN:VCARD"):
        return "vcf"
    if sample.startswith(b"From ") and b"\nFrom:" in data[:65536]:
        return "mbox"
    if re.match(rb"(?i)(received|return-path|from|message-id|mime-version|date|subject|to):", stripped[:40]) \
            and b"\n\n" in data[:65536].replace(b"\r\n", b"\n"):
        return "eml"
    if stripped[:1] in (b"{", b"[") and _looks_json(data):
        return "json"
    if mime.startswith("text/") or looks_text(sample):
        return "text"
    return "binary"


def _looks_json(data: bytes) -> bool:
    import json
    try:
        json.loads(decode_text(data[:2_000_000]))
        return True
    except ValueError:
        return False


def looks_text(sample: bytes) -> bool:
    if not sample:
        return True
    if b"\x00" in sample and not (sample.startswith(codecs.BOM_UTF16_LE) or sample.startswith(codecs.BOM_UTF16_BE)):
        return False
    try:
        sample.decode("utf-8")
        return True
    except UnicodeDecodeError as exc:
        if exc.start >= len(sample) - 3:  # a character cut at the end of the sample
            return True
    try:
        text = sample.decode("gb18030")
    except UnicodeDecodeError:
        return False
    bad = sum(1 for ch in text if ord(ch) < 32 and ch not in "\t\r\n\f")
    return bad < len(text) * 0.02


# ---- text helpers --------------------------------------------------------------------------------------


def decode_text(data: bytes, hint: str = "") -> str:
    """Bytes of a text file: BOM, the declared charset, UTF-8, then GB18030 (Chinese Windows files), else Latin-1."""
    if data.startswith(codecs.BOM_UTF8):
        return data[3:].decode("utf-8", "replace")
    if data.startswith(codecs.BOM_UTF16_LE) or data.startswith(codecs.BOM_UTF16_BE):
        return data.decode("utf-16", "replace")
    if hint:
        try:
            return data.decode(hint)
        except (LookupError, UnicodeDecodeError):
            pass
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        pass
    for enc in ("gb18030", "big5"):
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            continue
    return data.decode("latin-1")


def clean_text(text: str) -> str:
    """Normalize newlines, drop control characters, collapse runs of blank lines and trailing spaces."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"[\x00-\x08\x0b\x0e-\x1f\x7f]", "", text).replace("\x0c", "\n")
    text = re.sub(r"[ \t　]+\n", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def clip(text: str, limit: int) -> tuple[str, bool]:
    if len(text) <= limit:
        return text, False
    cut = text.rfind("\n", 0, limit)
    cut = cut if cut > limit * 0.8 else limit
    return text[:cut].rstrip(), True


def first_line(text: str, limit: int = 60) -> str:
    for line in (text or "").splitlines():
        line = re.sub(r"^[#>\-*\s|]+", "", line).strip()
        line = re.sub(r"\[\[IMG:\d+\]\]", "", line).strip()
        if len(line) >= 2:
            return line[:limit]
    return ""


def cell_text(value) -> str:
    """One spreadsheet cell as printed: dates as ISO, whole floats without ".0", no line breaks."""
    import datetime as _dt
    if value is None:
        return ""
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, _dt.datetime):
        return value.strftime("%Y-%m-%d %H:%M") if (value.hour or value.minute) else value.strftime("%Y-%m-%d")
    if isinstance(value, (_dt.date, _dt.time)):
        return value.isoformat()
    if isinstance(value, float):
        if value.is_integer() and abs(value) < 1e15:
            return str(int(value))
        return repr(round(value, 10)).rstrip("0").rstrip(".") if "e" not in repr(value) else repr(value)
    text = str(value)
    return re.sub(r"\s*\n\s*", " / ", text).replace("|", "\\|").strip()


def number_as_shown(value, fmt: str) -> str:
    """A spreadsheet number the way its number format shows it (25%, 1,280.00, ¥36.50); anything the
    format rules here do not cover is written as cell_text() writes it."""
    if not isinstance(value, (int, float)) or isinstance(value, bool) or not fmt or fmt == "General":
        return cell_text(value)
    try:
        raw = fmt.split(";")[0]
        m = re.search(r"\[\$([^\]-]*)", raw)
        symbol = m.group(1) if m else next((c for c in "¥￥$€£" if c in raw), "")
        section = re.sub(r'\[[^\]]*\]|"[^"]*"|\\.|_.|\*.', "", raw)   # colors, locales, literals, padding
        digits = re.search(r"[#0,]*0(?:\.(0+))?", section)
        if not digits:
            return cell_text(value)
        places = len(digits.group(1) or "")
        pct = "%" in section
        shown = value * 100 if pct else value
        text = f"{shown:,.{places}f}" if "," in digits.group(0) else f"{shown:.{places}f}"
        return f"{symbol}{text}{'%' if pct else ''}"
    except (ValueError, TypeError, OverflowError):
        return cell_text(value)


def md_table(rows: list[list[str]], max_rows: int = MAX_SHEET_ROWS, max_cols: int = MAX_SHEET_COLS) -> tuple[str, int]:
    """Compact markdown table: empty rows and all-empty columns dropped; first row is the header.
    Returns (table, rows left out)."""
    rows = [r for r in rows if any(c.strip() for c in r)]
    if not rows:
        return "", 0
    width = min(max(len(r) for r in rows), max_cols)
    keep = [j for j in range(width) if any(j < len(r) and r[j].strip() for r in rows)]
    shown = rows[:max_rows + 1]
    lines = []
    for i, r in enumerate(shown):
        cells = [(r[j] if j < len(r) else "").strip() for j in keep]
        lines.append("| " + " | ".join(cells) + " |")
        if i == 0:
            lines.append("|" + "---|" * len(keep))
    return "\n".join(lines), max(0, len(rows) - len(shown))


def delimited_rows(text: str, delimiter: Optional[str] = None, limit: int = 100_000) -> list[list[str]]:
    sample = text[:20000]
    if delimiter is None:
        try:
            delimiter = csv.Sniffer().sniff(sample, delimiters=",;\t|").delimiter
        except csv.Error:
            delimiter = ","
    rows = []
    for i, row in enumerate(csv.reader(io.StringIO(text), delimiter=delimiter)):
        if i >= limit:
            break
        rows.append([cell_text(c) for c in row])
    return rows


class _HTMLText(HTMLParser):
    BLOCK = {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article", "header",
             "footer", "blockquote", "pre", "table", "ul", "ol", "dt", "dd", "hr", "figure", "figcaption", "main",
             "nav", "aside", "title"}
    SKIP = {"script", "style", "noscript", "template", "svg", "head", "iframe", "object", "canvas", "math"}

    def __init__(self, on_image: Optional[Callable[[str], Optional[str]]] = None):
        super().__init__(convert_charrefs=True)
        self.out: list[str] = []
        self.skip = 0
        self.title = ""
        self._in_title = False
        self.on_image = on_image
        self.cell = False

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP and tag != "head":
            self.skip += 1
            return
        if tag == "title":
            self._in_title = True
        if tag in ("h1", "h2", "h3"):
            self.out.append("\n" + "#" * int(tag[1]) + " ")
        elif tag == "li":
            self.out.append("\n- ")
        elif tag in ("td", "th"):
            self.out.append(" | ")
        elif tag in self.BLOCK:
            self.out.append("\n")
        if tag == "img" and self.on_image is not None and not self.skip:
            src = dict(attrs).get("src") or ""
            marker = self.on_image(src)
            if marker:
                self.out.append(f"\n{marker}\n")

    def handle_endtag(self, tag):
        if tag in self.SKIP and tag != "head":
            self.skip = max(0, self.skip - 1)
            return
        if tag == "title":
            self._in_title = False
        if tag in self.BLOCK:
            self.out.append("\n")

    def handle_data(self, data):
        if self._in_title:
            self.title += data
            return
        if not self.skip:
            self.out.append(re.sub(r"[ \t\r\n]+", " ", data))


def html_to_text(markup: str, on_image: Optional[Callable[[str], Optional[str]]] = None) -> tuple[str, str]:
    """(title, text) of an HTML page: visible text in reading order, scripts / styles dropped."""
    p = _HTMLText(on_image)
    try:
        p.feed(markup)
        p.close()
    except Exception:  # noqa: BLE001 - malformed markup: keep what was read
        pass
    text = "".join(p.out)
    text = "\n".join(line.strip() for line in text.splitlines())
    return html.unescape(p.title).strip(), clean_text(text)
