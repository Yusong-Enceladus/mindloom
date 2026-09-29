"""Font registry for the multimodal generator.

Every face is looked up by a short key. macOS keeps several CJK faces (Kaiti, Hanzipen, Hannotate,
Xingkai, Yuanti, Lantinghei, Wawati) as downloadable assets under /System/Library/AssetsV2, so those are
found by file name with a glob. Override any key with EVAL_FONT_<KEY>=/path/to/font[:index].

Every string drawn goes through `check()`: a glyph the face does not have would be drawn as an empty
box while the ground truth still says the character is there, so a missing glyph is an error.
"""

from __future__ import annotations

import glob
import os
from functools import lru_cache

import logging

from PIL import ImageFont

logging.getLogger("fontTools").setLevel(logging.ERROR)  # "extra bytes in post.stringData" on some system faces

_ASSETS = "/System/Library/AssetsV2/com_apple_MobileAsset_Font*/*/AssetData/"
_SYS = "/System/Library/Fonts/"
_SUP = "/System/Library/Fonts/Supplemental/"

# key -> (candidate paths or globs, face index, needs CJK)
FACES: dict[str, tuple[list[str], int, bool]] = {
    "hei": ([_SYS + "Hiragino Sans GB.ttc"], 0, True),              # Hiragino Sans GB W3
    "hei_bold": ([_SYS + "Hiragino Sans GB.ttc"], 2, True),         # W6
    "heiti": ([_SYS + "STHeiti Light.ttc"], 1, True),               # Heiti SC Light
    "heiti_med": ([_SYS + "STHeiti Medium.ttc"], 1, True),          # Heiti SC Medium
    "song": ([_SUP + "Songti.ttc"], 6, True),                       # Songti SC Regular
    "song_bold": ([_SUP + "Songti.ttc"], 1, True),                  # Songti SC Bold
    "kai": ([_ASSETS + "Kaiti.ttc"], 0, True),                      # Kaiti SC
    "yuan": ([_ASSETS + "Yuanti.ttc"], 0, True),                    # Yuanti SC
    "lanting": ([_ASSETS + "Lantinghei.ttc"], 1, True),             # Lantinghei SC Extralight
    "lanting_bold": ([_ASSETS + "Lantinghei.ttc"], 0, True),        # Lantinghei SC Demibold
    # handwriting-like CJK faces
    "hand_pen": ([_ASSETS + "Hanzipen.ttc"], 0, True),              # HanziPen SC
    "hand_note": ([_ASSETS + "Hannotate.ttc"], 0, True),            # Hannotate SC
    "hand_wawa": ([_ASSETS + "WawaSC-Regular.otf"], 0, True),       # Wawati SC
    "hand_xing": ([_ASSETS + "Xingkai.ttc"], 2, True),              # Xingkai SC Light (cursive, hard)
    # handwriting-like Latin faces (no CJK glyphs: English lines only)
    "hand_bradley": ([_SUP + "Bradley Hand Bold.ttf"], 0, False),
    "hand_noteworthy": ([_SYS + "Noteworthy.ttc"], 0, False),
    "hand_marker": ([_SYS + "MarkerFelt.ttc"], 0, False),
    "hand_chalk": ([_SUP + "Chalkduster.ttf"], 0, False),
    # Latin text faces
    "helv": ([_SYS + "Helvetica.ttc"], 0, False),
    "helv_bold": ([_SYS + "Helvetica.ttc"], 1, False),
    "avenir": ([_SYS + "Avenir Next.ttc"], 2, False),
    "times": ([_SYS + "Times.ttc"], 0, False),
    "mono": ([_SYS + "Menlo.ttc"], 0, False),
    "mono_bold": ([_SYS + "Menlo.ttc"], 1, False),
}


@lru_cache(maxsize=None)
def resolve(key: str) -> tuple[str, int]:
    env = os.environ.get(f"EVAL_FONT_{key.upper()}")
    if env:
        path, _, idx = env.partition(":")
        return path, int(idx or 0)
    cands, index, _ = FACES[key]
    for pat in cands:
        hits = sorted(glob.glob(pat))
        if hits:
            return hits[0], index
    raise SystemExit(f"font '{key}' not found (looked for {cands}); set EVAL_FONT_{key.upper()}=/path[:index]")


USED: set[str] = set()  # every face key drawn with, for the manifest


@lru_cache(maxsize=None)
def font(key: str, size: int) -> ImageFont.FreeTypeFont:
    USED.add(key)
    path, index = resolve(key)
    return ImageFont.truetype(path, max(6, int(round(size))), index=index)


@lru_cache(maxsize=None)
def _cmap(key: str) -> frozenset[int]:
    from fontTools.ttLib import TTCollection, TTFont

    path, index = resolve(key)
    if path.lower().endswith((".ttc", ".otc")):
        tt = TTCollection(path, lazy=True).fonts[index]
    else:
        tt = TTFont(path, lazy=True)
    return frozenset(tt.getBestCmap().keys())


def has_glyphs(key: str, text: str) -> bool:
    cmap = _cmap(key)
    return all(ch.isspace() or ord(ch) in cmap for ch in text)


def check(key: str, text: str) -> str:
    """Return text unchanged, or raise if the face lacks a glyph for any visible character."""
    cmap = _cmap(key)
    missing = sorted({ch for ch in text if not ch.isspace() and ord(ch) not in cmap})
    if missing:
        raise ValueError(f"font {key} lacks glyphs {missing!r} for {text!r}")
    return text


def describe(keys) -> dict[str, str]:
    """key -> 'Family Style (file)' for the manifest."""
    out = {}
    for k in sorted(set(keys)):
        path, index = resolve(k)
        name = " ".join(font(k, 20).getname())
        out[k] = f"{name} ({os.path.basename(path)}#{index})"
    return out
