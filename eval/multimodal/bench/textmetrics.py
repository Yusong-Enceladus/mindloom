"""Normalization, edit distance, number and date parsing for the mm-v1 VLM benchmark. Standard library only."""

from __future__ import annotations

import re
import unicodedata
from decimal import Decimal, InvalidOperation
from typing import Optional

# NFKC already folds full-width ASCII (，：（）％ etc.). These are the remaining look-alikes the README
# asks to treat as equal ("全半角标点视为相同"), plus bullet/middle-dot and dash variants.
_PUNCT = str.maketrans({
    "。": ".", "、": ",", "“": '"', "”": '"', "„": '"', "‘": "'", "’": "'", "「": '"', "」": '"',
    "『": '"', "』": '"', "《": "<", "》": ">", "【": "[", "】": "]", "〔": "[", "〕": "]",
    "•": "·", "・": "·", "‧": "·", "∙": "·", "●": "·",
    "‐": "-", "‑": "-", "‒": "-", "–": "-", "—": "-", "―": "-", "−": "-", "〜": "~", "～": "~",
    "′": "'", "″": '"',
})
_WS = re.compile(r"\s+")
MARK = "合成数据"


def norm(s) -> str:
    """NFKC, drop the synthetic-data mark, fold look-alike punctuation, remove all whitespace."""
    if s is None:
        return ""
    s = unicodedata.normalize("NFKC", str(s)).replace(MARK, "")
    return _WS.sub("", s.translate(_PUNCT))


def _bitparallel(text: str, pattern: str, substring: bool) -> int:
    """Myers/Hyyro bit-vector edit distance. substring=True: best match of pattern anywhere in text."""
    m = len(pattern)
    if m == 0:
        return 0 if substring else len(text)
    peq: dict[str, int] = {}
    for i, c in enumerate(pattern):
        peq[c] = peq.get(c, 0) | (1 << i)
    full = (1 << m) - 1
    top = 1 << (m - 1)
    pv, mv, score = full, 0, m
    best = m
    for c in text:
        eq = peq.get(c, 0)
        xv = eq | mv
        xh = ((((eq & pv) + pv) & full) ^ pv) | eq
        ph = (mv | ~(xh | pv)) & full
        mh = pv & xh
        if ph & top:
            score += 1
        elif mh & top:
            score -= 1
        ph = ((ph << 1) | (0 if substring else 1)) & full
        mh = (mh << 1) & full
        pv = (mh | ~(xv | ph)) & full
        mv = ph & xv
        if substring and score < best:
            best = score
    return best if substring else score


def edit_distance(a: str, b: str) -> int:
    # strip common prefix/suffix first (outputs are often near-identical)
    i = 0
    while i < len(a) and i < len(b) and a[i] == b[i]:
        i += 1
    a, b = a[i:], b[i:]
    j = 0
    while j < len(a) and j < len(b) and a[-1 - j] == b[-1 - j]:
        j += 1
    if j:
        a, b = a[:-j], b[:-j]
    if not a:
        return len(b)
    if not b:
        return len(a)
    return _bitparallel(a, b, substring=False)


def substring_distance(pattern: str, text: str) -> int:
    """Minimum edits to turn pattern into some substring of text."""
    if not pattern:
        return 0
    if pattern in text:
        return 0
    return _bitparallel(text, pattern, substring=True)


def similarity(a: str, b: str) -> float:
    a, b = norm(a), norm(b)
    if not a and not b:
        return 1.0
    return 1.0 - edit_distance(a, b) / max(len(a), len(b))


def cer(pred: str, ref: str) -> tuple[int, int]:
    """(edits capped at len(ref), len(ref)) on normalized strings."""
    p, r = norm(pred), norm(ref)
    if not r:
        return (0 if not p else 1), max(1, len(r))
    return min(edit_distance(p, r), len(r)), len(r)


# ---------------------------------------------------------------- numbers
_NUM = re.compile(r"\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?")


def numbers(s) -> list[str]:
    """Canonical decimal strings of every number in s (thousands separators removed, sign ignored)."""
    out = []
    for tok in _NUM.findall(unicodedata.normalize("NFKC", str(s or ""))):
        try:
            d = Decimal(tok.replace(",", "")).normalize()
        except InvalidOperation:
            continue
        out.append(format(d, "f"))
    return out


def eq_num(a, b) -> bool:
    na, nb = numbers(a), numbers(b)
    return bool(nb) and na == nb


def zeroish(s) -> bool:
    n = numbers(s)
    return not norm(s) or (len(n) == 1 and Decimal(n[0]) == 0)


# ---------------------------------------------------------------- dates
_MONTHS = {m: i + 1 for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"])}
_D_YMD = re.compile(r"(\d{4})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})")
_D_MDY = re.compile(r"(\d{1,2})\s*/\s*(\d{1,2})\s*/\s*(\d{4})")
_D_MD_ZH = re.compile(r"(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]")
_D_MON = re.compile(r"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?!\d)(?:st|nd|rd|th)?,?\s*(\d{4})?", re.I)
_D_DMON = re.compile(r"\b(\d{1,2})\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?,?\s*(\d{4})?", re.I)


def parse_date(s) -> Optional[tuple]:
    s = unicodedata.normalize("NFKC", str(s or ""))
    m = _D_YMD.search(s)
    if m:
        return int(m[1]), int(m[2]), int(m[3])
    m = _D_MDY.search(s)
    if m:
        return int(m[3]), int(m[1]), int(m[2])
    m = _D_MON.search(s)
    if m:
        return (int(m[3]) if m[3] else None), _MONTHS[m[1].lower()[:3]], int(m[2])
    m = _D_DMON.search(s)
    if m:
        return (int(m[3]) if m[3] else None), _MONTHS[m[2].lower()[:3]], int(m[1])
    m = _D_MD_ZH.search(s)
    if m:
        return None, int(m[1]), int(m[2])
    return None


def eq_date(a, b) -> bool:
    da, db = parse_date(a), parse_date(b)
    if da and db:
        if da[0] is not None and db[0] is not None and da[0] != db[0]:
            return False
        return da[1:] == db[1:]
    return norm(a) == norm(b) and bool(norm(b))


def eq_text(a, b) -> bool:
    return norm(a) == norm(b)


_T = re.compile(r"(\d{1,2}):(\d{2})\s*([AaPp]\.?[Mm]\.?)?")


def parse_time(s) -> Optional[int]:
    """Minutes after midnight of the first h:mm in s; a trailing AM/PM converts 12-hour clock times."""
    m = _T.search(unicodedata.normalize("NFKC", str(s or "")))
    if not m:
        return None
    h, mi = int(m[1]), int(m[2])
    if m[3]:
        pm = m[3][0].lower() == "p"
        h = (h % 12) + (12 if pm else 0)
    return h * 60 + mi


def eq_time(a, b) -> bool:
    ta, tb = parse_time(a), parse_time(b)
    if ta is not None and tb is not None:
        return ta == tb
    return norm(a) == norm(b)
