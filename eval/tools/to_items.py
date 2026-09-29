#!/usr/bin/env python3
"""scenario.json -> organizer API items (JSON Lines, time order), the way the Mac would send them.

Gold labels (events, persons, facts, tags, ref) never leave this script. Speakers become the Mac's
voice identities: segment.person_id = people[].voice.mac_person_id and item.persons carries the name the
user gave that voice (or no name when it is still unnamed). Screenshots are sent as PNG bytes only.

  python3 tools/to_items.py scenarios/dev-week-v1/scenario.json -o /tmp/dev-items.jsonl

Matches spark/organizer/schemas.py Item: item_id, revision, kind, source_app{name}, started_at,
ended_at, text, segments[{start_ms,end_ms,person_id,text}], persons[{person_id,display_name}],
image_b64, sha256.

File items (item.file, e.g. eval/files-multiformat/scenario-multiformat) are sent in the organizer's file contract:
a PNG/JPEG image stays kind=image with image_b64; any other file becomes kind=file with filename, mime, size and
bytes_b64 (the original bytes), and the typed caption, if any, as text. --file-text gold instead keeps the scenario
kind and puts the file's ground-truth text into `text` without the file bytes (an oracle-reading upper bound; report it as such).
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import sys
from datetime import datetime, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

def _load(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def _sorted_items(scenario: dict) -> list[dict]:
    indexed = list(enumerate(scenario["items"]))
    indexed.sort(key=lambda pair: (datetime.fromisoformat(pair[1]["t"]), pair[0]))
    return [it for _, it in indexed]


def _png_bytes(scenario_path: str, item: dict, render_missing: bool) -> bytes:
    import render_screenshots  # local module; needs Pillow only when a PNG has to be drawn

    path = render_screenshots.asset_path(scenario_path, item)
    if not os.path.exists(path):
        if not render_missing:
            raise SystemExit(f"missing {path}; run tools/render_screenshots.py first")
        render_screenshots.render(item["image"], path)
    with open(path, "rb") as fh:
        return fh.read()


def _sha256(api_item: dict, image: bytes | None, file_bytes: bytes | None = None) -> str:
    h = hashlib.sha256()
    h.update(api_item["kind"].encode())
    h.update(json.dumps({k: api_item.get(k) for k in ("text", "segments")}, ensure_ascii=False, sort_keys=True).encode())
    if image:
        h.update(image)
    if file_bytes and file_bytes is not image:
        h.update(file_bytes)
    return h.hexdigest()


def _file_fields(scenario_path: str, item: dict, file_text: str) -> tuple[dict, bytes]:
    base = os.path.dirname(os.path.abspath(scenario_path))
    with open(os.path.normpath(os.path.join(base, item["file"])), "rb") as fh:
        raw = fh.read()
    out = {"filename": item.get("filename") or os.path.basename(item["file"]),
           "mime": item.get("mime_type") or "application/octet-stream"}
    text = item.get("text")  # a caption the user typed with the file
    if file_text == "gold":
        gold = item.get("file_text")
        if gold is None:
            with open(os.path.normpath(os.path.join(base, item["file_truth"])), encoding="utf-8") as fh:
                gold = json.load(fh)["text"]
        text = f"{out['filename']}\n\n{gold}" + (f"\n\n{text}" if text else "")
    elif not (item["kind"] == "image" and (raw.startswith(b"\x89PNG") or raw.startswith(b"\xff\xd8"))):
        out.update(kind="file", size=len(raw), bytes_b64=base64.b64encode(raw).decode("ascii"))
    if text:
        out["text"] = text
    return out, raw


def build_items(scenario_path: str, render_missing: bool = True, file_text: str = "none") -> list[dict]:
    scenario = _load(scenario_path)
    people = {p["person_id"]: p for p in scenario["people"]}

    def voice(pid: str) -> dict:
        v = people[pid].get("voice")
        if not v:
            raise SystemExit(f"{pid} speaks but has no voice in people[]")
        return v

    out = []
    for item in _sorted_items(scenario):
        kind = item["kind"]
        api = {"item_id": item["item_id"], "revision": 0, "kind": kind,
               "source_app": {"name": item["source_app"]}, "started_at": item["t"]}
        start = datetime.fromisoformat(item["t"])
        speakers: list[str] = []
        image = file_bytes = None
        if item.get("file"):
            fields, file_bytes = _file_fields(scenario_path, item, file_text)
            api.update(fields)
            if api["kind"] == "image" and (file_bytes.startswith(b"\x89PNG") or file_bytes.startswith(b"\xff\xd8")):
                image = file_bytes
                api["image_b64"] = base64.b64encode(image).decode("ascii")
        elif kind in ("meeting_online", "meeting_offline", "imported_media") and item.get("segments"):
            api["segments"] = [{"start_ms": s["start_ms"], "end_ms": s["end_ms"],
                                "person_id": voice(s["person_id"])["mac_person_id"], "text": s["text"]}
                               for s in item["segments"]]
            speakers = [s["person_id"] for s in item["segments"]]
            api["ended_at"] = (start + timedelta(milliseconds=item["segments"][-1]["end_ms"])).isoformat()
        elif kind == "dictation":
            owner = scenario["owner_person_id"]
            dur = int(item.get("duration_ms") or 3000)
            api["text"] = item["text"]
            api["segments"] = [{"start_ms": 0, "end_ms": dur, "person_id": voice(owner)["mac_person_id"],
                                "text": item["text"]}]
            speakers = [owner]
            api["ended_at"] = (start + timedelta(milliseconds=dur)).isoformat()
        elif kind == "document":
            api["text"] = f"{item['filename']}\n\n{item['text']}" if item.get("filename") else item["text"]
        elif kind == "image":
            image = _png_bytes(scenario_path, item, render_missing)
            api["image_b64"] = base64.b64encode(image).decode("ascii")
            if item.get("text"):
                api["text"] = item["text"]  # the caption the user typed with the screenshot
        else:
            api["text"] = item["text"]
        if speakers:
            persons, seen = [], set()
            for pid in speakers:
                v = voice(pid)
                if v["mac_person_id"] in seen:
                    continue
                seen.add(v["mac_person_id"])
                ref = {"person_id": v["mac_person_id"]}
                if v.get("user_label"):
                    ref["display_name"] = v["user_label"]
                persons.append(ref)
            api["persons"] = persons
        api["sha256"] = _sha256(api, image, file_bytes)
        out.append(api)
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("scenario")
    ap.add_argument("-o", "--out", help="output .jsonl (default: stdout)")
    ap.add_argument("--no-render", action="store_true", help="fail instead of rendering a missing PNG")
    ap.add_argument("--file-text", choices=["none", "gold"], default="none",
                    help="gold: also send each file item's ground-truth text as `text` (oracle reading)")
    args = ap.parse_args(argv)
    items = build_items(args.scenario, render_missing=not args.no_render, file_text=args.file_text)
    fh = open(args.out, "w", encoding="utf-8") if args.out else sys.stdout
    try:
        for it in items:
            fh.write(json.dumps(it, ensure_ascii=False) + "\n")
    finally:
        if args.out:
            fh.close()
    if args.out:
        kinds: dict[str, int] = {}
        for it in items:
            kinds[it["kind"]] = kinds.get(it["kind"], 0) + 1
        print(f"{args.out}: {len(items)} items {kinds}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
