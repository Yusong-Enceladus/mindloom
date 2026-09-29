"""Plain and structured text: txt / md / log / source code, csv / tsv, json / ipynb, yaml, xml, rtf, html,
and saved web pages (.webarchive, .webloc, .url). Links are recorded as text only; nothing is fetched.
"""

from __future__ import annotations

import json
import plistlib
import re

from .core import (ParseError, Parsed, cell_text, clean_text, decode_text, delimited_rows, ext_of, first_line,
                   html_to_text, md_table)
from .pkg import local, parse_xml

LANG = {"py": "Python", "js": "JavaScript", "ts": "TypeScript", "tsx": "TypeScript", "jsx": "JavaScript",
        "java": "Java", "kt": "Kotlin", "swift": "Swift", "c": "C", "h": "C", "cpp": "C++", "cc": "C++",
        "hpp": "C++", "cs": "C#", "go": "Go", "rs": "Rust", "rb": "Ruby", "php": "PHP", "sh": "Shell",
        "bash": "Shell", "zsh": "Shell", "sql": "SQL", "css": "CSS", "m": "Objective-C", "mm": "Objective-C++",
        "r": "R", "lua": "Lua", "dart": "Dart", "scala": "Scala", "tex": "LaTeX", "toml": "TOML", "ini": "INI"}


def parse_text(data: bytes, name: str, fmt: str) -> Parsed:
    text = clean_text(decode_text(data))
    ext = ext_of(name)
    if fmt == "code":
        lang = LANG.get(ext, ext.upper() or "代码")
        return Parsed("code", text, first_line(text), {"lines": text.count("\n") + 1 if text else 0},
                      fields=[{"key": "language", "label": "语言", "value": lang}] if lang in text else [])
    title = ""
    if ext in ("md", "markdown"):
        m = re.search(r"(?m)^#\s+(.+)$", text)
        title = m.group(1).strip() if m else ""
    return Parsed("text", text, title or first_line(text), {})


def parse_delimited(data: bytes, fmt: str) -> Parsed:
    text = decode_text(data)
    rows = delimited_rows(text, "\t" if fmt == "tsv" else None)
    table, left = md_table(rows)
    total = len(rows)
    out = table + (f"\n（其余 {left} 行未列出）" if left else "")
    return Parsed("spreadsheet", out, "", {"sheets": 1, "rows": total})


def parse_json(data: bytes) -> Parsed:
    text = decode_text(data)
    try:
        obj = json.loads(text)
    except ValueError:
        # JSON Lines, or broken JSON: keep the text as it is.
        lines = [ln for ln in text.splitlines() if ln.strip()]
        try:
            objs = [json.loads(ln) for ln in lines[:2000]]
        except ValueError:
            return Parsed("data", clean_text(text), "", {})
        return Parsed("data", "\n".join(json.dumps(o, ensure_ascii=False) for o in objs), "", {"records": len(lines)})
    pretty = json.dumps(obj, ensure_ascii=False, indent=1)
    if len(pretty) > 200_000:
        pretty = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    counts = {"records": len(obj)} if isinstance(obj, list) else {}
    return Parsed("data", pretty, "", counts)


def parse_ipynb(data: bytes) -> Parsed:
    try:
        nb = json.loads(decode_text(data))
    except ValueError as exc:
        raise ParseError("corrupt", f"notebook: {exc}") from exc
    blocks = []
    for cell in (nb.get("cells") or [])[:1000]:
        src = cell.get("source") or ""
        src = "".join(src) if isinstance(src, list) else str(src)
        if cell.get("cell_type") == "markdown":
            blocks.append(src.strip())
        elif cell.get("cell_type") == "code":
            blocks.append("```\n" + src.strip() + "\n```")
            for out in cell.get("outputs") or []:
                t = out.get("text") or (out.get("data") or {}).get("text/plain") or ""
                t = "".join(t) if isinstance(t, list) else str(t)
                if t.strip():
                    blocks.append("输出：" + t.strip()[:2000])
    text = clean_text("\n\n".join(b for b in blocks if b))
    return Parsed("code", text, first_line(text), {"cells": len(nb.get("cells") or [])},
                  fields=[{"key": "language", "label": "语言", "value": "Python"}] if "Python" in text else [])


