"""Write eval/files-multiformat/scenario-multiformat/scenario.json (+ scenario.dev.json / scenario.test.json) in the repo's scenario schema.

Called by build.py after the corpus is rendered (it needs each scenario file's corpus path). File items carry
`file` (asset path relative to the scenario directory), `filename`, `mime_type` and gold-only `file_truth`.
The dev/test split is by matter: ev_talk + ev_annot (+ the canteen menu) are dev, the other four matters test.
"""

from __future__ import annotations

import copy
import datetime as dt
import json
import os
import re
import uuid

import content_matters as CM

NS = uuid.UUID("6f2c1d4e-6a53-4f7e-9d3b-5b1d2f6a8c01")
IMAGE_TYPES = {"png", "jpg", "heic", "webp", "gif", "tiff", "bmp", "svg"}
VIDEO_TYPES = {"mp4", "mov"}
MIME = None
ROOT_OUT = [""]  # set by write()


def uid(name: str) -> str:
    return str(uuid.uuid5(NS, name)).upper()


def _kind(ftype: str) -> str:
    if ftype in IMAGE_TYPES:
        return "image"
    if ftype in VIDEO_TYPES:
        return "imported_media"
    return "document"


def build_full() -> tuple[dict, list[str]]:
    from build import MIME as _MIME
    errors = []
    people = []
    for p in CM.PEOPLE:
        pp = {k: v for k, v in p.items()}
        pp["voice"] = ({"mac_person_id": uid("voice-" + p["person_id"]), "user_label": "我"} if p.get("is_owner") else None)
        people.append(pp)
    events = [{k: v for k, v in e.items() if k != "split"} for e in CM.EVENTS]
    split_of_event = {e["event_id"]: e["split"] for e in CM.EVENTS}
    items = []
    for s in CM.FILES:
        if "_file_id" not in s:
            errors.append(f"scenario file {s['key']} was not rendered")
            continue
        split = s["_split"]
        it = {"item_id": uid(s["key"]), "ref": s["_file_id"], "t": s["t"], "kind": _kind(s["type"]), "source_app": s["source_app"],
              "persons": list(s["persons"]), "events": list(s["events"]),
              "tags": sorted(set(s.get("tags", [])) | {"file", f"file_type:{s['type']}", f"split:{split}"}),
              "filename": s["filename"], "file": "../" + s["_rel"], "mime_type": _MIME[s["type"]],
              "file_truth": "../" + s["_rel"].replace("corpus/", "truth/", 1).rsplit(".", 1)[0] + ".json"}
        with open(os.path.join(ROOT_OUT[0], it["file_truth"][3:]), encoding="utf-8") as fh:
            # gold only: lets eval/score.py ground claims in file content. Its matcher drops whitespace, so table cells
            # get a visible separator and a date keeps a comma before its time.
            txt = json.load(fh)["text"].replace("\t", " | ")
            it["file_text"] = re.sub(r"(\d{4}-\d{2}-\d{2}) (\d{1,2}:\d{2})", r"\1，\2", txt)
        items.append(it)
    for c in CM.CHATS:
        split = c.get("split") or split_of_event[c["events"][0]]
        items.append({"item_id": uid(c["key"]), "ref": c["key"], "t": c["t"], "kind": "text", "source_app": c["source_app"],
                      "persons": list(c["persons"]), "events": list(c["events"]),
                      "tags": sorted(set(c.get("tags", [])) | {"chat_paste", f"split:{split}"}), "text": c["text"]})
    items.sort(key=lambda it: (dt.datetime.fromisoformat(it["t"]), it["item_id"]))
    by_key = {s["key"]: uid(s["key"]) for s in CM.FILES}
    by_key.update({c["key"]: uid(c["key"]) for c in CM.CHATS})
    t_of = {it["item_id"]: dt.datetime.fromisoformat(it["t"]) for it in items}
    facts = []
    for fid, ev, text, keys, src, sup, state, date in CM.FACTS:
        f = {"fact_id": fid, "event_id": ev, "text": text, "keys": keys, "valid_from": by_key[src], "superseded_by": sup, "state": state}
        if date:
            f["date"] = date
        facts.append(f)
        it = next(i for i in items if i["item_id"] == by_key[src])
        if ev not in it["events"]:
            errors.append(f"fact {fid}: evidence item {src} is not labelled {ev}")
    fact_by_id = {f["fact_id"]: f for f in facts}
    checkpoints = []
    for cid, label, after, expected in CM.CHECKPOINTS:
        after_id = by_key[after] if after else items[-1]["item_id"]
        for ev, fids in expected.items():
            for f in fids:
                if t_of[fact_by_id[f]["valid_from"]] > t_of[after_id]:
                    errors.append(f"checkpoint {cid}: fact {f} is not yet valid")
                if fact_by_id[f]["event_id"] != ev:
                    errors.append(f"checkpoint {cid}: fact {f} belongs to another event")
        checkpoints.append({"checkpoint_id": cid, "after_item_id": after_id, "label": label, "expected": expected})
    sc = {"$schema": "../../schema/scenario.schema.json", "scenario_id": "files-multiformat-v1", "version": 1, "split": "holdout",
          "synthetic": True, "locale": "zh-CN", "title": "清屿大学视觉智能实验室 · 多格式文件周（合成）",
          "description": ("一周的实验室素材：43 个文件（33 种格式，每种至少 1 个）+ 7 条聊天粘贴，分属 6 件事和 3 条噪声。"
                          "文件条目用 file 指向 ../corpus 里的原文件（file_truth 是金标准，不发送）。按事件切分："
                          "ev_talk、ev_annot 与食堂菜单为 dev（scenario.dev.json），其余为 test（scenario.test.json）；"
                          "整份 scenario.json 含 test 素材，按 holdout 对待，不可据此调提示词。全部为合成数据。"),
          "owner_person_id": "p_owner", "people": people, "events": events, "items": items, "facts": facts, "checkpoints": checkpoints}
    return sc, errors


