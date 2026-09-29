#!/usr/bin/env python3
"""image-read: the two request steps and the reading the organizer keeps.

Step 1 (detect) asks for the image type with references/schema.json; step 2 (extract) asks for that
type's content with references/types.json[type]. Both steps send the same system prompt and the same
image first, so a prefix-caching server reuses the image's prefill for step 2.

compose(type, output) turns a type's extraction into the reading the organizer stores and publishes:
  type      the image type
  gist      the model's one-line gist (its own words; never source text)
  text      the transcription: one line per chat message, or the image's text lines (source text)
  lines     the same, as a list
  fields    key fields [{key, label, value}] (non-empty values only)
  numbers   key numbers [{label, value}] (as printed; each one appears in `text`)
  messages  chat messages [{sender, is_self, time, text}] (chat_screenshot only; [] otherwise)

Standard library only.
"""

from __future__ import annotations

import json
import re
import unicodedata
from pathlib import Path

_REFS = Path(__file__).resolve().parents[1] / "references"
DETECT_SCHEMA: dict = json.loads((_REFS / "schema.json").read_text(encoding="utf-8"))
TYPE_SCHEMAS: dict[str, dict] = json.loads((_REFS / "types.json").read_text(encoding="utf-8"))
TYPES: list[str] = DETECT_SCHEMA["properties"]["type"]["enum"]
assert set(TYPES) == set(TYPE_SCHEMAS), "detect enum and per-type schemas must list the same types"

TYPE_NAMES = {
    "chat_screenshot": "聊天截图", "chart_dashboard": "图表/看板", "slide": "幻灯片",
    "whiteboard_handwriting": "手写/白板", "receipt_invoice": "小票/发票", "scanned_document": "扫描件",
    "form_label_sign": "标签/面单/标牌", "other": "其他",
}
# The old screenshot-read `kind` for a client that still reads it.
LEGACY_KIND = {"chat_screenshot": "chat", "scanned_document": "document"}


def detect_task() -> str:
    return "第一步：判断这张图片属于哪一类，只输出 type。 (Step 1: name the image type.)"


def extract_task(image_type: str) -> str:
    return (f"第二步：这张图片的类型是 {image_type}（{TYPE_NAMES.get(image_type, image_type)}）。"
            f"按这个类型读取图片内容，最后写 gist。 (Step 2: extract this type's content, then the gist.)")


def schema_for(image_type: str) -> dict:
    return TYPE_SCHEMAS[image_type]


# ---------------------------------------------------------------- text helpers
_PUNCT = str.maketrans({
    "。": ".", "、": ",", "“": '"', "”": '"', "‘": "'", "’": "'", "「": '"', "」": '"', "《": "<", "》": ">",
    "【": "[", "】": "]", "•": "·", "・": "·", "●": "·", "‐": "-", "‑": "-", "–": "-", "—": "-", "―": "-",
    "−": "-", "～": "~", "〜": "~", "￥": "¥",
})
_WS = re.compile(r"\s+")
_MEMBERS = re.compile(r"\s*[(（]\d+[)）]\s*$")  # a group title's drawn member count "(8)"
_NUM = re.compile(r"\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?")


def norm(s) -> str:
    """NFKC, look-alike punctuation folded, whitespace removed (for "does this value appear" checks)."""
    return _WS.sub("", unicodedata.normalize("NFKC", str(s or "")).translate(_PUNCT))


def numbers(s) -> list[str]:
    """Canonical forms of every number in s: thousands separators removed, trailing zeros dropped."""
    out = []
    for tok in _NUM.findall(unicodedata.normalize("NFKC", str(s or ""))):
        tok = tok.replace(",", "")
        if "." in tok:
            tok = tok.rstrip("0").rstrip(".")
        tok = tok.lstrip("0") or "0"
        if tok.startswith("."):
            tok = "0" + tok
        out.append(tok)
    return out


def _s(x) -> str:
    return x.strip() if isinstance(x, str) else ("" if x is None else str(x))


def _list(x) -> list:
    return x if isinstance(x, list) else []


