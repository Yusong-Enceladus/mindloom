"""E-mail (.eml, .mbox, and .msg via ole.py), web archives saved as MIME (.mht), calendars (.ics) and
contacts (.vcf). Standard-library parsers only; nothing referenced by a message is fetched.
"""

from __future__ import annotations

import email
import quopri
import re
from email import policy
from email.utils import getaddresses
from typing import Callable

from .core import (MAX_MAILS, PART_TEXT_CAP, Budget, Parsed, clean_text, clip, decode_text,
                   first_line, html_to_text)

HEADER_LABELS = (("subject", "主题"), ("from", "发件人"), ("to", "收件人"), ("cc", "抄送"), ("date", "时间"))


def _part_text(part) -> str:
    try:
        content = part.get_content()
    except Exception:  # noqa: BLE001 - unknown charset or broken transfer encoding
        payload = part.get_payload(decode=True) or b""
        content = decode_text(payload, part.get_content_charset() or "")
    if isinstance(content, bytes):
        content = decode_text(content, part.get_content_charset() or "")
    if part.get_content_type() == "text/html":
        _, content = html_to_text(content)
    return clean_text(content)


def render_mail(headers: dict, body: str, attachments: list[tuple[str, bytes]], budget: Budget,
                sub: Callable[[bytes, str], Parsed], read_attachments: bool = True) -> Parsed:
    lines = [f"{label}：{headers[key]}" for key, label in HEADER_LABELS if headers.get(key)]
    fields = [{"key": key, "label": label, "value": headers[key]} for key, label in HEADER_LABELS if headers.get(key)]
    body, cut = clip(clean_text(body or ""), 40_000)
    blocks = ["\n".join(lines), body + ("\n（正文较长，已截断）" if cut else "")]
    listed = []
    for name, data in attachments:
        if not read_attachments or not data:
            listed.append({"filename": name, "type": "data", "summary": "未读取"})
            continue
        inner = sub(data, name)
        summary = _attachment_summary(inner)
        listed.append({"filename": name, "type": inner.type, "summary": summary})
        if inner.text:
            t, cut = clip(inner.text, PART_TEXT_CAP)
            blocks.append(f"## 附件：{name}\n{t}" + ("\n（附件较长，已截断）" if cut else ""))
        elif inner.error:
            blocks.append(f"## 附件：{name}\n（{summary}）")
    return Parsed("email", clean_text("\n\n".join(b for b in blocks if b)), headers.get("subject", ""),
                  {"attachments": len(attachments)}, listed, fields)


ERROR_WORDS = {"encrypted": "加密，无法读取", "unsupported": "格式不支持，未读取", "too_large": "过大，未读取",
               "corrupt": "文件损坏，无法读取"}


def _attachment_summary(p: Parsed) -> str:
    if p.error:
        return ERROR_WORDS.get(p.error, p.error)
    if p.type == "image":
        return "图片"
    return (p.title or first_line(p.text) or "")[:60]


def _message_parts(msg) -> tuple[str, list[tuple[str, bytes]]]:
    body_part = None
    try:
        body_part = msg.get_body(preferencelist=("plain", "html"))
    except Exception:  # noqa: BLE001
        body_part = None
    body = _part_text(body_part) if body_part is not None else ""
    attachments: list[tuple[str, bytes]] = []
    n = 0
    for part in msg.walk():
        if part.is_multipart() or part is body_part:
            continue
        ctype = part.get_content_type()
        disp = (part.get_content_disposition() or "").lower()
        name = part.get_filename()
        if ctype in ("text/plain", "text/html") and not name and disp != "attachment":
            continue  # the other alternative of the body
        if ctype == "message/rfc822":
            inner = part.get_payload()
            data = inner[0].as_bytes() if isinstance(inner, list) and inner else b""
            name = name or "附带邮件.eml"
        else:
            data = part.get_payload(decode=True) or b""
        n += 1
        if not name:
            ext = ctype.split("/")[-1].split("+")[0] if "/" in ctype else "bin"
            name = f"inline-{n}.{ext}"
        attachments.append((name, data))
    return body, attachments


def _headers(msg) -> dict:
    out = {}
    for key in ("subject", "from", "to", "cc", "date"):
        try:
            value = msg.get(key)
        except Exception:  # noqa: BLE001 - a malformed header
            value = None
        if value:
            out[key] = re.sub(r"\s+", " ", str(value)).strip()[:500]
    return out


def parse_eml(data: bytes, budget: Budget, sub: Callable[[bytes, str], Parsed]) -> Parsed:
    msg = email.message_from_bytes(data, policy=policy.default)
    body, attachments = _message_parts(msg)
    return render_mail(_headers(msg), body, attachments, budget, sub)


