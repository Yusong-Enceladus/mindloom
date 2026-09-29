"""Image parts of a file (embedded pictures, scanned PDF pages, image entries of an archive).

Each accepted image is normalized to PNG or JPEG with the longer side <= 2560 px (what image-read takes)
and put in the budget; the text gets a marker [[IMG:n]] where the image stood, which the organizer
replaces with the image's reading (or drops when the image could not be read).
"""

from __future__ import annotations

import hashlib
import io
import warnings
from typing import Optional

from .core import IMAGE_MAX_SIDE, MIN_IMAGE_AREA, MIN_IMAGE_SIDE, Budget

try:
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = 60_000_000
    warnings.simplefilter("error", Image.DecompressionBombWarning)
except ImportError:  # pragma: no cover - Pillow is a declared dependency
    Image = None  # type: ignore[assignment]


def normalize(data: bytes, max_side: int = IMAGE_MAX_SIDE) -> Optional[tuple[bytes, int, int]]:
    """(PNG/JPEG bytes, width, height) or None when the image cannot be decoded (EMF/WMF/SVG/HEIC, corrupt)."""
    if Image is None:
        return None
    try:
        with Image.open(io.BytesIO(data)) as im:
            im.seek(0)
            fmt = (im.format or "").upper()
            w, h = im.size
            if fmt in ("WMF", "EMF"):
                return None
            im.load()
            if im.mode in ("P", "LA", "PA") or (im.mode == "RGBA"):
                im = im.convert("RGBA")
                bg = Image.new("RGB", im.size, (255, 255, 255))
                bg.paste(im, mask=im.split()[-1])
                im = bg
            elif im.mode not in ("RGB", "L"):
                im = im.convert("RGB")
            if max(w, h) > max_side:
                scale = max_side / max(w, h)
                im = im.resize((max(1, round(w * scale)), max(1, round(h * scale))), Image.LANCZOS)
            out = io.BytesIO()
            if fmt == "PNG" and w * h <= 4_000_000:
                im.save(out, "PNG", optimize=False)
            else:
                im.save(out, "JPEG", quality=88)
            return out.getvalue(), im.size[0], im.size[1]
    except Exception:  # noqa: BLE001 - any undecodable picture is simply not read
        return None


def add_image(budget: Budget, data: bytes, label: str, *, page: bool = False,
              min_side: int = MIN_IMAGE_SIDE, min_area: int = MIN_IMAGE_AREA) -> Optional[str]:
    """Queue one image for image-read. Returns the text marker, or None (too small, duplicate, undecodable,
    or over the per-file cap, which is noted once)."""
    digest = hashlib.sha256(data).hexdigest()
    if digest in budget.image_hashes:
        return None
    left = budget.scanned_pages_left if page else budget.images_left
    if left <= 0:
        budget.note("扫描页超过上限，其余页未识别" if page else "图片超过上限，其余图片未识别")
        return None
    norm = normalize(data)
    if norm is None:
        return None
    img, w, h = norm
    if not page and (min(w, h) < min_side or w * h < min_area):
        return None
    budget.image_hashes.add(digest)
    if page:
        budget.scanned_pages_left -= 1
    else:
        budget.images_left -= 1
    n = len(budget.images) + 1
    budget.images.append({"id": n, "data": img, "label": label, "page": page})
    return f"[[IMG:{n}]]"
