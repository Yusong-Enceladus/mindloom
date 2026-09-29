"""Meeting transcript exports pasted or imported as text (contract A).

The Mac reads the same text with the same rules (BestASRMemory/MemoryTranscriptText.swift); both sides
are checked against spark/tests/fixtures/transcript_formats.json (the Mac keeps a copy of that file).
Keep the two in step: the organizer cuts split segments on these turns and the Mac slices the item text
with the offsets it gets back.

The text is read line by line (split on "\\n"; each line trimmed of surrounding whitespace, so a CRLF
export's "\\r" is not content). Formats, tried in this order:

  tencent   Tencent Meeting export: a header line "Name(HH:MM:SS):" (ASCII or full-width brackets and
            colon, the colon optional; H:MM and MM:SS also accepted), then the utterance on the following
            lines until the next header. The utterance may also follow the colon on the header line.
  feishu    Feishu minutes: a header line "Name HH:MM:SS" (seconds required, nothing after the time), then
            the utterance as above.
  zoom      "[HH:MM:SS] Name: text" per line; a following line without a header continues the turn and a
            blank line ends it.
  vtt/srt   WebVTT / SRT: a cue timing line "HH:MM:SS.mmm --> HH:MM:SS.mmm" ("," for SRT; a cue number on
            the line above belongs to the cue), then "Name: text" or "<v Name>text"; the cue's text runs to
            the next blank line. Cues without a speaker are not turns; consecutive cues of one speaker are
            one turn.

A speaker name is at most 40 characters, does not start with a digit, has no sentence punctuation or
brackets and at most 8 CJK ideographs (so "记得带上报告，明天(09:00):" is not a header). A name may be
"中文名 English NAME". Lines before the first header belong to no turn. Text is a transcript when a
format yields at least two turns with words; the format with the most turns wins, the earlier one in the
order above on a tie. Generic speaker labels (说话人1, Speaker 2, 发言人) are kept as the turn's speaker
but are not people (`is_generic_speaker`).

Each turn is {speaker, t ("HH:MM:SS"), text, start, end}. start/end are character offsets (Python str
indices = Unicode scalars; "\\r\\n" counts 2) from the first non-space character of the header line (the
cue number's line for SRT) to the end of the turn's last non-empty line, trailing spaces and "\\r"
excluded. A split segment starts at a turn's start and ends at a turn's end.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Optional

_CLOCK = r"(\d{1,2}:\d{2}(?::\d{2})?)"
_TENCENT = re.compile(r"^(\S(?:[^()（）]{0,38}\S)?)\s*[(（]\s*" + _CLOCK + r"\s*[)）]\s*(?:[:：]\s*(.*))?$")
_FEISHU = re.compile(r"^(\S(?:.{0,38}\S)?)\s+(\d{1,2}:\d{2}:\d{2})$")
_ZOOM = re.compile(r"^\[\s*" + _CLOCK + r"\s*\]\s*([^:：\[\]]{1,40}?)\s*[:：]\s*(.*)$")
_CUE = re.compile(r"^(\d{1,2}:\d{2}(?::\d{2})?)[.,]\d{1,3}\s*-->\s*\d{1,2}:\d{2}(?::\d{2})?[.,]\d{1,3}")
_VOICE = re.compile(r"^<v(?:\.[^\s>]+)?\s+([^>]{1,40})>(.*)$")
_NAMED = re.compile(r"^([^:：]{1,40}?)\s*[:：]\s*(\S.*)$")
_CUE_NUMBER = re.compile(r"^[+-]?[0-9]+$")
_GENERIC = re.compile(r"^(说话人|发言人|讲话人|参会人|参会者|未知|speaker|unknown|participant)[ \t_-]*\d*$", re.I)
_NOT_IN_NAME = set("。，,、！!？?；;：:“”\"「」【】[]()（）<>")


@dataclass
class _Line:
    text: str            # trimmed
    start: int           # offset of the first non-space character
    end: int             # offset just after the last non-space character


def _lines(text: str) -> list[_Line]:
    out, offset = [], 0
    for raw in text.split("\n"):
        lead = len(raw) - len(raw.lstrip())
        trail = len(raw) - len(raw.rstrip())
        out.append(_Line(raw.strip(), offset + lead, offset + len(raw) - trail))
        offset += len(raw) + 1
    return out


def _hms(t: str) -> str:
    """"1:02" -> "00:01:02", "1:02:03" -> "01:02:03"; fractions are dropped."""
    t = re.split(r"[.,]", t)[0]
    parts = [int(p) for p in t.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0)
    h, m, s = parts[-3:]
    return f"{h:02d}:{m:02d}:{s:02d}"


def clean_speaker(name: str) -> str:
    return re.sub(r"[ \t]+", " ", (name or "").strip())


def is_generic_speaker(name: str) -> bool:
    return not name or _GENERIC.match(name.strip()) is not None


def is_speaker_name(name: str) -> bool:
    """A name, not a clause (the same rule as MemoryTranscriptText.isSpeakerName)."""
    if not name or len(name) > 40 or name[0].isdecimal():
        return False
    if any(ch in _NOT_IN_NAME for ch in name):
        return False
    return sum(1 for ch in name if "一" <= ch <= "鿿") <= 8


def _turn(speaker: str, t: str, body: list[str], start: int, end: int) -> Optional[dict]:
    text = "\n".join(body)
    if not text:
        return None
    return {"speaker": clean_speaker(speaker), "t": _hms(t), "text": text, "start": start, "end": end}


def _headed(lines: list[_Line], header: re.Pattern, inline: bool) -> list[dict]:
    """Header line + utterance lines (tencent, feishu)."""
    turns: list[dict] = []
    cur: Optional[dict] = None

    def flush() -> None:
        nonlocal cur
        if cur is not None and (turn := _turn(**cur)) is not None:
            turns.append(turn)
        cur = None

    for line in lines:
        m = header.match(line.text)
        if m and is_speaker_name(m.group(1).strip()):
            flush()
            rest = (m.group(3) or "").strip() if inline else ""
            cur = {"speaker": m.group(1).strip(), "t": m.group(2), "body": [rest] if rest else [],
                   "start": line.start, "end": line.end}
            continue
        if not line.text or cur is None:
            continue
        cur["body"].append(line.text)
        cur["end"] = line.end
    flush()
    return turns


def _zoom(lines: list[_Line]) -> list[dict]:
    turns: list[dict] = []
    cur: Optional[dict] = None

    def flush() -> None:
        nonlocal cur
        if cur is not None and (turn := _turn(**cur)) is not None:
            turns.append(turn)
        cur = None

    for line in lines:
        m = _ZOOM.match(line.text)
        if m and is_speaker_name(m.group(2).strip()):
            flush()
            first = m.group(3).strip()
            cur = {"speaker": m.group(2).strip(), "t": m.group(1), "body": [first] if first else [],
                   "start": line.start, "end": line.end}
            continue
        if not line.text:
            flush()  # a blank line ends a turn in this format
            continue
        if cur is None:
            continue
        cur["body"].append(line.text)
        cur["end"] = line.end
    flush()
    return turns


def _subtitles(lines: list[_Line]) -> list[dict]:
    """WebVTT / SRT cues whose text names a speaker (<v Name> or "Name:")."""
    turns: list[dict] = []
    i = 0
    while i < len(lines):
        timing = _CUE.match(lines[i].text)
        if not timing:
            i += 1
            continue
        start = lines[i].start
        if i > 0 and _CUE_NUMBER.match(lines[i - 1].text):
            start = lines[i - 1].start  # the cue number belongs to the cue
        body: list[_Line] = []
        j = i + 1
        while j < len(lines) and lines[j].text and not _CUE.match(lines[j].text):
            body.append(lines[j])
            j += 1
        i = j
        if not body:
            continue
        first = body[0].text
        v = _VOICE.match(first)
        if v:
            speaker, opening = v.group(1), v.group(2)
        else:
            p = _NAMED.match(first)
            if not p or not is_speaker_name(p.group(1)):
                continue
            speaker, opening = p.group(1), p.group(2)
        opening = opening.replace("</v>", "").strip()
        text = "\n".join(x for x in [opening] + [b.text for b in body[1:]] if x)
        if not text:
            continue
        speaker = clean_speaker(speaker)
        if turns and turns[-1]["speaker"] == speaker:
            # Consecutive cues of one speaker are one turn.
            turns[-1]["text"] += "\n" + text
            turns[-1]["end"] = body[-1].end
        else:
            turns.append({"speaker": speaker, "t": _hms(timing.group(1)), "text": text,
                          "start": start, "end": body[-1].end})
    return turns


def parse(text: Optional[str]) -> Optional[dict]:
    """{"format", "turns": [{speaker, t, text, start, end}]} or None when the text is not a transcript."""
    if not text:
        return None
    lines = _lines(text)
    candidates = [("tencent", _headed(lines, _TENCENT, inline=True)),
                  ("feishu", _headed(lines, _FEISHU, inline=False)),
                  ("zoom", _zoom(lines))]
    first_cue = next((m for line in lines if (m := _CUE.match(line.text))), None)
    if first_cue is not None:
        vtt = text.lstrip().upper().startswith("WEBVTT") or "." in first_cue.group(0).split("-->")[0]
        candidates.append(("vtt" if vtt else "srt", _subtitles(lines)))
    best_fmt, best = "", []
    for fmt, turns in candidates:
        if len(turns) >= 2 and len(turns) > len(best):
            best_fmt, best = fmt, turns
    if not best:
        return None
    return {"format": best_fmt, "turns": best}


def speakers(parsed: Optional[dict]) -> list[str]:
    """Distinct non-generic speaker names in order of first appearance."""
    out: list[str] = []
    for turn in (parsed or {}).get("turns") or []:
        name = turn["speaker"]
        if name and not is_generic_speaker(name) and name not in out:
            out.append(name)
    return out
