#!/usr/bin/env python3
"""Render a captured terminal transcript as a frame sequence (and, with ffmpeg, an mp4) for the S3 shot.

This is a re-rendering of text that a real run printed, with the real inter-line timings; it is not a screen
capture, and the film should say so if it is used as one. Input lines look like `<seconds since start>\\t<text>`
(ops/step3_shot.sh capture writes that). Hostnames, addresses, user names and paths must not be in the text:
step3_shot.py prints none.

  python3 ops/render_terminal_frames.py transcript.tsv out_dir [--fps 10] [--mp4 out.mp4] [--speed 1.0]
"""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H, PAD, LINE = 1920, 1080, 64, 44
BG, FG, DIM, GREEN, CYAN = (14, 17, 22), (222, 226, 232), (130, 138, 150), (120, 220, 140), (110, 200, 235)
CJK = "/System/Library/Fonts/STHeiti Medium.ttc"
MONO = "/System/Library/Fonts/Menlo.ttc"


def font(size: int) -> ImageFont.FreeTypeFont:
    for path in (CJK, MONO):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def colour(text: str) -> tuple:
    if "Step3-VL" in text and "→" in text and text.lstrip().startswith("["):
        return GREEN
    if "Qwen3.6" in text and "→" in text and text.lstrip().startswith("["):
        return CYAN
    if text.startswith(("读图计数", "织机整理器")):
        return FG
    return DIM if text.startswith("          类型") else FG


def render(lines: list[tuple[float, str]], upto: float, f) -> Image.Image:
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    shown = [t for s, t in lines if s <= upto]
    visible = shown[-((H - 2 * PAD) // LINE):]
    for i, text in enumerate(visible):
        d.text((PAD, PAD + i * LINE), text, font=f, fill=colour(text))
    if int(upto * 2) % 2 == 0:
        d.rectangle((PAD, PAD + len(visible) * LINE + 4, PAD + 18, PAD + len(visible) * LINE + LINE - 6), fill=FG)
    return img


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("transcript")
    ap.add_argument("out_dir")
    ap.add_argument("--fps", type=int, default=10)
    ap.add_argument("--speed", type=float, default=1.0, help="1.0 = the real timing")
    ap.add_argument("--tail", type=float, default=2.0, help="seconds to hold the last frame")
    ap.add_argument("--mp4", default="")
    a = ap.parse_args()
    lines = []
    for raw in Path(a.transcript).read_text(encoding="utf-8").splitlines():
        sec, _, text = raw.partition("\t")
        lines.append((float(sec) / a.speed, text))
    out = Path(a.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    f = font(30)
    total = lines[-1][0] + a.tail
    n = int(total * a.fps) + 1
    for i in range(n):
        render(lines, i / a.fps, f).save(out / f"frame_{i:04d}.png")
    print(f"{n} frames, {n / a.fps:.1f} s at {a.fps} fps -> {out}")
    if a.mp4:
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(a.fps), "-i", str(out / "frame_%04d.png"),
                        "-pix_fmt", "yuv420p", a.mp4], check=True)
        print(a.mp4)


if __name__ == "__main__":
    main()
