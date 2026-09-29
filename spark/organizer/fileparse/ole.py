"""OLE compound files: legacy Word (.doc), Excel (.xls), PowerPoint (.ppt), Outlook (.msg), and Office files
encrypted with a password (an OOXML package inside EncryptionInfo / EncryptedPackage streams).

olefile (BSD) only lists and reads streams; the binary records are walked here. No macro stream
(Macros, _VBA_PROJECT, VBA) is ever read.
"""

from __future__ import annotations

import io
import re
import struct
from datetime import datetime, timedelta, timezone
from typing import Callable

from .core import MAX_SHEET_COLS, MAX_SHEET_ROWS, MAX_SHEETS, Budget, ParseError, Parsed, cell_text, clean_text, \
    first_line, md_table


def open_ole(data: bytes):
    import olefile
    try:
        return olefile.OleFileIO(io.BytesIO(data))
    except Exception as exc:  # noqa: BLE001
        raise ParseError("corrupt", f"not a readable OLE file: {exc}") from exc


def ole_kind(ole) -> str:
    names = {"/".join(p) for p in ole.listdir(streams=True, storages=True)}
    if "EncryptionInfo" in names and "EncryptedPackage" in names:
        return "ooxml_encrypted"
    if "WordDocument" in names:
        return "doc"
    if "Workbook" in names or "Book" in names:
        return "xls"
    if "PowerPoint Document" in names:
        return "ppt"
    if any(n.startswith("__substg1.0_") for n in names):
        return "msg"
    return "ole"


# ---- .doc (Word 97-2003): the text from the piece table ---------------------------------------------------


def parse_doc(ole) -> Parsed:
    wd = ole.openstream("WordDocument").read()
    if len(wd) < 0x1AA or struct.unpack_from("<H", wd, 0)[0] != 0xA5EC:
        raise ParseError("corrupt", "WordDocument without a FIB")
    flags = struct.unpack_from("<H", wd, 0x0A)[0]
    if flags & 0x0100:
        raise ParseError("encrypted", "Word document is encrypted")
    table_name = "1Table" if flags & 0x0200 else "0Table"
    if not ole.exists(table_name):
        raise ParseError("corrupt", f"missing {table_name}")
    table = ole.openstream(table_name).read()
    fc_clx, lcb_clx = struct.unpack_from("<II", wd, 0x01A2)
    clx = table[fc_clx:fc_clx + lcb_clx]
    i = 0
    while i < len(clx) and clx[i] == 0x01:  # Prc entries (formatting): skipped
        cb = struct.unpack_from("<H", clx, i + 1)[0]
        i += 3 + cb
    if i >= len(clx) or clx[i] != 0x02:
        raise ParseError("corrupt", "no piece table")
    lcb = struct.unpack_from("<I", clx, i + 1)[0]
    plc = clx[i + 5:i + 5 + lcb]
    n = (lcb - 4) // 12
    cps = struct.unpack_from(f"<{n + 1}I", plc, 0)
    out: list[str] = []
    for k in range(n):
        pcd = plc[4 * (n + 1) + 8 * k:4 * (n + 1) + 8 * (k + 1)]
        fc = struct.unpack_from("<I", pcd, 2)[0]
        count = cps[k + 1] - cps[k]
        if count <= 0 or count > 20_000_000:
            continue
        if fc & 0x40000000:
            off = (fc & 0x3FFFFFFF) // 2
            out.append(wd[off:off + count].decode("cp1252", "replace"))
        else:
            out.append(wd[fc:fc + 2 * count].decode("utf-16-le", "replace"))
    raw = "".join(out)
    # Field codes: keep the result (between \x14 and \x15), drop the instruction (between \x13 and \x14).
    raw = re.sub(r"\x13[^\x13\x14\x15]*\x14", "", raw)
    raw = re.sub(r"\x13[^\x13\x14\x15]*\x15", "", raw).replace("\x15", "")
    raw = raw.replace("\x07", "\t").replace("\r", "\n").replace("\x0b", "\n").replace("\x0c", "\n")
    text = clean_text(raw)
    return Parsed("document", text, first_line(text), {})


# ---- .xls -----------------------------------------------------------------------------------------------


def parse_xls(data: bytes, budget: Budget) -> Parsed:
    import xlrd  # BSD; xlrd 2.x reads .xls only
    try:
        book = xlrd.open_workbook(file_contents=data, on_demand=True, formatting_info=False)
    except xlrd.biffh.XLRDError as exc:
        if "encrypt" in str(exc).lower():
            raise ParseError("encrypted", str(exc)) from exc
        raise ParseError("corrupt", str(exc)) from exc
    except Exception as exc:  # noqa: BLE001
        raise ParseError("corrupt", f"xls: {type(exc).__name__}: {exc}") from exc
    blocks = []
    names = book.sheet_names()
    for si, name in enumerate(names[:MAX_SHEETS]):
        sh = book.sheet_by_index(si)
        rows = []
        for r in range(min(sh.nrows, MAX_SHEET_ROWS + 1)):
            row = []
            for c in range(min(sh.ncols, MAX_SHEET_COLS)):
                cell = sh.cell(r, c)
                if cell.ctype == xlrd.XL_CELL_DATE:
                    try:
                        value = xlrd.xldate.xldate_as_datetime(cell.value, book.datemode)
                    except Exception:  # noqa: BLE001
                        value = cell.value
                else:
                    value = cell.value
                row.append(cell_text(value))
            rows.append(row)
        table, left = md_table(rows)
        more = max(0, sh.nrows - len(rows)) + left
        blocks.append(f"## 工作表：{name}\n" + (table or "（空表）") + (f"\n（其余 {more} 行未列出）" if more else ""))
        book.unload_sheet(si)
    if len(names) > MAX_SHEETS:
        budget.note(f"工作表超过 {MAX_SHEETS} 个，其余未读")
    return Parsed("spreadsheet", "\n\n".join(blocks), "", {"sheets": len(names)})


