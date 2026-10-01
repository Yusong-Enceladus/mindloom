"""Reading a file item (kind "file") with the file-read skill.

  1. parse   organizer/fileparse in a sandboxed child process: route by content signature / extension,
             extract the text (tables as markdown, sections marked), collect image parts (scanned PDF pages
             <= 20, embedded pictures <= 10) and deterministic fields (mail headers, calendar, contact).
  2. images  every image part is read with image-read (the same two steps as an image item, same clients);
             its reading replaces the part's marker in the text.
  3. summary the file-read skill writes a one-line summary (+ doc_kind, key fields for receipt-like
             documents); scripts/validate.py checks that its numbers and field values appear in the text.
             Output that fails twice is sanitized; an empty summary falls back to a plain one written here.

The reading (contract "file", 2026-09-29) is {type, text, summary, fields, counts, attachments, error?,
source: "file-read"}; the text used for organizing is the reading text (+ summary).

Pictures inside the bytes are read (step 2) only when the Mac says it redacted every one of them in the send copy
(`meta["pictures_redacted"]`, privacy review F3); otherwise they are skipped and counted.

Privacy (contract v6): with `mask` (the store's mask function, organizer/masking.py) every text read from the
bytes (the extracted text, title, fields, attachment names and summaries, each image part's reading) is masked
before it goes into the summary prompt or the returned reading. Audio and video inside a document or archive
are never decoded here: the parser skips them and the text records only "N 个媒体附件未读取（只在 Mac 上）".
An encrypted / corrupt / unsupported / too large file gets a reading with `error` set, the Mac's
local_text (if any) as its text and a plain summary, so the item is still organized by what is known.
"""

from __future__ import annotations

import hashlib
import logging
import re
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Callable, Optional

from . import fileparse
from .clients import ChatClient, ModelUnavailable, safe_error
from .image_read import read_image
from .skills import Harness

log = logging.getLogger("organizer.file_read")

SKILL = "file-read"
TEXT_CAP = 60_000
EXCERPT_CHARS = 8_000
IMAGE_WORKERS = 4
MARKER = re.compile(r"\[\[IMG:(\d+)\]\]")

TYPE_LABEL = {"text": "文本", "document": "文档", "spreadsheet": "表格", "slides": "演示文稿", "pdf": "PDF 文档",
              "scanned_pdf": "扫描版 PDF", "email": "邮件", "calendar": "日程", "contact": "联系人", "ebook": "电子书",
              "archive": "压缩包", "web": "网页", "code": "代码", "data": "数据文件", "image": "图片"}
ERROR_LABEL = {"encrypted": "已加密，需要密码，未读取内容", "unsupported": "格式暂不支持，未读取内容",
               "too_large": "文件过大，未读取内容", "corrupt": "文件已损坏，无法读取"}
EXT_TYPE = {"doc": "document", "docx": "document", "pages": "document", "rtf": "document", "odt": "document",
            "xls": "spreadsheet", "xlsx": "spreadsheet", "numbers": "spreadsheet", "csv": "spreadsheet",
            "ppt": "slides", "pptx": "slides", "key": "slides", "pdf": "pdf", "eml": "email", "msg": "email",
            "ics": "calendar", "vcf": "contact", "epub": "ebook", "zip": "archive", "html": "web", "htm": "web",
            "txt": "text", "md": "text", "json": "data", "wps": "document", "et": "spreadsheet", "dps": "slides",
            "xmind": "document"}


@dataclass
class FileReading:
    type: str
    text: str
    summary: str
    fields: list
    counts: dict
    attachments: list
    error: Optional[str]
    doc_kind: str = ""
    notes: list = field(default_factory=list)
    run_id: Optional[str] = None           # the summary run (None when no model call was made)
    image_run_ids: list = field(default_factory=list)
    summary_source: str = "model"          # model | sanitized | plain
    latency_s: float = 0.0

    def reading(self) -> dict:
        """The stored reading meta (item_derived.reading); text and summary are stored in their own columns."""
        out = {"type": self.type, "fields": self.fields, "counts": self.counts, "attachments": self.attachments,
               "source": "file-read", "doc_kind": self.doc_kind, "summary_source": self.summary_source,
               "notes": self.notes[:20], "image_run_ids": self.image_run_ids}
        if self.error:
            out["error"] = self.error
        return out


def _ext(name: str) -> str:
    base = (name or "").rsplit("/", 1)[-1].lower()
    return base.rsplit(".", 1)[-1] if "." in base else ""