def parse_yaml(data: bytes) -> Parsed:
    # Kept as text: YAML is never loaded (no object construction, no alias expansion).
    text = clean_text(decode_text(data))
    return Parsed("data", text, first_line(text), {})


def parse_xml_file(data: bytes, name: str) -> Parsed:
    ext = ext_of(name)
    if ext == "svg":
        root = parse_xml(data)
        texts = [(e.text or "").strip() for e in root.iter() if local(e.tag) in ("text", "tspan", "title", "desc")]
        return Parsed("image", clean_text("\n".join(t for t in texts if t)), "", {})
    if data.lstrip()[:5] == b"<?xml" and b"<plist" in data[:400]:
        return parse_plist(data, name)
    root = parse_xml(data)
    lines = []
    for el in root.iter():
        t = (el.text or "").strip()
        # Outline and mind-map formats (OPML, FreeMind .mm, KML names) keep their words in attributes.
        t = t or next((el.get(a) for a in ("text", "TEXT", "title", "name") if (el.get(a) or "").strip()), "")
        if t and len(lines) < 20000:
            lines.append(f"{local(el.tag)}：{t.strip()}")
    return Parsed("data", clean_text("\n".join(lines)), local(root.tag), {})


# ---- mind maps (XMind) and databases (SQLite) ------------------------------------------------------------


def parse_xmind(pkg) -> Parsed:
    """XMind Zen / 2020+ (content.json) or XMind 8 (content.xml): each sheet's topic tree as a nested list,
    with notes and labels."""
    blocks: list[str] = []
    raw = pkg.read("content.json", limit=50 * 1024 * 1024)
    if raw:
        try:
            sheets = json.loads(decode_text(raw))
        except ValueError as exc:
            raise ParseError("corrupt", f"xmind content.json: {exc}") from exc

        def walk_json(topic: dict, depth: int, out: list[str]) -> None:
            if not isinstance(topic, dict) or len(out) > 5000 or depth > 30:
                return
            title = str(topic.get("title") or "").strip()
            note = ((topic.get("notes") or {}).get("plain") or {}).get("content") if isinstance(topic.get("notes"), dict) else ""
            labels = topic.get("labels") or []
            line = "  " * depth + "- " + title + (f"（{'、'.join(map(str, labels))}）" if labels else "")
            out.append(line + (f"\n{'  ' * depth}  备注：{str(note).strip()}" if note else ""))
            children = topic.get("children") or {}
            for key in ("attached", "detached"):
                for child in children.get(key) or []:
                    walk_json(child, depth + 1, out)

        for sheet in sheets if isinstance(sheets, list) else []:
            out: list[str] = []
            walk_json(sheet.get("rootTopic") or {}, 0, out)
            blocks.append(f"## 画布：{sheet.get('title') or ''}\n" + "\n".join(out))
    else:
        root = pkg.xml("content.xml")
        if root is None:
            raise ParseError("corrupt", "xmind without content")

        def walk_xml(topic, depth: int, out: list[str]) -> None:
            if len(out) > 5000 or depth > 30:
                return
            title = next((c.text or "" for c in topic if local(c.tag) == "title"), "").strip()
            out.append("  " * depth + "- " + title)
            for c in topic:
                if local(c.tag) == "children":
                    for topics in c:
                        for child in topics:
                            if local(child.tag) == "topic":
                                walk_xml(child, depth + 1, out)

        for sheet in [e for e in root if local(e.tag) == "sheet"]:
            out: list[str] = []
            sheet_title = next((c.text or "" for c in sheet if local(c.tag) == "title"), "")
            for topic in [c for c in sheet if local(c.tag) == "topic"]:
                walk_xml(topic, 0, out)
            blocks.append(f"## 画布：{sheet_title}\n" + "\n".join(out))
    text = clean_text("\n\n".join(blocks))
    return Parsed("document", text, first_line(text), {"sheets": len(blocks)})


