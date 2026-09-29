"""PDF: the text layer page by page (pypdfium2, Apache-2.0 / BSD-3); pages without a text layer (scans,
photos of paper, outlined text) are rendered and read by image-read, at most 20 per file.

PDFium runs no JavaScript here (no form environment is initialized), opens no links and follows no
remote references. A password-protected file is reported as "encrypted", never guessed.
"""

from __future__ import annotations

import io

from .core import MAX_PDF_PAGES_TEXT, Budget, ParseError, Parsed, clean_text, first_line
from .images import add_image

MIN_PAGE_CHARS = 20
RENDER_DPI = 200


def _pdfium():
    import pypdfium2 as pdfium
    return pdfium


def parse_pdf(data: bytes, budget: Budget) -> Parsed:
    pdfium = _pdfium()
    try:
        pdf = pdfium.PdfDocument(data)
    except pdfium.PdfiumError as exc:
        if "password" in str(exc).lower():
            raise ParseError("encrypted", "password-protected PDF") from exc
        raise ParseError("corrupt", f"pdf: {exc}") from exc
    try:
        return _read(pdf, budget)
    finally:
        pdf.close()


def _page_has_graphics(page) -> bool:
    import pypdfium2.raw as raw
    n_img = n_other = 0
    for obj in page.get_objects(max_depth=2):
        if obj.type == raw.FPDF_PAGEOBJ_IMAGE:
            n_img += 1
        elif obj.type in (raw.FPDF_PAGEOBJ_PATH, raw.FPDF_PAGEOBJ_SHADING):
            n_other += 1
        if n_img or n_other > 40:
            return True
    return False


def _read(pdf, budget: Budget) -> Parsed:
    n = len(pdf)
    pages: list[tuple[int, str]] = []
    image_pages: list[int] = []
    for i in range(min(n, MAX_PDF_PAGES_TEXT)):
        page = pdf[i]
        try:
            tp = page.get_textpage()
            text = clean_text(tp.get_text_bounded())
            tp.close()
            if len(text.replace(" ", "")) < MIN_PAGE_CHARS and _page_has_graphics(page):
                image_pages.append(i)
            pages.append((i, text))
        finally:
            page.close()
    if n > MAX_PDF_PAGES_TEXT:
        budget.note(f"PDF 共 {n} 页，只读了前 {MAX_PDF_PAGES_TEXT} 页的文字")
    text_pages = sum(1 for _, t in pages if len(t.replace(" ", "")) >= MIN_PAGE_CHARS)
    scanned = bool(image_pages) and len(image_pages) >= max(1, text_pages)
    markers: dict[int, str] = {}
    for i in image_pages:
        if budget.scanned_pages_left <= 0:
            budget.note(f"无文字层的页超过 {len(markers)} 页上限，其余未识别")
            break
        page = pdf[i]
        try:
            w, h = page.get_size()
            scale = min(RENDER_DPI / 72.0, 2560.0 / max(w, h, 1.0))
            bitmap = page.render(scale=scale, grayscale=False)
            pil = bitmap.to_pil()
            buf = io.BytesIO()
            pil.convert("RGB").save(buf, "JPEG", quality=85)
            bitmap.close()
        finally:
            page.close()
        marker = add_image(budget, buf.getvalue(), f"第 {i + 1} 页（扫描）", page=True)
        if marker:
            markers[i] = marker
    blocks = []
    for i, t in pages:
        body = t
        if i in markers:
            body = (t + "\n" if t else "") + markers[i]
        if body:
            blocks.append((f"## 第 {i + 1} 页\n" if n > 1 else "") + body)
    title = ""
    try:
        meta = pdf.get_metadata_dict(skip_empty=True)
        title = (meta.get("Title") or "").strip()
    except Exception:  # noqa: BLE001
        pass
    text = "\n\n".join(blocks)
    counts = {"pages": n}
    if image_pages:
        counts["image_pages"] = len(image_pages)
    return Parsed("scanned_pdf" if scanned else "pdf", text, title or first_line(text), counts)