def plain_summary(typ: str, filename: str, title: str, error: Optional[str]) -> str:
    """The organizer's own summary when there is no model summary: what the file is, by its title or name."""
    label = TYPE_LABEL.get(typ, "文件")
    name = (title or filename or "").strip()
    if error:
        return f"{label}「{filename}」{ERROR_LABEL.get(error, '未读取内容')}"[:80]
    return f"{label}：{name}"[:80] if name else label


def clip(text: str, limit: int) -> tuple[str, bool]:
    if len(text) <= limit:
        return text, False
    cut = text.rfind("\n", 0, limit)
    cut = cut if cut > limit * 0.8 else limit
    return text[:cut].rstrip(), True


def excerpt(text: str, limit: int = EXCERPT_CHARS) -> str:
    """Head and tail of a long text (the model sees where a document starts and how it ends)."""
    if len(text) <= limit:
        return text
    head = text[:int(limit * 0.8)]
    tail = text[-int(limit * 0.2):]
    return f"{head}\n……（中间省略 {len(text) - len(head) - len(tail)} 字）……\n{tail}"


def media_note(n: int) -> str:
    return f"{n} 个媒体附件未读取（只在 Mac 上）"


def pictures_note(n: int) -> str:
    return f"{n} 张图片未读取（未经 Mac 遮盖）"


def read_file(harness: Harness, data: Optional[bytes], meta: dict, *, subject: Optional[str] = None,
              clients: Optional[dict[str, ChatClient]] = None, as_of: Optional[str] = None,
              parse: Callable[..., dict] = fileparse.parse_file, image_workers: int = IMAGE_WORKERS,
              mask: Optional[Callable[[str], str]] = None) -> FileReading:
    """Read one file. `meta` is the item's file metadata (filename, mime, sha256, local_text, source_app,
    captured_at). Raises ModelUnavailable when the model is down (the job is retried later). `mask` masks
    every text read from the bytes before it is used (the organizer passes the store's mask function)."""
    m: Callable[[str], str] = mask or (lambda t: t)
    started = time.time()
    filename = str(meta.get("filename") or "文件")
    local_text = str(meta.get("local_text") or "").strip()
    expected = str(meta.get("sha256") or "").lower()
    notes: list[str] = []
    if data is None:
        parsed = fileparse.failure(None, "")  # type: ignore[arg-type]
        parsed["type"] = EXT_TYPE.get(_ext(filename), "document")
        parsed["notes"] = []
        if not local_text:
            parsed["error"] = "too_large" if meta.get("size") and int(meta["size"]) > 25 * 1024 * 1024 else "unsupported"
    elif re.fullmatch(r"[0-9a-f]{64}", expected) and hashlib.sha256(data).hexdigest() != expected:
        parsed = fileparse.failure("corrupt", "文件内容与校验值不符")
        parsed["type"] = EXT_TYPE.get(_ext(filename), "data")
    else:
        parsed = parse(data, filename, str(meta.get("mime") or ""))
    typ = parsed.get("type") or EXT_TYPE.get(_ext(filename), "data")
    notes += parsed.get("notes") or []
    error = parsed.get("error")
    # Everything below the parse is masked text: the prompt and the stored reading never see raw identifiers.
    parsed["text"] = m(parsed.get("text") or "")
    parsed["title"] = m(parsed.get("title") or "")
    parsed["fields"] = [dict(f, value=m(str(f.get("value") or "")), label=m(str(f.get("label") or "")))
                        for f in parsed.get("fields") or [] if isinstance(f, dict)]
    parsed["attachments"] = [dict(a, filename=m(str(a.get("filename") or "")), summary=m(str(a.get("summary") or "")))
                             for a in parsed.get("attachments") or [] if isinstance(a, dict)]
    notes = [m(str(n)) for n in notes]
    media_skipped = int(parsed.get("media_skipped") or 0)

    # (2) image parts. Only a picture the Mac redacted may reach a model (contract section 4): pictures inside the
    # file bytes (scanned PDF pages, pictures in a document, an image or a zip of images under a document's name)
    # are read only when the Mac rebuilt the send copy with every picture redacted (`pictures_redacted`); else
    # they are skipped and counted (privacy review F3).
    readings: dict[int, str] = {}
    image_run_ids: list[str] = []
    images = parsed.get("images") or []
    pictures_skipped = 0
    if images and not meta.get("pictures_redacted"):
        pictures_skipped, images = len(images), []
    if images:
        ctx = {"source_app": (meta.get("source_app") or {}).get("name", "") if isinstance(meta.get("source_app"), dict)
               else str(meta.get("source_app") or ""), "captured_at": meta.get("captured_at") or ""}

        def one(im: dict):
            try:
                return im, read_image(harness, im["data"], ctx, subject=subject, clients=clients, as_of=as_of)
            except ValueError as exc:  # the endpoint cannot take images: keep the text without this part
                log.warning("image part %s of %s not read: %s", im["id"], subject, safe_error(exc))
                return im, None

        with ThreadPoolExecutor(max_workers=max(1, min(image_workers, len(images)))) as pool:
            results = list(pool.map(one, images))  # ModelUnavailable propagates (the job is retried)
        for im, res in results:
            if res is None or not res.ok:
                continue
            r = res.reading
            body = (r.get("text") or "").strip()
            gist = (r.get("gist") or "").strip()
            if not body and not gist:
                continue
            readings[im["id"]] = m(f"[{im['label']}·图片识别] {gist}".rstrip() + (f"\n{body}" if body else ""))
            if res.run_id:
                image_run_ids.append(res.run_id)
    text = MARKER.sub(lambda mt: readings.get(int(mt.group(1)), ""), parsed.get("text") or "")
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    counts = dict(parsed.get("counts") or {})
    if images:
        counts["images_read"] = len(readings)
    if pictures_skipped:
        counts["pictures_skipped"] = pictures_skipped
        text = (text + "\n\n" if text else "") + pictures_note(pictures_skipped)
        notes.append(pictures_note(pictures_skipped))
    if media_skipped:
        # Audio / video inside the file stay unread here; only their number is recorded.
        counts["media_skipped"] = media_skipped
        text = (text + "\n\n" if text else "") + media_note(media_skipped)
        notes.append(media_note(media_skipped))
    if typ == "image" and not readings and not error and not text:
        error = "unsupported"

    # Mac-side text: used when the Spark could not read the file or got (almost) nothing out of it.
    if local_text and len(text.replace(" ", "")) < 20 and len(local_text) > len(text):
        text = m(local_text)
        notes.append("正文来自 Mac 端提取的文字")
    text, cut = clip(text, TEXT_CAP)
    if cut:
        notes.append(f"正文较长，只保留前 {TEXT_CAP} 字")
    fields = [f for f in parsed.get("fields") or [] if isinstance(f, dict) and f.get("value")]
    attachments = parsed.get("attachments") or []
    title = parsed.get("title") or ""

    # (3) summary
    summary, doc_kind, source, run_id = "", "", "plain", None
    if text.strip() and not error:
        summary, doc_kind, source, run_id, extra = _summarize(harness, filename, typ, title, counts, fields, text,
                                                              subject=subject, as_of=as_of)
        fields = fields + extra
    if not summary:
        summary, source = plain_summary(typ, m(filename), title, error), "plain"
    summary = m(summary)
    fields = [dict(f, value=m(str(f.get("value") or ""))) for f in fields]
    return FileReading(type=typ, text=text, summary=summary, fields=fields, counts=counts, attachments=attachments,
                       error=error, doc_kind=doc_kind, notes=notes, run_id=run_id, image_run_ids=image_run_ids,
                       summary_source=source, latency_s=time.time() - started)