def subset(sc: dict, split: str) -> dict:
    s = copy.deepcopy(sc)
    keep_ev = {e["event_id"] for e in CM.EVENTS if e["split"] == split}
    s["scenario_id"] = f"files-multiformat-v1-{split}"
    s["split"] = "dev" if split == "dev" else "holdout"
    s["title"] += f"（{split}）"
    s["events"] = [e for e in s["events"] if e["event_id"] in keep_ev]
    s["items"] = [it for it in s["items"] if f"split:{split}" in it["tags"]]
    ids = {it["item_id"] for it in s["items"]}
    t_of = {it["item_id"]: dt.datetime.fromisoformat(it["t"]) for it in sc["items"]}
    s["facts"] = [f for f in s["facts"] if f["event_id"] in keep_ev and f["valid_from"] in ids]
    cps = []
    for cp in s["checkpoints"]:
        t = t_of[cp["after_item_id"]]
        cands = [it for it in s["items"] if t_of[it["item_id"]] <= t]
        if not cands:
            continue
        exp = {ev: f for ev, f in cp["expected"].items() if ev in keep_ev}
        if exp:
            cps.append(dict(cp, after_item_id=cands[-1]["item_id"], expected=exp))
    s["checkpoints"] = cps
    used = {p for it in s["items"] for p in it["persons"]} | {s["owner_person_id"]}
    s["people"] = [p for p in s["people"] if p["person_id"] in used]
    s["description"] = f"scenario.json 的 {split} 子集（按事件切分）。" + ("可用于调试。" if split == "dev" else "测试集：只评一次，不据此调提示词。")
    return s


def validate(sc: dict, schema_path: str) -> list[str]:
    try:
        import jsonschema
    except ImportError:
        return []
    if not os.path.exists(schema_path):  # building outside the repo (--out elsewhere)
        return []
    with open(schema_path, encoding="utf-8") as fh:
        schema = json.load(fh)
    v = jsonschema.Draft202012Validator(schema)
    return [f"{sc['scenario_id']}: {'/'.join(map(str, e.path))}: {e.message[:200]}" for e in v.iter_errors(sc)]


def write(root: str) -> list[str]:
    ROOT_OUT[0] = root
    sc, errors = build_full()
    d = os.path.join(root, "scenario-multiformat")
    os.makedirs(d, exist_ok=True)
    schema_path = os.path.join(os.path.dirname(root), "schema", "scenario.schema.json")
    for name, obj in (("scenario.json", sc), ("scenario.dev.json", subset(sc, "dev")), ("scenario.test.json", subset(sc, "test"))):
        errors += validate(obj, schema_path)
        with open(os.path.join(d, name), "w", encoding="utf-8") as fh:
            json.dump(obj, fh, ensure_ascii=False, indent=1)
            fh.write("\n")
        print(f"{name}: {len(obj['items'])} items, {len(obj['events'])} events, {len(obj['facts'])} facts, {len(obj['checkpoints'])} checkpoints")
    for it in sc["items"]:
        if "file" in it and not os.path.exists(os.path.normpath(os.path.join(d, it["file"]))):
            errors.append(f"missing asset {it['file']}")
    return errors