# ---- .ppt: text atoms of the PowerPoint Document stream ---------------------------------------------------

_TEXT_CHARS, _TEXT_BYTES, _SLIDE_LIST_WITH_TEXT, _SLIDE_PERSIST, _SLIDE = 0x0FA0, 0x0FA8, 0x0FF0, 0x03F3, 0x03EE


def parse_ppt(ole) -> Parsed:
    stream = ole.openstream("PowerPoint Document").read()
    slides: list[list[str]] = []
    loose: list[str] = []
    n_slides = 0

    def walk(buf: bytes, start: int, end: int, in_list: bool, depth: int) -> None:
        nonlocal n_slides
        pos = start
        while pos + 8 <= end:
            ver_inst, rtype, rlen = struct.unpack_from("<HHI", buf, pos)
            body = pos + 8
            if rlen > end - body:
                return
            if rtype == _SLIDE:
                n_slides += 1
            if (ver_inst & 0x000F) == 0x000F and depth < 12:
                walk(buf, body, body + rlen, in_list or rtype == _SLIDE_LIST_WITH_TEXT, depth + 1)
            elif rtype == _SLIDE_PERSIST and in_list:
                slides.append([])
            elif rtype in (_TEXT_CHARS, _TEXT_BYTES):
                raw = buf[body:body + rlen]
                t = raw.decode("utf-16-le", "replace") if rtype == _TEXT_CHARS else raw.decode("cp1252", "replace")
                t = t.replace("\r", "\n").replace("\x0b", "\n").strip()
                if t and t != "*":
                    (slides[-1] if in_list and slides else loose).append(t)
            pos = body + rlen

    walk(stream, 0, len(stream), False, 0)
    blocks = [f"## 第 {i} 张幻灯片\n" + "\n".join(lines) for i, lines in enumerate(slides, 1) if lines]
    extra = [t for t in dict.fromkeys(loose) if not any(t in "\n".join(s) for s in slides)]
    if extra:
        blocks.append("\n".join(extra[:400]))
    text = clean_text("\n\n".join(blocks))
    return Parsed("slides", text, first_line(text), {"slides": len(slides) or n_slides})


# ---- .msg (Outlook) --------------------------------------------------------------------------------------


def _msg_prop(ole, prefix: str, prop: str) -> str:
    for suffix, enc in (("001F", "utf-16-le"), ("001E", "cp1252")):
        path = f"{prefix}__substg1.0_{prop}{suffix}"
        if ole.exists(path):
            raw = ole.openstream(path).read()
            return raw.decode(enc, "replace").rstrip("\x00").strip()
    return ""


def _msg_time(ole) -> str:
    """PR_CLIENT_SUBMIT_TIME (0x0039) or PR_MESSAGE_DELIVERY_TIME (0x0E06) from the property stream."""
    if not ole.exists("__properties_version1.0"):
        return ""
    raw = ole.openstream("__properties_version1.0").read()
    for off in range(32, len(raw) - 15, 16):
        tag = struct.unpack_from("<I", raw, off)[0]
        if tag in (0x00390040, 0x0E060040):
            ft = struct.unpack_from("<Q", raw, off + 8)[0]
            if ft:
                dt = datetime(1601, 1, 1, tzinfo=timezone.utc) + timedelta(microseconds=ft // 10)
                return dt.strftime("%Y-%m-%d %H:%M UTC")
    return ""


def parse_msg(ole, budget: Budget, sub: Callable[[bytes, str], Parsed]) -> Parsed:
    subject = _msg_prop(ole, "", "0037")
    sender = _msg_prop(ole, "", "0C1A")
    sender_addr = _msg_prop(ole, "", "0C1F") or _msg_prop(ole, "", "5D01")
    to = _msg_prop(ole, "", "0E04")
    cc = _msg_prop(ole, "", "0E03")
    body = _msg_prop(ole, "", "1000")
    date = _msg_time(ole)
    if not date:
        headers = _msg_prop(ole, "", "007D")
        m = re.search(r"(?im)^Date:\s*(.+)$", headers)
        date = m.group(1).strip() if m else ""
    if not body and ole.exists("__substg1.0_10130102"):
        from .core import decode_text, html_to_text
        _, body = html_to_text(decode_text(ole.openstream("__substg1.0_10130102").read()))
    frm = f"{sender} <{sender_addr}>" if sender and sender_addr and "@" in sender_addr else (sender or sender_addr)
    from .mail import render_mail
    attachments = []
    for entry in ole.listdir(streams=False, storages=True):
        if len(entry) == 1 and entry[0].startswith("__attach_version1.0_"):
            prefix = entry[0] + "/"
            name = _msg_prop(ole, prefix, "3707") or _msg_prop(ole, prefix, "3704") or "附件"
            data_path = prefix + "__substg1.0_37010102"
            data = ole.openstream(data_path).read() if ole.exists(data_path) else b""
            attachments.append((name, data))
    return render_mail({"from": frm, "to": to, "cc": cc, "date": date, "subject": subject}, body, attachments,
                       budget, sub)