def _summarize(harness: Harness, filename: str, typ: str, title: str, counts: dict, fields: list, text: str, *,
               subject: Optional[str], as_of: Optional[str]) -> tuple[str, str, str, Optional[str], list]:
    validate_mod = harness.registry.script(SKILL, "validate")
    given = [f.get("key") for f in fields]
    context = {"text": text, "extra_numbers": [str(v) for v in counts.values() if isinstance(v, int)],
               "given_keys": given}
    data = {"filename": filename, "type": typ, "counts": counts, "title": title,
            "fields": [{"key": f.get("key"), "label": f.get("label", ""), "value": f.get("value")} for f in fields],
            "text": excerpt(text)}
    try:
        res = harness.run("file_read", data, context=context, subject=subject, as_of=as_of)
    except ValueError as exc:  # the endpoint rejected the request
        log.warning("file-read summary rejected for %s: %s", subject, safe_error(exc))
        return "", "", "plain", None, []
    except ModelUnavailable:
        raise
    output, source = res.output, "model"
    if not res.ok:
        if res.candidate is None:
            return "", "", "plain", res.run_id, []
        output, _ = validate_mod.sanitize(res.candidate, context)
        source = "sanitized"
    summary = (output.get("summary") or "").strip()
    extra = [{"key": f["key"], "label": f.get("label", ""), "value": f["value"]}
             for f in output.get("fields") or [] if isinstance(f, dict) and f.get("key") not in given]
    return summary, output.get("doc_kind") or "", source, res.run_id, extra