# ---------------------------------------------------------------- per type: lines, fields, numbers
def chat_lines(out: dict) -> list[str]:
    """One line per message. A time stamp is written per line only when the messages carry different
    times; one label shared by every message (the chat's single time header) says nothing per line."""
    msgs = [m for m in _list(out.get("messages")) if isinstance(m, dict)]
    times = {_s(m.get("time")) for m in msgs} - {""}
    lines = []
    for m in msgs:
        stamp = f"[{_s(m.get('time'))}] " if len(times) > 1 and _s(m.get("time")) else ""
        lines.append(f"{stamp}{_s(m.get('sender'))}：{_s(m.get('text'))}")
    return lines


def _chart_lines(out: dict) -> list[str]:
    lines = [x for x in (_s(out.get("title")),) if x]
    axes = "；".join(f"{k}：{_s(out.get(f))}" for k, f in (("横轴", "x_label"), ("纵轴", "y_label"), ("单位", "unit"))
                    if _s(out.get(f)))
    if axes:
        lines.append(axes)
    for k in _list(out.get("kpis")):
        if isinstance(k, dict) and (_s(k.get("label")) or _s(k.get("value"))):
            lines.append(" ".join(x for x in (_s(k.get("label")), _s(k.get("value")), _s(k.get("delta"))) if x))
    series = [sr for sr in _list(out.get("series")) if isinstance(sr, dict)]
    for sr in series:
        pts = [f"{_s(p.get('category'))} {_s(p.get('value'))}".strip()
               for p in _list(sr.get("points")) if isinstance(p, dict) and (_s(p.get("category")) or _s(p.get("value")))]
        if pts:
            name = _s(sr.get("name"))
            lines.append((f"{name}：" if name else "") + "，".join(pts))
    return lines


def _slide_lines(out: dict) -> list[str]:
    lines = [x for x in (_s(out.get("title")), _s(out.get("subtitle"))) if x]
    for b in _list(out.get("bullets")):
        if isinstance(b, dict) and _s(b.get("text")):
            lines.append("  " * int(b.get("level") or 0) + "· " + _s(b.get("text")))
    for k in _list(out.get("kpis")):
        if isinstance(k, dict) and (_s(k.get("label")) or _s(k.get("value"))):
            lines.append(f"{_s(k.get('label'))} {_s(k.get('value'))}".strip())
    lines += [x for x in (_s(out.get("footer")), _s(out.get("page"))) if x]
    return lines


def _board_lines(out: dict) -> list[str]:
    lines = []
    for ln in _list(out.get("lines")):
        if not isinstance(ln, dict) or not _s(ln.get("text")):
            continue
        mark = "（已划掉）" if ln.get("struck") else ("[✓] " if ln.get("checked") else "")
        lines.append(f"{mark}{_s(ln.get('text'))}")
    return lines


def _scan_lines(out: dict) -> list[str]:
    lines = [x for x in (_s(out.get("title")),) if x]
    for f in _list(out.get("fields")):
        if isinstance(f, dict) and _s(f.get("value")):
            lines.append(f"{_s(f.get('key'))}：{_s(f.get('value'))}" if _s(f.get("key")) else _s(f.get("value")))
    for b in _list(out.get("blocks")):
        if not isinstance(b, dict):
            continue
        if b.get("type") == "table":
            for row in [_list(b.get("header"))] + _list(b.get("rows")):
                cells = [_s(c) for c in _list(row)]
                if any(cells):
                    lines.append(" | ".join(cells))
        elif _s(b.get("text")):
            lines.append(_s(b.get("text")))
    return lines


def _plain_lines(out: dict) -> list[str]:
    return [_s(x) for x in _list(out.get("lines")) if _s(x)]


LINES = {
    "chat_screenshot": chat_lines, "chart_dashboard": _chart_lines, "slide": _slide_lines,
    "whiteboard_handwriting": _board_lines, "receipt_invoice": _plain_lines, "scanned_document": _scan_lines,
    "form_label_sign": _plain_lines, "other": _plain_lines,
}

RECEIPT_FIELDS = (("merchant", "商家"), ("buyer", "购买方"), ("date_text", "日期"), ("time", "时间"),
                  ("doc_no", "单号"), ("subtotal", "小计"), ("discount", "优惠"), ("tax", "税"), ("total", "合计"),
                  ("payment_method", "支付方式"), ("total_in_words", "大写金额"))