def parse_mht(data: bytes) -> Parsed:
    msg = email.message_from_bytes(data, policy=policy.default)
    html_part = None
    for part in msg.walk():
        if part.get_content_type() == "text/html":
            html_part = part
            break
    if html_part is None:
        body, _ = _message_parts(msg)
        return Parsed("web", body, str(msg.get("subject") or ""), {})
    try:
        markup = html_part.get_content()
    except Exception:  # noqa: BLE001
        markup = decode_text(html_part.get_payload(decode=True) or b"")
    title, text = html_to_text(markup if isinstance(markup, str) else decode_text(markup))
    url = str(msg.get("Snapshot-Content-Location") or html_part.get("Content-Location") or "")
    head = f"网址：{url}\n" if url.startswith(("http://", "https://")) else ""
    return Parsed("web", clean_text(head + text), title or str(msg.get("subject") or ""), {})


def parse_mbox(data: bytes, budget: Budget) -> Parsed:
    text = data.replace(b"\r\n", b"\n")
    starts = [0] if text.startswith(b"From ") else []
    starts += [m.start() + 1 for m in re.finditer(rb"\n(?=From [^\n]*\n)", text)]
    starts = sorted(set(starts))
    total = len(starts)
    blocks, listed = [], []
    for i, s in enumerate(starts[:MAX_MAILS]):
        e = starts[i + 1] if i + 1 < len(starts) else len(text)
        chunk = text[s:e]
        chunk = chunk.split(b"\n", 1)[1] if chunk.startswith(b"From ") else chunk
        chunk = re.sub(rb"(?m)^>(>*From )", rb"\1", chunk)
        msg = email.message_from_bytes(chunk, policy=policy.default)
        headers = _headers(msg)
        body, attachments = _message_parts(msg)
        body, _ = clip(body, 3000)
        head = "\n".join(f"{label}：{headers[k]}" for k, label in HEADER_LABELS if headers.get(k))
        names = "、".join(n for n, _ in attachments)
        blocks.append(f"## 邮件 {i + 1}\n{head}\n\n{body}" + (f"\n附件：{names}" if names else ""))
        listed += [{"filename": n, "type": "data", "summary": f"邮件 {i + 1} 的附件，未读取"} for n, _ in attachments]
    if total > MAX_MAILS:
        budget.note(f"邮箱共 {total} 封邮件，只读了前 {MAX_MAILS} 封")
    return Parsed("email", clean_text("\n\n".join(blocks)), "", {"messages": total, "attachments": len(listed)},
                  listed[:100])


# ---- iCalendar / vCard ---------------------------------------------------------------------------------


def _unfold(text: str) -> list[str]:
    lines: list[str] = []
    for raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if raw[:1] in (" ", "\t") and lines:
            lines[-1] += raw[1:]
        elif raw.strip():
            lines.append(raw)
    return lines


def _prop(line: str) -> tuple[str, dict, str]:
    # NAME;PARAM=v;PARAM2="x:y":value  (a colon inside a quoted parameter is not the separator)
    m = re.match(r'^((?:[^:";]|"[^"]*")*?)((?:;(?:[^:";]|"[^"]*")*)*):(.*)$', line)
    if not m:
        return line.upper(), {}, ""
    name = m.group(1).upper()
    params = {}
    for p in re.findall(r';((?:[^;"]|"[^"]*")*)', m.group(2)):
        k, _, v = p.partition("=")
        params[k.upper()] = v.strip('"')
    return name.split(".")[-1], params, m.group(3)


def _ical_unescape(v: str) -> str:
    return v.replace("\\n", "\n").replace("\\N", "\n").replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\")


def _ical_time(v: str, params: dict) -> str:
    m = re.match(r"^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$", v.strip())
    if not m:
        return v
    y, mo, d, hh, mm, _, z = m.groups()
    out = f"{y}-{mo}-{d}"
    if hh:
        out += f" {hh}:{mm}"
        if z:
            out += " UTC"
        elif params.get("TZID"):
            out += f" ({params['TZID']})"
    return out