def parse_sqlite(data: bytes) -> Parsed:
    """An SQLite database, opened in memory from the bytes (nothing is written): each table's columns, row
    count and first 20 rows. Views and triggers are never run."""
    import sqlite3
    conn = sqlite3.connect(":memory:")
    try:
        conn.deserialize(data)
        conn.execute("PRAGMA query_only = 1")
        tables = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
                                             " ORDER BY name LIMIT 50")]
        blocks = []
        for t in tables:
            q = '"' + t.replace('"', '""') + '"'
            cur = conn.execute(f"SELECT * FROM {q} LIMIT 20")
            cols = [d[0] for d in cur.description or []][:MAX_COLS]
            rows = [[cell_text(v if not isinstance(v, bytes) else f"<{len(v)} 字节>") for v in r[:MAX_COLS]]
                    for r in cur.fetchall()]
            n = conn.execute(f"SELECT COUNT(*) FROM {q}").fetchone()[0]
            table, _ = md_table([cols] + rows, max_rows=20)
            blocks.append(f"## 表：{t}（{n} 行）\n" + (table or "（空表）"))
    except sqlite3.DatabaseError as exc:
        msg = str(exc).lower()
        raise ParseError("encrypted" if "encrypt" in msg or "not a database" in msg else "corrupt", str(exc)) from exc
    finally:
        conn.close()
    return Parsed("data", "\n\n".join(blocks), "", {"tables": len(tables)})


MAX_COLS = 30


def parse_html(data: bytes) -> Parsed:
    raw = decode_text(data, _html_charset(data))
    title, text = html_to_text(raw)
    return Parsed("web", text, title or first_line(text), {})


def _html_charset(data: bytes) -> str:
    m = re.search(rb"""<meta[^>]+charset=["']?([A-Za-z0-9_\-]+)""", data[:4096], re.I)
    return m.group(1).decode("ascii") if m else ""


# ---- RTF --------------------------------------------------------------------------------------------------

_RTF_SKIP = {"fonttbl", "colortbl", "stylesheet", "info", "pict", "object", "header", "footer", "headerl",
             "headerr", "footerl", "footerr", "listtable", "listoverridetable", "rsidtbl", "generator",
             "themedata", "colorschememapping", "latentstyles", "datastore", "xmlnstbl", "fldinst", "bkmkstart",
             "bkmkend", "field_instruction", "pgdsctbl", "revtbl", "filetbl", "mmathPr", "expandedcolortbl"}


