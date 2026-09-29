#!/usr/bin/env python3
"""Semantic validator for image-read output (after the JSON schema).

validate(output, context) -> list of error strings (empty = valid)
  context["stage"] = "detect" | "extract"; context["type"] = the image type for "extract".

Extract-step rules (the schema already fixes each type's fields):
  - gist is not empty, and every number in it appears in what was read from the image (the other fields);
  - no stand-in values ("未知", "N/A", …): a value the image does not show is "";
  - receipts and labels carry their own transcription (`lines`): every key field, item name and amount must
    be found in it (a field the image does not support is not kept);
  - a receipt's normalized `date` uses only the numbers of its printed date;
  - chats: a message marked is_self is sent by "我"/"Me", and a chat has at least one message.

sanitize(image_type, output) -> (cleaned copy, number of values dropped): what the organizer keeps when the
output still fails after the retry: unsupported values are emptied, never guessed.

CLI: python validate.py output.json context.json
"""

from __future__ import annotations

import copy
import importlib.util
import json
import re
import sys
from pathlib import Path


def _load_reading():
    name = "skill_image_read_reading_helpers"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parent / "reading.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


R = _load_reading()
norm, numbers = R.norm, R.numbers

SELF_NAMES = {"我", "自己", "本人", "me"}
STAND_INS = {"未知", "不详", "不明", "暂无", "无法识别", "看不清", "n/a", "na", "unknown", "none", "null", "tbd", "?", "？"}
# enum-valued fields ("none" is a trend, not a stand-in)
ENUM_KEYS = {"type", "chart_type", "trend", "surface", "doc_kind", "label_kind", "kind", "level"}
_MONTHS = {m: str(i + 1) for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"])}
_MONTH_WORD = re.compile(r"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?(?![a-z])", re.I)
RECEIPT_TEXT_FIELDS = ("merchant", "buyer", "date_text", "time", "doc_no", "payment_method", "total_in_words")
RECEIPT_AMOUNTS = ("subtotal", "discount", "tax", "total")
ITEM_NUMBERS = ("qty", "unit_price", "amount")


def _s(x) -> str:
    return x.strip() if isinstance(x, str) else ""


def _content_numbers(out: dict) -> set:
    """Numbers of everything read off the image (not the gist). A printed month name counts as its number,
    so a Chinese gist of an English date ("Sep 10" -> "9月10日") is not a made-up number."""
    nums = set()
    for v in _strings(out):
        nums.update(numbers(v))
        nums.update(_MONTHS[m.group(1).lower()] for m in _MONTH_WORD.finditer(v))
    return nums


def _strings(o, skip=("gist",)):
    if isinstance(o, dict):
        for k, v in o.items():
            if k not in skip:
                yield from _strings(v, skip)
    elif isinstance(o, list):
        for v in o:
            yield from _strings(v, skip)
    elif isinstance(o, str):
        yield o


def _in_text(value: str, text_norm: str) -> bool:
    v = norm(value)
    return not v or v in text_norm


def _nums_in(value: str, text_nums: set) -> bool:
    return all(n in text_nums for n in numbers(value))


_YMD = re.compile(r"(\d{4})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})")
_YEAR = re.compile(r"(?<!\d)(?:19|20)\d{2}(?!\d)")


def _date_matches(date: str, date_text: str) -> bool:
    """The normalized date equals the printed one (year-month-day), or at least uses the printed numbers
    including a year (other formats: "Sep 14, 2026", "14/09/2026"). No year printed -> no normalized date."""
    d, t = _YMD.search(date), _YMD.search(date_text)
    if d and t:
        return tuple(map(int, d.groups())) == tuple(map(int, t.groups()))
    if not _YEAR.search(date_text):
        return False
    printed = set(numbers(date_text)) | {_MONTHS[m.group(1).lower()] for m in _MONTH_WORD.finditer(date_text)}
    return all(n in printed for n in numbers(date))


def _shape(values: list[float]) -> str:
    """The trend a series' values show, or "" when they do not show one clearly (no check then)."""
    if len(values) < 3:
        return ""
    steps = [b - a for a, b in zip(values, values[1:])]
    if any(d == 0 for d in steps):
        return ""
    signs = "".join("+" if d > 0 else "-" for d in steps)
    if set(signs) == {"+"}:
        return "up"
    if set(signs) == {"-"}:
        return "down"
    if re.fullmatch(r"\++-+", signs):
        return "rise_then_fall"
    if re.fullmatch(r"-+\++", signs):
        return "fall_then_rise"
    return ""


def _series_shape(series: dict) -> str:
    vals = []
    for p in series.get("points") or []:
        n = numbers(_s(p.get("value")) if isinstance(p, dict) else "")
        if len(n) != 1:
            return ""
        vals.append(float(n[0]))
    return _shape(vals)


def _lines_text(out: dict) -> str:
    return "\n".join(x for x in out.get("lines") or [] if isinstance(x, str))


def problems(image_type: str, out: dict) -> list[tuple[str, str]]:
    """(path, message) for each rule the extraction breaks."""
    found: list[tuple[str, str]] = []
    gist = _s(out.get("gist"))
    if not gist:
        found.append(("gist", "gist 为空：用一句话说这张图在讲什么事"))
    else:
        content_nums = _content_numbers(out)
        extra = [n for n in numbers(gist) if n not in content_nums]
        if extra:
            found.append(("gist", f"gist 里的数字 {'、'.join(extra)} 在读出的内容里没有；gist 只能用图里写着的数字"))
    for v in _strings(out, skip=("gist",) + tuple(ENUM_KEYS)):
        if v.strip().lower() in STAND_INS:
            found.append(("*", f"不要写占位词 \"{v.strip()}\"；图里没有的写空字符串 \"\""))
            break

    if image_type == "receipt_invoice":
        text = _lines_text(out)
        tn, tnums = norm(text), set(numbers(text))
        for key in RECEIPT_TEXT_FIELDS:
            if not _in_text(_s(out.get(key)), tn):
                found.append((key, f"{key}=\"{_s(out.get(key))}\" 在 lines 里找不到：只写图上印着的值（lines 漏了就补上那一行）"))
        for key in RECEIPT_AMOUNTS:
            if not _nums_in(_s(out.get(key)), tnums):
                found.append((key, f"{key}=\"{_s(out.get(key))}\" 在 lines 里找不到：金额照图上写，图上没有就写 \"\""))
        for i, it in enumerate(out.get("items") or []):
            if not isinstance(it, dict):
                continue
            if not _in_text(_s(it.get("name")), tn):
                found.append((f"items[{i}]", f"items[{i}].name=\"{_s(it.get('name'))}\" 在 lines 里找不到"))
            for key in ITEM_NUMBERS:
                if not _nums_in(_s(it.get(key)), tnums):
                    found.append((f"items[{i}]", f"items[{i}].{key}=\"{_s(it.get(key))}\" 在 lines 里找不到"))
        date = _s(out.get("date"))
        if date and not _date_matches(date, _s(out.get("date_text"))):
            found.append(("date", f"date=\"{date}\" 和图上的日期对不上：只在图上写全年月日时换算，否则写 \"\""))

    elif image_type == "form_label_sign":
        tn = norm(_lines_text(out))
        for i, f in enumerate(out.get("fields") or []):
            if not isinstance(f, dict):
                continue
            if not _in_text(_s(f.get("value")), tn):
                found.append((f"fields[{i}]", f"fields[{i}].value=\"{_s(f.get('value'))}\" 在 lines 里找不到：只写图上有的字段"))
            elif not _in_text(_s(f.get("label")), tn):
                found.append((f"fields[{i}]", f"fields[{i}].label=\"{_s(f.get('label'))}\" 不是图上印的字段名：没有字段名就写 \"\""))

    elif image_type == "chart_dashboard":
        for i, sr in enumerate(out.get("series") or []):
            if not isinstance(sr, dict) or sr.get("trend") in (None, "none", "flat"):
                continue
            shape = _series_shape(sr)
            if shape and shape != sr.get("trend"):
                found.append((f"series[{i}]", f"series[{i}].trend={sr.get('trend')} 和它的数据点不一致（按数据点是 {shape}）："
                                               "先核对每个数据标签，再按横轴顺序判断走势"))

    elif image_type == "chat_screenshot":
        msgs = [m for m in out.get("messages") or [] if isinstance(m, dict)]
        if not msgs:
            found.append(("messages", "聊天截图至少要有一条消息"))
        for i, m in enumerate(msgs):
            sender = _s(m.get("sender")).lower()
            if m.get("is_self") and sender not in SELF_NAMES:
                found.append((f"messages[{i}]", f"messages[{i}] is_self=true 时 sender 写\"我\"（英文界面写\"Me\"）"))
            elif not m.get("is_self") and sender in {"我", "me"}:
                found.append((f"messages[{i}]", f"messages[{i}] sender=\"我\" 时 is_self 应为 true"))
            if not _s(m.get("text")):
                found.append((f"messages[{i}]", f"messages[{i}].text 为空"))
    return found


def _blank_stand_ins(o) -> int:
    """Empty every stand-in string value (outside enum fields), at any depth."""
    n = 0
    items = o.items() if isinstance(o, dict) else enumerate(o) if isinstance(o, list) else []
    for k, v in list(items):
        if isinstance(v, str):
            if k not in ENUM_KEYS and v.strip().lower() in STAND_INS:
                o[k], n = "", n + 1
        elif k not in ENUM_KEYS:
            n += _blank_stand_ins(v)
    return n


def validate(output: dict, context: dict) -> list[str]:
    if (context or {}).get("stage", "extract") == "detect":
        return []
    image_type = (context or {}).get("type") or "other"
    return [msg for _, msg in problems(image_type, output)]


def sanitize(image_type: str, output: dict) -> tuple[dict, int]:
    """Empty every value the rules reject (never replace it with a guess). Returns (copy, values dropped)."""
    out = copy.deepcopy(output)
    dropped = 0
    for _ in range(3):  # dropping a value can change what the gist is checked against
        found = problems(image_type, out)
        if not found:
            break
        for path, _msg in found:
            if path == "gist":
                if out.get("gist"):
                    out["gist"], dropped = "", dropped + 1
            elif path == "*":
                dropped += _blank_stand_ins(out)
            elif path.startswith("items["):
                i = int(path[6:-1])
                if out["items"][i] is not None:
                    out["items"][i], dropped = None, dropped + 1
            elif path.startswith("fields["):
                i = int(path[7:-1])
                if out["fields"][i] is not None:
                    out["fields"][i], dropped = None, dropped + 1
            elif path.startswith("series["):
                sr = out["series"][int(path[7:-1])]
                shape = _series_shape(sr)
                if shape and sr.get("trend") != shape:
                    sr["trend"], dropped = shape, dropped + 1   # the printed values decide the trend
            elif path.startswith("messages["):
                i = int(path[9:-1])
                m = [x for x in out.get("messages") or [] if isinstance(x, dict)][i]
                if m.get("is_self"):
                    m["sender"] = "Me" if _s(m.get("sender")).isascii() and _s(m.get("sender")) else "我"
                elif _s(m.get("sender")).lower() in {"我", "me"}:
                    m["is_self"] = True
                dropped += 1
            elif path in out and isinstance(out[path], str) and out[path]:
                out[path], dropped = "", dropped + 1
        for key in ("items", "fields"):
            if isinstance(out.get(key), list):
                out[key] = [x for x in out[key] if x is not None]
        if image_type == "chat_screenshot":
            out["messages"] = [m for m in out.get("messages") or [] if isinstance(m, dict) and _s(m.get("text"))]
    return out, dropped


def main() -> int:
    output = json.load(open(sys.argv[1], encoding="utf-8"))
    context = json.load(open(sys.argv[2], encoding="utf-8")) if len(sys.argv) > 2 else {}
    errs = validate(output, context)
    for e in errs:
        print(e)
    return 1 if errs else 0


if __name__ == "__main__":
    raise SystemExit(main())