def parse_ics(data: bytes) -> Parsed:
    lines = _unfold(decode_text(data))
    events: list[dict] = []
    cur = None
    kind = ""
    for line in lines:
        name, params, value = _prop(line)
        if name == "BEGIN" and value.upper() in ("VEVENT", "VTODO"):
            cur, kind = {"_kind": value.upper(), "attendees": []}, value.upper()
        elif name == "END" and value.upper() == kind and cur is not None:
            events.append(cur)
            cur = None
        elif cur is not None:
            if name in ("SUMMARY", "LOCATION", "DESCRIPTION", "STATUS", "URL"):
                cur[name] = _ical_unescape(value).strip()
            elif name in ("DTSTART", "DTEND", "DUE"):
                cur[name] = _ical_time(value, params)
            elif name == "ORGANIZER":
                cur[name] = params.get("CN") or re.sub(r"(?i)^mailto:", "", value)
            elif name == "ATTENDEE":
                cur["attendees"].append(params.get("CN") or re.sub(r"(?i)^mailto:", "", value))
            elif name == "RRULE":
                cur[name] = value
    blocks = []
    labels = (("SUMMARY", "日程"), ("DTSTART", "开始"), ("DTEND", "结束"), ("DUE", "截止"), ("LOCATION", "地点"),
              ("ORGANIZER", "组织者"), ("RRULE", "重复"), ("STATUS", "状态"), ("URL", "链接"))
    for ev in events[:200]:
        rows = [f"{lab}：{ev[k]}" for k, lab in labels if ev.get(k)]
        if ev["attendees"]:
            rows.append("参与者：" + "、".join(ev["attendees"][:50]))
        if ev.get("DESCRIPTION"):
            desc, _ = clip(ev["DESCRIPTION"], 3000)
            rows.append(f"说明：{desc}")
        blocks.append("\n".join(rows))
    fields = []
    if len(events) == 1:
        keymap = {"SUMMARY": ("summary", "日程"), "DTSTART": ("start", "开始"), "DTEND": ("end", "结束"),
                  "DUE": ("due", "截止"), "LOCATION": ("location", "地点"), "ORGANIZER": ("organizer", "组织者")}
        fields = [{"key": keymap[k][0], "label": keymap[k][1], "value": events[0][k]} for k in keymap
                  if events[0].get(k)]
    title = events[0].get("SUMMARY", "") if events else ""
    return Parsed("calendar", clean_text("\n\n".join(blocks)), title, {"events": len(events)}, fields=fields)


def _vcard_value(value: str, params: dict) -> str:
    if params.get("ENCODING", "").upper() in ("QUOTED-PRINTABLE", "Q"):
        raw = quopri.decodestring(value.encode("latin-1", "replace"))
        value = decode_text(raw, params.get("CHARSET", ""))
    return _ical_unescape(value).strip()


def parse_vcf(data: bytes) -> Parsed:
    lines = _unfold(decode_text(data))
    # vCard 2.1 quoted-printable soft line breaks end in "=": join them first.
    joined: list[str] = []
    for line in lines:
        if joined and joined[-1].endswith("=") and "QUOTED-PRINTABLE" in joined[-1].upper():
            joined[-1] = joined[-1][:-1] + line
        else:
            joined.append(line)
    cards: list[dict] = []
    cur = None
    for line in joined:
        name, params, value = _prop(line)
        if name == "BEGIN" and value.upper() == "VCARD":
            cur = {}
        elif name == "END" and value.upper() == "VCARD" and cur is not None:
            cards.append(cur)
            cur = None
        elif cur is not None and name in ("FN", "N", "ORG", "TITLE", "TEL", "EMAIL", "ADR", "NOTE", "BDAY", "URL",
                                          "NICKNAME"):
            v = _vcard_value(value, params)
            if name == "N" and v:
                parts = [p for p in v.split(";") if p]
                v = "".join(parts[:2][::-1]) if all(re.match(r"[一-鿿]", p) for p in parts[:2]) else " ".join(parts[:2][::-1])
            elif name in ("ADR", "ORG"):
                v = " ".join(p for p in v.split(";") if p)
            if v:
                cur.setdefault(name, []).append(v)
    labels = (("FN", "姓名"), ("N", "姓名"), ("NICKNAME", "昵称"), ("ORG", "单位"), ("TITLE", "职务"), ("TEL", "电话"),
              ("EMAIL", "邮箱"), ("ADR", "地址"), ("BDAY", "生日"), ("URL", "网址"), ("NOTE", "备注"))
    blocks = []
    for card in cards[:500]:
        rows = []
        for k, lab in labels:
            if k == "N" and card.get("FN"):
                continue
            for v in card.get(k, [])[:5]:
                rows.append(f"{lab}：{v}")
        blocks.append("\n".join(rows))
    fields = []
    if len(cards) == 1:
        keymap = (("FN", "name", "姓名"), ("N", "name", "姓名"), ("ORG", "org", "单位"), ("TITLE", "title", "职务"),
                  ("TEL", "phone", "电话"), ("EMAIL", "email", "邮箱"), ("ADR", "address", "地址"), ("BDAY", "birthday", "生日"))
        seen = set()
        for k, key, lab in keymap:
            if card_vals := cards[0].get(k):
                if key in seen:
                    continue
                seen.add(key)
                fields.append({"key": key, "label": lab, "value": card_vals[0]})
    title = (cards[0].get("FN") or cards[0].get("N") or [""])[0] if cards else ""
    return Parsed("contact", clean_text("\n\n".join(blocks)), title, {"contacts": len(cards)}, fields=fields)


def mail_addresses(value: str) -> list[str]:
    return [n or a for n, a in getaddresses([value]) if n or a]