def rtf_to_text(rtf: str) -> str:
    out: list[str] = []
    stack: list[tuple[bool, int, str]] = []
    skip = False
    uc = 1
    codepage = "cp1252"
    pending_bytes = bytearray()
    i, n = 0, len(rtf)
    ignore_next = 0

    def flush() -> None:
        if pending_bytes:
            out.append(bytes(pending_bytes).decode(codepage, "replace"))
            pending_bytes.clear()

    while i < n:
        ch = rtf[i]
        if ch == "{":
            flush()
            stack.append((skip, uc, codepage))
            i += 1
            if rtf.startswith("\\*", i):
                skip = True
        elif ch == "}":
            flush()
            if stack:
                skip, uc, codepage = stack.pop()
            i += 1
        elif ch == "\\":
            m = re.match(r"\\([a-zA-Z]+)(-?\d+)? ?|\\'([0-9a-fA-F]{2})|\\(.)", rtf[i:i + 40], re.S)
            if not m:
                i += 1
                continue
            i += m.end()
            word, arg, hexb, sym = m.group(1), m.group(2), m.group(3), m.group(4)
            if hexb is not None:
                if ignore_next:
                    ignore_next -= 1
                elif not skip:
                    pending_bytes.append(int(hexb, 16))
                continue
            flush()
            if sym is not None:
                if not skip and sym in "\\{}":
                    out.append(sym)
                elif not skip and sym == "~":
                    out.append("\u00a0")
                elif not skip and sym in "\n\r":
                    out.append("\n")
                continue
            if word in _RTF_SKIP:
                skip = True
            elif word == "ansicpg" and arg:
                codepage = f"cp{arg}"
                try:
                    "".encode(codepage)
                except LookupError:
                    codepage = "cp1252"
            elif word == "uc" and arg:
                uc = int(arg)
            elif word == "u" and arg and not skip:
                code = int(arg)
                out.append(chr(code + 65536 if code < 0 else code))
                ignore_next = uc
            elif skip:
                continue
            elif word in ("par", "line", "sect", "page", "row"):
                out.append("\n")
            elif word == "tab" or word == "cell":
                out.append("\t")
            elif word in ("emdash",):
                out.append("—")
            elif word in ("endash",):
                out.append("–")
            elif word in ("lquote", "rquote"):
                out.append("'")
            elif word in ("ldblquote", "rdblquote"):
                out.append('"')
            elif word == "bullet":
                out.append("•")
        else:
            if ch in "\r\n":
                i += 1
                continue
            if ignore_next:
                ignore_next -= 1
            elif not skip:
                flush()
                out.append(ch)
            i += 1
    flush()
    return clean_text("".join(out))


def parse_rtf(data: bytes) -> Parsed:
    text = rtf_to_text(data.decode("latin-1"))
    return Parsed("document", text, first_line(text), {})


# ---- saved web content ----------------------------------------------------------------------------------


def parse_plist(data: bytes, name: str) -> Parsed:
    try:
        obj = plistlib.loads(data)
    except Exception as exc:  # noqa: BLE001
        raise ParseError("corrupt", f"plist: {exc}") from exc
    ext = ext_of(name)
    if isinstance(obj, dict) and "WebMainResource" in obj:
        return _webarchive(obj)
    if isinstance(obj, dict) and isinstance(obj.get("URL"), str) and (ext == "webloc" or len(obj) <= 3):
        return Parsed("web", f"链接：{obj['URL']}", obj["URL"], {}, fields=[{"key": "url", "label": "链接", "value": obj["URL"]}])
    text = json.dumps(obj, ensure_ascii=False, indent=1, default=lambda o: o.hex() if isinstance(o, bytes) else str(o))
    return Parsed("data", text[:200_000], "", {})


def _webarchive(obj: dict) -> Parsed:
    main = obj.get("WebMainResource") or {}
    url = str(main.get("WebResourceURL") or "")
    raw = main.get("WebResourceData") or b""
    enc = str(main.get("WebResourceTextEncodingName") or "")
    mime = str(main.get("WebResourceMIMEType") or "text/html")
    content = decode_text(raw, enc) if isinstance(raw, bytes) else str(raw)
    if "html" in mime:
        title, text = html_to_text(content)
    else:
        title, text = "", clean_text(content)
    head = f"网址：{url}\n" if url else ""
    fields = [{"key": "url", "label": "网址", "value": url}] if url else []
    return Parsed("web", clean_text(head + text), title or first_line(text), {}, fields=fields)


def parse_url_file(data: bytes) -> Parsed:
    text = decode_text(data)
    m = re.search(r"(?im)^URL\s*=\s*(\S+)", text)
    if not m:
        raise ParseError("corrupt", "internet shortcut without URL=")
    url = m.group(1).strip()
    return Parsed("web", f"链接：{url}", url, {}, fields=[{"key": "url", "label": "链接", "value": url}])