RECEIPT_AMOUNTS = ("subtotal", "discount", "tax", "total")


def fields_of(image_type: str, out: dict) -> list[dict]:
    """Key fields with a non-empty value. Every value is text the model read off the image (the receipt's
    normalized `date` is kept as `date_iso` next to the printed `date_text`)."""
    f: list[dict] = []

    def add(key: str, label: str, value) -> None:
        if _s(value):
            f.append({"key": key, "label": label, "value": _s(value)})

    if image_type == "chat_screenshot":
        add("chat_title", "会话", _MEMBERS.sub("", _s(out.get("chat_title"))))
    elif image_type == "chart_dashboard":
        add("title", "标题", out.get("title"))
        add("unit", "单位", out.get("unit"))
    elif image_type == "slide":
        for key, label in (("title", "标题"), ("subtitle", "副标题"), ("footer", "页脚"), ("page", "页码")):
            add(key, label, out.get(key))
    elif image_type == "whiteboard_handwriting":
        for ln in _list(out.get("lines")):
            if isinstance(ln, dict) and ln.get("is_title"):
                add("title", "标题", ln.get("text"))
                break
    elif image_type == "receipt_invoice":
        for key, label in RECEIPT_FIELDS:
            add(key, label, out.get(key))
        add("date_iso", "日期（换算）", out.get("date"))
        add("currency", "币种", out.get("currency"))
    elif image_type == "scanned_document":
        add("title", "标题", out.get("title"))
        for x in _list(out.get("fields")):
            if isinstance(x, dict):
                add(_s(x.get("key")) or "field", _s(x.get("key")), x.get("value"))
    elif image_type == "form_label_sign":
        for x in _list(out.get("fields")):
            if isinstance(x, dict):
                add(_s(x.get("key")) or "field", _s(x.get("label")), x.get("value"))
    return f


def numbers_of(image_type: str, out: dict) -> list[dict]:
    """Key numbers as printed, with what they are: amounts, chart points and KPIs, slide KPIs, numeric fields."""
    nums: list[dict] = []

    def add(label: str, value) -> None:
        if numbers(value):
            nums.append({"label": label, "value": _s(value)})

    if image_type == "chart_dashboard":
        for k in _list(out.get("kpis")):
            if isinstance(k, dict):
                add(_s(k.get("label")), k.get("value"))
        series = [sr for sr in _list(out.get("series")) if isinstance(sr, dict)]
        for sr in series:
            for p in _list(sr.get("points")):
                if isinstance(p, dict):
                    label = _s(p.get("category"))
                    if len(series) > 1 and _s(sr.get("name")):
                        label = f"{_s(sr.get('name'))}·{label}"
                    add(label, p.get("value"))
    elif image_type == "slide":
        for k in _list(out.get("kpis")):
            if isinstance(k, dict):
                add(_s(k.get("label")), k.get("value"))
    elif image_type == "receipt_invoice":
        for key, label in RECEIPT_FIELDS:
            if key in RECEIPT_AMOUNTS:
                add(label, out.get(key))
        for it in _list(out.get("items")):
            if isinstance(it, dict):
                add(_s(it.get("name")), it.get("amount"))
    elif image_type in ("scanned_document", "form_label_sign"):
        for x in fields_of(image_type, out):
            if x["key"] != "title" and not x["key"].endswith(("phone", "_no", "barcode", "sku", "lot")):
                add(x["label"] or x["key"], x["value"])
    return nums


def compose(image_type: str, out: dict) -> dict:
    lines = LINES.get(image_type, _plain_lines)(out)
    messages = []
    if image_type == "chat_screenshot":
        messages = [{"sender": _s(m.get("sender")), "is_self": bool(m.get("is_self")), "time": _s(m.get("time")),
                     "text": _s(m.get("text"))}
                    for m in _list(out.get("messages")) if isinstance(m, dict) and _s(m.get("text"))]
    return {"type": image_type, "gist": _s(out.get("gist")), "text": "\n".join(lines), "lines": lines,
            "fields": fields_of(image_type, out), "numbers": numbers_of(image_type, out), "messages": messages}
