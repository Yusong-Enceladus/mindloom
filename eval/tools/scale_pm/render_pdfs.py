#!/usr/bin/env python3
"""Render the text PDFs of scale-pm with a real text layer (reportlab, built-in STSong-Light CID font).

  python3 render_pdfs.py jobs.json OUT_DIR

jobs.json: [{"file": "小澄_PRD_v2.1.pdf", "text": "..."}]. The first line is the title. Every page carries a
small "合成数据" mark. Scanned PDFs are not made here (assemble.py writes image-only PDFs with Pillow).
"""

import json
import os
import sys

from reportlab.lib.pagesizes import A4
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
from reportlab.pdfgen import canvas

pdfmetrics.registerFont(UnicodeCIDFont("STSong-Light"))
FONT = "STSong-Light"


def wrap(text, size, width):
    lines, cur = [], ""
    for ch in text:
        if pdfmetrics.stringWidth(cur + ch, FONT, size) > width and cur:
            lines.append(cur)
            cur = ch
        else:
            cur += ch
    lines.append(cur)
    return lines


def render(text, path):
    w, h = A4
    c = canvas.Canvas(path, pagesize=A4)
    c.setTitle(os.path.basename(path))
    c.setAuthor("synthetic")
    margin = 56
    y = h - margin

    def mark():
        c.setFont(FONT, 8)
        c.setFillColorRGB(0.8, 0.27, 0.23)
        c.drawRightString(w - 24, h - 20, "合成数据")
        c.setFillColorRGB(0, 0, 0)

    mark()
    lines = text.strip().splitlines()
    title, body = (lines[0], lines[1:]) if lines else ("", [])
    c.setFont(FONT, 15)
    for tl in wrap(title, 15, w - 2 * margin):
        c.drawCentredString(w / 2, y, tl)
        y -= 22
    y -= 8
    for para in body:
        size = 10.5
        for ln in wrap(para, size, w - 2 * margin) if para.strip() else [""]:
            if y < margin:
                c.showPage()
                mark()
                y = h - margin
            c.setFont(FONT, size)
            c.drawString(margin, y, ln)
            y -= 16
    c.save()


def main():
    jobs = json.load(open(sys.argv[1], encoding="utf-8"))
    out = sys.argv[2]
    os.makedirs(out, exist_ok=True)
    for j in jobs:
        render(j["text"], os.path.join(out, j["file"]))
        print(j["file"])


if __name__ == "__main__":
    main()
