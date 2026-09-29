#!/usr/bin/env python3
"""Build the synthetic multi-format file-reading eval set (no model calls).

  python eval/files-multiformat/tools/build.py            # writes eval/files-multiformat/{corpus,truth,manifest.json,scenario-multiformat/}

Needs: Pillow, python-docx, XlsxWriter, python-pptx, odfpy, PyMuPDF, imageio-ffmpeg (ffmpeg binary), and macOS
textutil / sips / plutil. Output is deterministic up to encoder versions. Every file is invented (合成数据).
Each file gets a ground-truth JSON; every QA answer is checked to be present in the file's canonical text and the
build fails otherwise.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import io
import json
import mailbox
import os
import random
import re
import shutil
import sys
import tempfile
import uuid
from email import policy
from email.message import EmailMessage
from email.utils import format_datetime, formataddr

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import content_families as CF  # noqa: E402
import content_matters as CM  # noqa: E402
import content_special as CS  # noqa: E402
import extract as X  # noqa: E402
import render as R  # noqa: E402
from PIL import Image, ImageDraw, ImageFilter  # noqa: E402

ROOT = os.path.dirname(HERE)  # eval/files-multiformat
TYPES = ["txt", "md", "rtf", "html", "csv", "json", "xml", "docx", "doc", "odt", "xlsx", "ods", "pptx", "odp", "pdf", "pdf_scanned",
         "epub", "eml", "mbox", "ics", "vcf", "zip", "webarchive", "png", "jpg", "heic", "webp", "gif", "tiff", "bmp", "svg", "mp4", "mov"]
EXT = {t: t for t in TYPES}
EXT["pdf_scanned"] = "pdf"
MIME = {"txt": "text/plain", "md": "text/markdown", "rtf": "application/rtf", "html": "text/html", "csv": "text/csv",
        "json": "application/json", "xml": "application/xml",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "doc": "application/msword",
        "odt": "application/vnd.oasis.opendocument.text", "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ods": "application/vnd.oasis.opendocument.spreadsheet",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "odp": "application/vnd.oasis.opendocument.presentation", "pdf": "application/pdf", "pdf_scanned": "application/pdf",
        "epub": "application/epub+zip", "eml": "message/rfc822", "mbox": "application/mbox", "ics": "text/calendar", "vcf": "text/vcard",
        "zip": "application/zip", "webarchive": "application/x-webarchive", "png": "image/png", "jpg": "image/jpeg", "heic": "image/heic",
        "webp": "image/webp", "gif": "image/gif", "tiff": "image/tiff", "bmp": "image/bmp", "svg": "image/svg+xml", "mp4": "video/mp4",
        "mov": "video/quicktime"}
IMAGE_TYPES = {"png", "jpg", "heic", "webp", "gif", "tiff", "bmp", "svg"}
VIDEO_TYPES = {"mp4", "mov"}
NS = uuid.UUID("6f2c1d4e-6a53-4f7e-9d3b-5b1d2f6a8c01")  # uuid5 namespace for this eval set


def uid(name: str) -> str:
    return str(uuid.uuid5(NS, name)).upper()


# ============================================================================== canonical text helpers

def doc_lines(doc: dict) -> list[str]:
    out = []
    if doc.get("letterhead"):
        out.append(doc["letterhead"])
    if doc.get("front_matter"):
        out += [f"{k}: {v}" for k, v in doc["front_matter"].items()]
    lines = R.blocks_to_lines(doc)
    out.append(lines[0])
    if doc.get("subtitle"):
        out.append(doc["subtitle"])
    out += lines[1:]
    if doc.get("signature"):
        out.append(doc["signature"])
    out.append(R.mark_for(doc))  # every prose renderer writes this mark into the text layer or the picture
    return [x for x in out if x.strip()]


def _cell_display(v):
    if isinstance(v, dict):
        v = v["v"]
    if v is None:
        return ""
    if isinstance(v, float) and abs(v - round(v)) < 1e-9:
        return str(int(round(v)))
    return str(v)


def sheet_lines(sheets: list[dict]) -> list[str]:
    out = []
    for sh in sheets:
        out.append(f"[{sh['name']}]")
        if sh.get("title"):
            out.append(sh["title"])
        if sh.get("group_header"):
            out.append("\t".join(t for _, _, t in sh["group_header"]))
        out.append("\t".join(sh["columns"]))
        covered = {(k, col) for (col, a, b) in sh.get("vmerge", []) for k in range(a + 1, b + 1)}
        for ri, r in enumerate(sh["rows"]):
            out.append("\t".join("" if (ri, ci) in covered else _cell_display(v) for ci, v in enumerate(r)))
        out.append(R.MARK)
    return out


def slide_lines(s: dict) -> list[str]:
    out = [s["title"]]
    if s.get("subtitle"):
        out.append(s["subtitle"])
    if s.get("big"):
        out.append(s["big"])
    out += s.get("bullets", [])
    if s.get("table"):
        t = s["table"]
        out.append("\t".join(t["columns"]))
        out += ["\t".join(R.cell_str(c) for c in r) for r in t["rows"]]
    if s.get("chart"):
        c = s["chart"]
        out.append(c["title"])
        for name, vals in c["series"].items():
            out.append(f"{name}: " + ", ".join(f"{x} {v:g}" if isinstance(v, float) else f"{x} {v:,}" for x, v in zip(c["xlabels"], vals)))
    out.append(R.MARK)  # drawn in the corner of every picture slide / frame, a text box on text slides
    return out


# ============================================================================== visuals

def render_detect(v: dict, rng: random.Random, w=640, h=400):
    im = Image.new("RGB", (w, h), (120, 124, 128))
    px = Image.effect_noise((w, h), 30).convert("RGB")
    im = Image.blend(im, px, 0.35)
    grad = Image.linear_gradient("L").resize((w, h)).rotate(90)
    im = Image.composite(im, Image.blend(im, Image.new("RGB", (w, h), (170, 174, 178)), 0.5), grad)
    d = ImageDraw.Draw(im)
    for _ in range(40):  # brushed metal
        y = rng.randrange(h)
        d.line((0, y, w, y + rng.randint(-3, 3)), fill=(140, 144, 148), width=1)
    d.line((120, 110, 330, 96), fill=(215, 215, 220), width=3)  # scratch
    d.ellipse((425, 245, 455, 275), fill=(70, 72, 76))  # dent
    for label, (x0, y0, x1, y1) in v["boxes"]:
        d.rectangle((x0, y0, x1, y1), outline=(255, 60, 60), width=3)
        tw = R.font(20, True).getlength(label)
        d.rectangle((x0, y0 - 28, x0 + tw + 12, y0), fill=(255, 60, 60))
        d.text((x0 + 6, y0 - 26), label, font=R.font(20, True), fill=(255, 255, 255))
    d.rectangle((0, 0, w, 34), fill=(20, 22, 26))
    d.text((10, 6), v["header"], font=R.font(18), fill=(235, 235, 235))
    d.text((w - R.font(16).getlength(R.MARK) - 10, h - 26), R.MARK, font=R.font(16), fill=(255, 120, 110))
    return im, [v["header"]] + [b[0] for b in v["boxes"]] + [R.MARK]


def render_visual(v: dict, rng: random.Random):
    """-> (PIL image, visible text lines)."""
    st = v["style"]
    if st == "chart":
        im = R.render_chart(v["title"], v["series"], v["xlabels"], kind=v.get("kind", "line"), w=v.get("w", 1200), h=v.get("h", 760),
                            ylabel=v.get("ylabel", ""), notes=v.get("notes"))
        lines = [v["title"], "  ".join(v["xlabels"])]
        for name, vals in v["series"].items():
            lines.append(f"{name}: " + ", ".join(f"{x} {val:g}" if isinstance(val, float) else f"{x} {val:,}" for x, val in zip(v["xlabels"], vals)))
        lines += v.get("notes") or []
        if v.get("ylabel"):
            lines.append(v["ylabel"])
        return im, lines + [R.MARK]
    if st == "detect":
        return render_detect(v, rng)
    if st == "window":
        im = R.render_window(v["app"], v["lines"], fields=v.get("fields"), table=v.get("table"), badge=v.get("badge"))
        lines = [v["app"]] + list(v["lines"]) + [f"{k} {val}" for k, val in (v.get("fields") or [])]
        if v.get("badge"):
            lines.append(v["badge"])
    else:  # card
        kw = {k: v[k] for k in ("bg", "accent", "fg", "line_size") if k in v}
        im = R.render_card(v["title"], v.get("lines", []), w=v.get("w", 1000), fields=v.get("fields"), table=v.get("table"), **kw)
        if v.get("photo"):
            im = R.photo_effect(im, rng)
        lines = [v["title"]] + list(v.get("lines", [])) + [f"{k} {val}" for k, val in (v.get("fields") or [])]
    t = v.get("table")
    if t:
        lines.append("\t".join(t["columns"]))
        lines += ["\t".join(R.cell_str(c) for c in r) for r in t["rows"]]
    return im, lines + [R.MARK]


def svg_render(spec: dict) -> tuple[str, list[str]]:
    e = lambda s: s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")  # noqa: E731
    font = "font-family=\"PingFang SC, Hiragino Sans GB, Microsoft YaHei, Noto Sans CJK SC, sans-serif\""
    texts: list[str] = []
    parts: list[str] = []

    def text(x, y, s, size, fill="#222", anchor="start", weight="normal"):
        texts.append(s)
        parts.append(f'<text x="{x}" y="{y}" {font} font-size="{size}" fill="{fill}" text-anchor="{anchor}" font-weight="{weight}">{e(s)}</text>')

    if "lines" in spec:
        W, H = 900, 140 + 78 * len(spec["lines"])
        parts.append(f'<rect width="{W}" height="{H}" fill="{spec["bg"]}"/>')
        parts.append(f'<rect x="30" y="30" width="{W - 60}" height="{H - 60}" fill="none" stroke="#f5d58a" stroke-width="3" rx="16"/>')
        y = 110
        for s, size, fill in spec["lines"]:
            text(W / 2, y, s, size, fill, "middle", "bold" if size >= 40 else "normal")
            y += 78
    elif "chart" in spec:
        c = spec["chart"]
        W, H = 900, 560
        parts.append(f'<rect width="{W}" height="{H}" fill="#ffffff"/>')
        text(40, 50, c["title"], 30, "#1f3b63", weight="bold")
        mx = max(c["values"]) or 1
        bw = (W - 160) / len(c["values"])
        for i, (lab, val) in enumerate(zip(c["labels"], c["values"])):
            x = 100 + i * bw
            bh = (H - 200) * val / mx
            parts.append(f'<rect x="{x + 10:.1f}" y="{H - 100 - bh:.1f}" width="{bw - 20:.1f}" height="{bh:.1f}" fill="#2f6db5"/>')
            text(x + bw / 2, H - 110 - bh, str(val), 22, "#222", "middle")
            text(x + bw / 2, H - 66, lab, 20, "#222", "middle")
        parts.append(f'<line x1="90" y1="{H - 100}" x2="{W - 40}" y2="{H - 100}" stroke="#333" stroke-width="2"/>')
    elif "org" in spec:
        o = spec["org"]
        W, H = 960, 420
        parts.append(f'<rect width="{W}" height="{H}" fill="#fbfbf8"/>')
        text(W / 2, 50, o["title"], 30, "#1f3b63", "middle", "bold")
        top = [b for b in o["boxes"] if b[2] == 0][0]
        subs = [b for b in o["boxes"] if b[2] == 1]
        parts.append(f'<rect x="{W / 2 - 120}" y="90" width="240" height="80" rx="10" fill="#dde6f2" stroke="#1f3b63"/>')
        text(W / 2, 122, top[0], 22, "#1f3b63", "middle")
        text(W / 2, 154, top[1], 24, "#222", "middle", "bold")
        for i, (role, name, _) in enumerate(subs):
            cx = 180 + i * 300
            parts.append(f'<line x1="{W / 2}" y1="170" x2="{cx}" y2="250" stroke="#888" stroke-width="2"/>')
            parts.append(f'<rect x="{cx - 120}" y="250" width="240" height="80" rx="10" fill="#ffffff" stroke="#1f3b63"/>')
            text(cx, 282, role, 22, "#1f3b63", "middle")
            text(cx, 314, name, 24, "#222", "middle", "bold")
    else:
        st = spec["seats"]
        W, H = 900, 420
        parts.append(f'<rect width="{W}" height="{H}" fill="#ffffff"/>')
        text(W / 2, 50, st["title"], 30, "#1f3b63", "middle", "bold")
        parts.append(f'<rect x="250" y="75" width="400" height="30" fill="#e8e8e8"/>')
        text(W / 2, 97, "讲台", 20, "#555", "middle")
        for i, name in enumerate(st["names"]):
            r, cidx = divmod(i, st["cols"])
            seat = f"{'AB'[r]}{cidx + 1}"
            x, y = 150 + cidx * 220, 150 + r * 120
            parts.append(f'<rect x="{x}" y="{y}" width="180" height="90" rx="8" fill="#f3f7fc" stroke="#2f6db5"/>')
            text(x + 90, y + 36, seat, 22, "#2f6db5", "middle", "bold")
            text(x + 90, y + 70, name, 24, "#222", "middle")
    W = re.search(r'width="(\d+)"', parts[0]).group(1)
    H = re.search(r'height="(\d+)"', parts[0]).group(1)
    texts.append(R.MARK)
    parts.append(f'<text x="{int(W) - 16}" y="{int(H) - 14}" {font} font-size="16" fill="#e0564a" text-anchor="end">{R.MARK}</text>')
    svg = (f'<?xml version="1.0" encoding="UTF-8"?>\n<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
           f'viewBox="0 0 {W} {H}">\n<title>{e(texts[0])}</title>\n' + "\n".join(parts) + "\n</svg>\n")
    return svg, texts


# ============================================================================== calendar / contacts / mail

def _ics_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\n", "\\n")


def _fold(line: str) -> str:
    out, cur = [], b""
    for ch in line:
        bch = ch.encode("utf-8")
        if len(cur) + len(bch) > (75 if not out else 74):
            out.append(cur.decode("utf-8"))
            cur = b""
        cur += bch
    out.append(cur.decode("utf-8"))
    return "\r\n ".join(out)


def ics_text(cal: dict) -> str:
    L = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//synthetic-eval//files eval//ZH", "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
         f"X-WR-CALNAME:{_ics_escape(cal.get('name', ''))}", "BEGIN:VTIMEZONE", "TZID:Asia/Shanghai", "BEGIN:STANDARD",
         "DTSTART:19700101T000000", "TZOFFSETFROM:+0800", "TZOFFSETTO:+0800", "TZNAME:CST", "END:STANDARD", "END:VTIMEZONE"]
    for ev in cal["events"]:
        L += ["BEGIN:VEVENT", f"UID:{ev['uid']}", "DTSTAMP:20261001T010000Z", f"SUMMARY:{_ics_escape(ev['summary'])}"]
        if ev.get("start_date"):
            L += [f"DTSTART;VALUE=DATE:{ev['start_date']}", f"DTEND;VALUE=DATE:{ev['end_date']}"]
        else:
            L += [f"DTSTART;TZID=Asia/Shanghai:{ev['start']}", f"DTEND;TZID=Asia/Shanghai:{ev['end']}"]
        if ev.get("rrule"):
            L.append(f"RRULE:{ev['rrule']}")
        if ev.get("location"):
            L.append(f"LOCATION:{_ics_escape(ev['location'])}")
        if ev.get("description"):
            L.append(f"DESCRIPTION:{_ics_escape(ev['description'])}")
        if ev.get("organizer"):
            n, a = ev["organizer"]
            L.append(f'ORGANIZER;CN="{n}":mailto:{a}')
        for n, a in ev.get("attendees", []):
            L.append(f'ATTENDEE;CN="{n}";ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION:mailto:{a}')
        if ev.get("alarm"):
            L += ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder", f"TRIGGER:{ev['alarm']}", "END:VALARM"]
        L.append("END:VEVENT")
    L.append("END:VCALENDAR")
    return "\r\n".join(_fold(x) for x in L) + "\r\n"


def _qp(s: str) -> str:
    return "".join(ch if (ch.isascii() and ch not in "=\r\n") else "".join(f"={b:02X}" for b in ch.encode("utf-8")) for ch in s)


def vcf_text(contacts: list[dict], version: str = "3.0") -> str:
    L = []
    for c in contacts:
        L += ["BEGIN:VCARD", f"VERSION:{version}"]
        def prop(name, value, typ=None):
            if value is None or value == "":
                return
            p = name + (f";TYPE={typ}" if typ and version != "2.1" else (f";{typ}" if typ else ""))
            if version == "2.1" and not value.isascii():
                L.append(f"{p};CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE:{_qp(value)}")
            else:
                L.append(f"{p}:{value}")
        prop("N", f"{c.get('family', '')};{c.get('given', '')};;;")
        prop("FN", c["fn"])
        prop("ORG", c.get("org"))
        prop("TITLE", c.get("title"))
        prop("TEL", c.get("tel"), "CELL" if version != "4.0" else "cell")
        prop("TEL", c.get("tel2"), "WORK" if version != "4.0" else "work")
        prop("EMAIL", c.get("email"), "INTERNET" if version == "3.0" else ("work" if version == "4.0" else None))
        if c.get("adr"):
            prop("ADR", ";".join(c["adr"]), "WORK" if version != "4.0" else "work")
        prop("URL", c.get("url"))
        note = c.get("note")
        prop("NOTE", f"{note}（{R.MARK}）" if note and R.MARK not in note else (note or R.MARK))
        L.append("END:VCARD")
    return "\r\n".join(_fold(x) if version != "2.1" else x for x in L) + "\r\n"


def member_bytes(m: dict, tmp: str, rng: random.Random) -> tuple[bytes, list[str]]:
    """Render one zip member / e-mail attachment. Returns bytes and lines drawn only in pictures."""
    k = m["kind"]
    fd, p = tempfile.mkstemp(dir=tmp, suffix="." + {"text": "txt", "image": m.get("fmt", "jpg")}.get(k, k))
    os.close(fd)
    drawn: list[str] = []
    if k == "text":
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(m["text"])
    elif k == "csv":
        R.write_csv(p, m["columns"], m["rows"])
    elif k == "json":
        with open(p, "w", encoding="utf-8") as fh:
            json.dump(m["record"], fh, ensure_ascii=False, indent=2)
    elif k == "md":
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(R.to_markdown(m["doc"]))
    elif k == "pdf":
        R.write_pdf_text(p, m["doc"])
    elif k == "docx":
        R.write_docx(p, m["doc"])
    elif k == "xlsx":
        R.write_xlsx(p, m["sheets"])
    elif k == "image":
        if m.get("visual_ref") == "detect":
            im, drawn = render_detect(DETECT_VISUAL, rng)
        else:
            im, drawn = render_visual(m["visual"], rng)
        R.save_image(im, p, m.get("fmt", "jpg"), tmp)
    elif k == "zip":
        subs = []
        for sm in m["members"]:
            b, dl = member_bytes(sm, tmp, rng)
            subs.append((sm["name"], b))
            drawn += dl
        R.write_zip(p, subs)
    else:
        raise KeyError(k)
    with open(p, "rb") as fh:
        data = fh.read()
    os.remove(p)
    return data, drawn


DETECT_VISUAL = {"header": "澄川测试集 v3 · 样例 #0417 · 模型 v1.2",
                 "boxes": [("划痕 0.94", (112, 80, 342, 128)), ("凹坑 0.81", (410, 230, 470, 290))]}

_SUBTYPE = {"pdf": ("application", "pdf"), "docx": ("application", "vnd.openxmlformats-officedocument.wordprocessingml.document"),
            "xlsx": ("application", "vnd.openxmlformats-officedocument.spreadsheetml.sheet"), "csv": ("text", "csv"),
            "text": ("text", "plain"), "image": ("image", "jpeg"), "json": ("application", "json")}


def build_email(em: dict, tmp: str, rng: random.Random) -> tuple[EmailMessage, list[str]]:
    msg = EmailMessage(policy=policy.SMTP)
    msg["From"] = formataddr(em["from"])
    msg["To"] = ", ".join(formataddr(x) for x in em["to"])
    if em.get("cc"):
        msg["Cc"] = ", ".join(formataddr(x) for x in em["cc"])
    msg["Date"] = format_datetime(dt.datetime.fromisoformat(em["date"]))
    msg["Subject"] = em["subject"]
    msg["Message-ID"] = em.get("message_id") or f"<{uid(em['subject'])}@example.com>"
    if em.get("in_reply_to"):
        msg["In-Reply-To"] = em["in_reply_to"]
        msg["References"] = em["in_reply_to"]
    msg["X-Synthetic-Data"] = "yes"
    drawn: list[str] = []
    charset = em.get("charset", "utf-8")
    if em.get("html_only"):
        hdoc = em["html_doc"]
        img = ""
        if em.get("inline_image"):
            img = '<p><img src="cid:banner@example.com" alt="banner" width="480"></p>'
        html_s = R.to_html(hdoc).replace("<main>", "<main>" + img, 1)
        msg.set_content(html_s, subtype="html", cte="quoted-printable")
        if em.get("inline_image"):
            im = R.render_card(hdoc["title"], ["本周推荐"], w=640, title_size=32, line_size=24)
            drawn += [hdoc["title"], "本周推荐", R.MARK]
            buf = io.BytesIO()
            im.save(buf, "PNG")
            msg.add_related(buf.getvalue(), "image", "png", cid="<banner@example.com>")
    else:
        cte = em.get("cte", "8bit")
        if charset != "utf-8":
            msg.set_content(em["body"], charset=charset, cte="base64")
        else:
            msg.set_content(em["body"], cte=cte)
        if em.get("html_alt"):
            body_html = "".join(f"<p>{R.html.escape(par).replace(chr(10), '<br>')}</p>" for par in em["body"].split("\n\n"))
            msg.add_alternative(f"<html><body>{body_html}</body></html>", subtype="html")
    for a in em.get("attachments", []):
        data, dl = member_bytes(a, tmp, rng)
        drawn += dl
        mt, st = _SUBTYPE[a["kind"]]
        msg.add_attachment(data, maintype=mt, subtype=st, filename=a["filename"])
    return msg, drawn


# ============================================================================== render one spec

def render_spec(ftype: str, spec: dict, path: str, tmp: str, rng: random.Random) -> tuple[list[str], list[str], dict]:
    """Write the file. Returns (text-layer lines, picture-only lines, structure facts)."""
    text_lines: list[str] = []
    drawn: list[str] = []
    st: dict = {}
    if ftype == "txt":
        text = spec.get("text") or "\n".join(doc_lines(spec["doc"])) + "\n"
        R.write_txt(path, text, spec.get("encoding", "utf-8"), spec.get("newline", "\n"))
        text_lines = text.splitlines()
        st = {"encoding": spec.get("encoding", "utf-8"), "newline": "CRLF" if spec.get("newline") == "\r\n" else "LF"}
    elif ftype == "md":
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(R.to_markdown(spec["doc"]))
        text_lines = doc_lines(spec["doc"])
    elif ftype in ("rtf", "doc", "docx", "odt", "html", "pdf"):
        doc = spec["doc"]
        if ftype == "html":
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(R.to_html(doc))
            text_lines = [doc.get("site", "内部页面")] + doc_lines(doc)
        else:
            {"rtf": R.write_rtf, "doc": R.write_doc, "docx": R.write_docx, "odt": R.write_odt, "pdf": R.write_pdf_text}[ftype](path, doc)
            text_lines = doc_lines(doc)
    elif ftype == "pdf_scanned":
        st["pages"] = R.write_pdf_scanned(path, spec["doc"], rng)
        drawn = doc_lines(spec["doc"])
        st["text_layer"] = False
    elif ftype == "epub":
        R.write_epub(path, spec["book"])
        b = spec["book"]
        text_lines = [b["title"]]
        for ch in b["chapters"]:
            text_lines.append(ch["title"])
            text_lines += R.blocks_to_lines({"title": "", "lang": b["lang"], "blocks": ch["blocks"]})[1:]
        text_lines.append(R.MARK)
        st["chapters"] = len(b["chapters"])
    elif ftype == "webarchive":
        doc = dict(spec["doc"])
        logo = R.render_card(doc.get("site", "网站"), [], w=360, title_size=26, line_size=18)
        buf = io.BytesIO()
        logo.save(buf, "PNG")
        base_url = spec["url"].split("/", 3)
        img_url = f"{base_url[0]}//{base_url[2]}/static/logo.png"
        html_s = R.to_html(doc).replace("<main>", f'<main><img src="{img_url}" alt="logo" width="180">', 1)
        R.write_webarchive(path, spec["url"], html_s, [(img_url, "image/png", buf.getvalue())])
        text_lines = [doc.get("site", "内部页面")] + doc_lines(doc)
        drawn = [doc.get("site", "网站"), R.MARK]
        st = {"url": spec["url"], "subresources": 1}
    elif ftype == "csv":
        c = spec["csv"]
        R.write_csv(path, c["columns"], c["rows"], encoding=c.get("encoding", "utf-8"), delimiter=c.get("delimiter", ","),
                    comment=c.get("comment") or f"# {spec.get('title') or spec.get('filename', '')}（{R.MARK}）")
        with open(path, "rb") as fh:
            text_lines = X.decode_bytes(fh.read())[0].splitlines()
        st = {"encoding": c.get("encoding", "utf-8"), "delimiter": {",": "comma", ";": "semicolon", "\t": "tab"}[c.get("delimiter", ",")],
              "rows": len(c["rows"])}
    elif ftype in ("xlsx", "ods"):
        (R.write_xlsx if ftype == "xlsx" else R.write_ods)(path, spec["sheets"], {"title": spec.get("title", "")})
        text_lines = sheet_lines(spec["sheets"])
        st = {"sheets": [s["name"] for s in spec["sheets"]],
              "formulas": sum(1 for s in spec["sheets"] for r in s["rows"] for v in r if isinstance(v, dict)),
              "merged": sum(len(s.get("vmerge", [])) + len(s.get("group_header", [])) + (1 if s.get("title") else 0) for s in spec["sheets"])}
    elif ftype == "json":
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(spec["record"], fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        with open(path, encoding="utf-8") as fh:
            text_lines = fh.read().splitlines()
    elif ftype == "xml":
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(spec["xml"])
        text_lines = spec["xml"].splitlines()
    elif ftype in ("pptx", "odp"):
        (R.write_pptx if ftype == "pptx" else R.write_odp)(path, spec["slides"], spec.get("title", ""), tmp,
                                                         theme=rng.randint(0, 3))
        for i, s in enumerate(spec["slides"], 1):
            (drawn if s.get("image") else text_lines).extend(slide_lines(s))
            if s.get("notes"):
                text_lines.append(s["notes"])
        st = {"slides": len(spec["slides"]), "picture_only_slides": [i for i, s in enumerate(spec["slides"], 1) if s.get("image")],
              "notes_slides": [i for i, s in enumerate(spec["slides"], 1) if s.get("notes")]}
    elif ftype in VIDEO_TYPES:
        theme = rng.randint(0, 3)
        frames = [R.slide_picture(s, theme) for s in spec["slides"]]
        secs = spec.get("seconds") or [2.5] * len(frames)
        R.write_video(path, frames, secs, tmp, silent_audio=spec.get("silent_audio", False))
        for s in spec["slides"]:
            drawn += slide_lines(s)
        st = {"slides": len(frames), "seconds": secs, "duration_s": sum(secs), "audio": "silent AAC" if spec.get("silent_audio") else "none",
              "timeline": [{"start_s": sum(secs[:i]), "title": s["title"]} for i, s in enumerate(spec["slides"])]}
    elif ftype == "gif":
        theme = rng.randint(0, 3)
        frames = [R.slide_picture(f, (theme + i) % 4).resize((960, 540), Image.LANCZOS) for i, f in enumerate(spec["frames"])]
        R.save_gif(frames, path, [1500] * len(frames))
        for f in spec["frames"]:
            drawn += slide_lines(f)
        st = {"frames": len(frames), "frame_ms": 1500, "frame_titles": [f["title"] for f in spec["frames"]]}
    elif ftype in ("png", "jpg", "heic", "webp", "bmp"):
        im, drawn = render_visual(spec["visual"], rng)
        if ftype == "bmp":
            w = min(im.width, 720)
            im = im.resize((w, int(im.height * w / im.width)), Image.LANCZOS).convert("RGB").quantize(256)
        R.save_image(im, path, ftype, tmp)
        st = {"size": [im.width, im.height]}
    elif ftype == "tiff":
        pages = []
        for doc in spec["pages"]:
            pages += R.render_page_images(doc, scale=0.8)
            drawn += doc_lines(doc)
        pages = [R.scan_effect(p, rng, noise=12) for p in pages]
        if spec.get("bilevel"):
            pages = [p.point(lambda v: 255 if v > 150 else 0).convert("1") for p in pages]
            pages[0].save(path, "TIFF", compression="group4", save_all=True, append_images=pages[1:])
        else:
            pages[0].save(path, "TIFF", compression="jpeg", quality=60, save_all=True, append_images=pages[1:])
        st = {"pages": len(pages), "mode": "1-bit" if spec.get("bilevel") else "grayscale"}
    elif ftype == "svg":
        svg, text_lines = svg_render(spec["svg"])
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(svg)
    elif ftype == "ics":
        with open(path, "w", encoding="utf-8", newline="") as fh:
            fh.write(ics_text(spec["calendar"]))
        t, info = X.extract(path, "ics")
        text_lines, st = t.splitlines(), info
    elif ftype == "vcf":
        with open(path, "w", encoding="utf-8", newline="") as fh:
            fh.write(vcf_text(spec["contacts"], spec.get("vcf_version", "3.0")))
        t, info = X.extract(path, "vcf")
        text_lines, st = t.splitlines(), info
    elif ftype == "eml":
        msg, drawn = build_email(spec["email"], tmp, rng)
        with open(path, "wb") as fh:
            fh.write(msg.as_bytes())
        t, info = X.extract(path, "eml")
        text_lines, st = t.splitlines(), info
    elif ftype == "mbox":
        if os.path.exists(path):
            os.remove(path)
        mb = mailbox.mbox(path, create=True)
        for em in spec["messages"]:
            msg, dl = build_email(em, tmp, rng)
            drawn += dl
            mm = mailbox.mboxMessage(msg)
            mm.set_from(em["from"][1], dt.datetime.fromisoformat(em["date"]).astimezone(dt.timezone.utc).timetuple())
            mb.add(mm)
        mb.flush()
        mb.close()
        t, info = X.extract(path, "mbox")
        text_lines, st = t.splitlines(), info
    elif ftype == "zip":
        members = []
        for m in spec["members"]:
            b, dl = member_bytes(m, tmp, rng)
            members.append((m["name"], b))
            drawn += dl
        R.write_zip(path, members)
        t, info = X.extract(path, "zip")
        text_lines, st = t.splitlines(), info
    else:
        raise KeyError(ftype)
    return [x for x in text_lines if x.strip()], [x for x in drawn if x.strip()], st


# ============================================================================== truth

def answers_of(qa: dict) -> list:
    return [qa["a"]] + list(qa.get("accept", []))


def answerable(qa: dict, text: str) -> bool:
    if qa.get("derived"):
        return True
    if qa["match"] == "number":
        if X.has_number(text, qa["a"]):
            return True
        return any(X.norm(a) in X.norm(text) for a in qa.get("accept", []))
    return any(X.norm(a) in X.norm(text) for a in answers_of(qa))


def pick_key_lines(lines: list[str], qa: list[dict], numbers: list[dict], limit: int = 12) -> list[str]:
    keys = []
    for ln in lines:
        s = ln.strip()
        if not s or s in keys or len(s) > 300:
            continue
        hit = any(answerable(q, s) for q in qa if not q.get("derived")) or any(X.has_number(s, n["value"]) for n in numbers if n["value"] not in (0, 1, 2, 3))
        if hit:
            keys.append(s)
        if len(keys) >= limit:
            break
    return keys


def make_truth(fid, ftype, rel, spec, meta, text_lines, drawn, st, split, scen):
    text = "\n".join(text_lines + drawn)
    t = spec["truth"]
    errors = []
    for i, qa in enumerate(t["qa"]):
        if not answerable(qa, text):
            errors.append(f"{fid}: QA not answerable from content: {qa['q']} -> {qa['a']}")
    for n in t.get("numbers", []):
        if not X.has_number(text, n["value"]):
            errors.append(f"{fid}: number {n['value']} ({n.get('label')}) not in content")
    if text_lines and drawn:
        layer = "partial"
    elif text_lines:
        layer = "full"
    else:
        layer = "none"
    key_lines = pick_key_lines(text_lines + drawn, t["qa"], t.get("numbers", []))
    truth = {"file_id": fid, "path": rel, "type": ftype, "ext": EXT[ftype], "mime": MIME[ftype], "filename": meta["filename"],
             "lang": spec.get("lang") or meta.get("lang", "zh"), "split": split, "synthetic": True,
             "scenario": scen, "text_layer": layer, "text": text, "key_lines": key_lines,
             "picture_only_lines": [x for x in key_lines if x in drawn and x not in text_lines],
             "key_fields": t.get("key_fields", {}), "numbers": t.get("numbers", []),
             "qa": [dict({"id": f"q{i + 1}"}, **qa) for i, qa in enumerate(t["qa"])],
             "structure": st}
    if t.get("notes"):
        truth["notes"] = t["notes"]
    return truth, errors


def safe_name(s: str) -> str:
    return re.sub(r'[\\/:*?"<>|\n]+', "_", s).strip()[:60]


def display_filename(ftype, spec, rng):
    ext = EXT[ftype]
    v = spec.get("visual") or {}
    if ftype in ("jpg", "heic") and v.get("photo"):
        return f"IMG_{rng.randint(1000, 9999)}.{ext}"
    if ftype in ("png", "webp") and v.get("style") == "window":
        return f"截屏2026-10-{rng.randint(1, 9):02d} {rng.randint(9, 20)}.{rng.randint(10, 59)}.{rng.randint(10, 59)}.{ext}"
    return f"{safe_name(spec.get('title') or ftype)}.{ext}"


# ============================================================================== main

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=ROOT)
    ap.add_argument("--only", help="comma-separated types to (re)build (debugging)")
    args = ap.parse_args(argv)
    only = set(args.only.split(",")) if args.only else None
    tmp = tempfile.mkdtemp(prefix="filesbuild")
    manifest, errors = [], []
    per_type: dict[str, list] = {t: [] for t in TYPES}
    for spec in CM.FILES:  # scenario files first
        per_type[spec["type"]].append(("scenario", spec))
    for ftype, fams in CF.PLAN.items():
        for i, fam in enumerate(fams):
            per_type[ftype].append(("standalone", (fam, i)))
    event_split = {e["event_id"]: e["split"] for e in CM.EVENTS}
    # dev quota per type: alternate 2/1 so the total is ~30%
    dev_quota = {t: (2 if k % 2 == 0 else 1) for k, t in enumerate(TYPES)}
    for ftype in TYPES:
        d = os.path.join(args.out, "corpus", ftype)
        td = os.path.join(args.out, "truth", ftype)
        entries = per_type[ftype]
        # split: scenario files inherit their matter's split; standalone files fill the per-type dev quota first
        n_dev = sum(1 for kind, s in entries if kind == "scenario" and
                    (s.get("split") or (event_split[s["events"][0]] if s["events"] else "test")) == "dev")
        for k, (kind, payload) in enumerate(entries, 1):
            fid = f"{ftype}-{k:02d}"
            rel = f"corpus/{ftype}/{fid}.{EXT[ftype]}"
            rng = random.Random(f"{ftype}-{k}-v1")
            if kind == "scenario":
                spec = dict(payload)
                spec.setdefault("truth", {})
                split = spec.get("split") or (event_split[spec["events"][0]] if spec["events"] else "test")
                spec.setdefault("lang", (spec.get("doc") or spec.get("book") or {}).get("lang", "zh"))
                meta = {"filename": spec["filename"], "lang": spec["lang"]}
                scen = {"item_id": uid(spec["key"]), "ref": spec["key"], "events": spec["events"]}
            else:
                fam, i = payload
                spec = CS.make_standalone(ftype, fam, rng, i)
                if n_dev < dev_quota[ftype]:
                    split, n_dev = "dev", n_dev + 1
                else:
                    split = "test"
                meta = {"filename": display_filename(ftype, spec, rng), "lang": spec.get("lang", "zh")}
                scen = None
                spec["family"] = fam
            if only and ftype not in only:
                continue
            os.makedirs(d, exist_ok=True)
            os.makedirs(td, exist_ok=True)
            path = os.path.join(args.out, rel)
            R.OVERFLOWS.clear()
            text_lines, drawn, st = render_spec(ftype, spec, path, tmp, rng)
            if R.OVERFLOWS:
                errors += [f"{fid}: {o}" for o in R.OVERFLOWS]
            truth, errs = make_truth(fid, ftype, rel, spec, meta, text_lines, drawn, st, split, scen)
            errors += errs
            with open(path, "rb") as fh:
                data = fh.read()
            truth["bytes"] = len(data)
            truth["sha256"] = hashlib.sha256(data).hexdigest()
            if kind == "standalone":
                truth["family"] = spec["family"]
            with open(os.path.join(td, f"{fid}.json"), "w", encoding="utf-8") as fh:
                json.dump(truth, fh, ensure_ascii=False, indent=1)
                fh.write("\n")
            manifest.append({"file_id": fid, "type": ftype, "path": rel, "truth": f"truth/{ftype}/{fid}.json", "filename": meta["filename"],
                             "lang": truth["lang"], "split": split, "text_layer": truth["text_layer"], "bytes": len(data),
                             "scenario_item": scen["item_id"] if scen else None, "events": scen["events"] if scen else None,
                             "n_qa": len(truth["qa"])})
            if kind == "scenario":
                payload["_file_id"], payload["_rel"], payload["_split"] = fid, rel, split
            print(f"{fid:18s} {split:4s} {len(data):>9,d} B  {meta['filename']}", flush=True)
    shutil.rmtree(tmp, ignore_errors=True)
    if only:
        print("\n".join(errors) or "no errors")
        return 1 if errors else 0
    manifest.sort(key=lambda m: (TYPES.index(m["type"]), m["file_id"]))
    counts = {t: sum(1 for m in manifest if m["type"] == t) for t in TYPES}
    summary = {"synthetic": True, "note": "合成数据 · every file and value is invented; no model was called to build it.",
               "files": len(manifest), "types": len(TYPES), "per_type": counts,
               "split": {s: sum(1 for m in manifest if m["split"] == s) for s in ("dev", "test")},
               "qa": sum(m["n_qa"] for m in manifest), "bytes": sum(m["bytes"] for m in manifest), "entries": manifest}
    with open(os.path.join(args.out, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, ensure_ascii=False, indent=1)
        fh.write("\n")
    import make_scenario
    errors += make_scenario.write(args.out)
    if errors:
        print("\nERRORS:\n" + "\n".join(errors), file=sys.stderr)
        return 1
    print(f"\n{summary['files']} files, {summary['qa']} QA, split {summary['split']}, {summary['bytes'] / 1e6:.1f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
