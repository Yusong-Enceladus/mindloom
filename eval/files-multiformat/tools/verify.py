#!/usr/bin/env python3
"""Check the file-reading eval set without any model: every file parses with plain (non-ML) readers, the truth's key
lines are in each text layer, image-only files really have no text layer, structure claims hold (sheets, merged cells,
cached formulas, picture-only slides, GIF frames, video length/audio, nested zips, attachments), hashes match, and the
multi-format scenario validates against eval/schema/scenario.schema.json.

  python eval/files-multiformat/tools/verify.py            # exit 1 on any failure
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import extract as X  # noqa: E402

ROOT = os.path.dirname(HERE)


def ffprobe(path: str) -> dict:
    import imageio_ffmpeg
    exe = imageio_ffmpeg.get_ffmpeg_exe()
    r = subprocess.run([exe, "-hide_banner", "-i", path], capture_output=True, text=True)
    err = r.stderr
    m = re.search(r"Duration: (\d+):(\d+):([\d.]+)", err)
    dur = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3)) if m else None
    return {"duration": dur, "video": "Video: h264" in err, "audio": "Audio:" in err}


def check(entry: dict, truth: dict, tmp: str) -> list[str]:
    errs = []
    path = os.path.join(ROOT, entry["path"])
    ftype = entry["type"]
    with open(path, "rb") as fh:
        data = fh.read()
    if hashlib.sha256(data).hexdigest() != truth["sha256"]:
        errs.append("sha256 mismatch")
    st = truth.get("structure", {})
    text, info = "", {}
    if ftype not in X.IMAGE_LIKE:
        text, info = X.extract(path, ftype, tmp)
    ntext = X.norm(text)
    if truth["text_layer"] in ("full", "partial"):
        for line in truth["key_lines"]:
            if line in truth.get("picture_only_lines", []):
                continue
            if X.norm(line) not in ntext:
                errs.append(f"key line not in text layer: {line[:80]}")
    if ftype == "pdf_scanned":
        if text.strip():
            errs.append("scanned PDF has a text layer")
        if info.get("images", 0) < 1:
            errs.append("scanned PDF has no page images")
    if ftype in ("xlsx", "ods"):
        if len(info["sheets"]) < 2:
            errs.append("fewer than 2 sheets")
        if info["merged_ranges"] < 1:
            errs.append("no merged cells")
        if info["formulas"] < 1 or info["formulas_without_cache"]:
            errs.append(f"formulas {info['formulas']}, without cached value {info['formulas_without_cache']}")
    if ftype in ("pptx", "odp"):
        if info["picture_only_slides"] != st.get("picture_only_slides"):
            errs.append(f"picture-only slides {info['picture_only_slides']} != truth {st.get('picture_only_slides')}")
        if ftype == "pptx" and not info["picture_only_slides"]:
            errs.append("pptx has no picture-only slide")
    if ftype == "gif":
        from PIL import Image
        im = Image.open(path)
        frames = []
        for i in range(im.n_frames):
            im.seek(i)
            frames.append(hashlib.md5(im.convert("RGB").tobytes()).hexdigest())
        if len(frames) != 3 or len(set(frames)) != 3:
            errs.append(f"GIF frames {len(frames)} distinct {len(set(frames))}")
    if ftype in ("mp4", "mov"):
        p = ffprobe(path)
        if not p["video"] or p["duration"] is None or abs(p["duration"] - st["duration_s"]) > 0.6:
            errs.append(f"video probe {p} vs {st.get('duration_s')}")
        if p["audio"] != (st.get("audio") == "silent AAC"):
            errs.append(f"audio track {p['audio']} vs {st.get('audio')}")
    if ftype == "heic":
        r = subprocess.run(["/usr/bin/sips", "-g", "format", path], capture_output=True, text=True)
        if "heic" not in r.stdout:
            errs.append("not HEIC per sips")
    if ftype in ("png", "jpg", "webp", "bmp", "tiff"):
        from PIL import Image
        im = Image.open(path)
        im.load()
        if ftype == "tiff" and im.n_frames != st.get("pages"):
            errs.append(f"tiff pages {im.n_frames} != {st.get('pages')}")
        want = {"png": "PNG", "jpg": "JPEG", "webp": "WEBP", "bmp": "BMP", "tiff": "TIFF"}[ftype]
        if im.format != want:
            errs.append(f"format {im.format}")
    if ftype == "svg":
        import xml.dom.minidom
        xml.dom.minidom.parseString(data)
    if ftype == "zip":
        if sorted(info["members"]) != sorted(st["members"]):
            errs.append("zip member list differs")
    if ftype in ("eml", "mbox"):
        if info.get("attachments", []) != st.get("attachments", []):
            errs.append(f"attachments {info.get('attachments')} != {st.get('attachments')}")
    if ftype == "epub":
        with zipfile.ZipFile(path) as z:
            first = z.infolist()[0]
            if first.filename != "mimetype" or first.compress_type != zipfile.ZIP_STORED:
                errs.append("epub mimetype is not the first stored entry")
    if ftype == "webarchive":
        r = subprocess.run(["/usr/bin/plutil", "-lint", path], capture_output=True, text=True)
        if r.returncode:
            errs.append("plutil -lint failed")
        if not info.get("subresources"):
            errs.append("no subresources")
    if "合成数据" not in truth["text"] and "synthetic" not in truth["text"].lower():
        errs.append("no visible synthetic-data mark")
    return errs


def check_scenarios() -> list[str]:
    errs = []
    schema_path = os.path.join(os.path.dirname(ROOT), "schema", "scenario.schema.json")
    try:
        import jsonschema
        with open(schema_path, encoding="utf-8") as fh:
            validator = jsonschema.Draft202012Validator(json.load(fh))
    except ImportError:
        validator = None
        errs.append("jsonschema not installed: scenario schema NOT checked")
    with open(os.path.join(ROOT, "manifest.json"), encoding="utf-8") as fh:
        man = {e["file_id"]: e for e in json.load(fh)["entries"]}
    d = os.path.join(ROOT, "scenario-multiformat")
    for name in ("scenario.json", "scenario.dev.json", "scenario.test.json"):
        with open(os.path.join(d, name), encoding="utf-8") as fh:
            sc = json.load(fh)
        if validator:
            errs += [f"{name}: {'/'.join(map(str, e.path))}: {e.message[:160]}" for e in validator.iter_errors(sc)]
        evs = {e["event_id"] for e in sc["events"]}
        for it in sc["items"]:
            if not set(it["events"]) <= evs:
                errs.append(f"{name}: {it['ref']} has events outside the scenario")
            if "file" in it:
                if not os.path.exists(os.path.normpath(os.path.join(d, it["file"]))):
                    errs.append(f"{name}: missing {it['file']}")
                m = man.get(it["ref"])
                if not m or f"split:{m['split']}" not in it["tags"]:
                    errs.append(f"{name}: split tag of {it['ref']} disagrees with the manifest")
    return errs


def main() -> int:
    with open(os.path.join(ROOT, "manifest.json"), encoding="utf-8") as fh:
        man = json.load(fh)
    tmp = tempfile.mkdtemp(prefix="verify")
    fails, per_type = 0, {}
    for e in man["entries"]:
        with open(os.path.join(ROOT, e["truth"]), encoding="utf-8") as fh:
            truth = json.load(fh)
        try:
            errs = check(e, truth, tmp)
        except Exception as exc:  # noqa: BLE001 - report and continue
            errs = [f"{type(exc).__name__}: {exc}"]
        t = per_type.setdefault(e["type"], {"files": 0, "dev": 0, "test": 0, "qa": 0, "failed": 0, "layer": set()})
        t["files"] += 1
        t[e["split"]] += 1
        t["qa"] += len(truth["qa"])
        t["layer"].add(truth["text_layer"])
        if errs:
            fails += 1
            t["failed"] += 1
            for x in errs:
                print(f"FAIL {e['file_id']}: {x}")
    scen = check_scenarios()
    for x in scen:
        print(f"FAIL scenario: {x}")
    print(f"\n{'type':12s} files dev test  qa  text-layer      failed")
    for ft, t in per_type.items():
        print(f"{ft:12s} {t['files']:5d} {t['dev']:3d} {t['test']:4d} {t['qa']:3d}  {','.join(sorted(t['layer'])):14s} {t['failed']}")
    n = len(man["entries"])
    print(f"\n{n} files, {fails} failed; scenario problems: {len(scen)}")
    return 1 if fails or scen else 0


if __name__ == "__main__":
    sys.exit(main())
