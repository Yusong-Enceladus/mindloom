#!/usr/bin/env python3
"""Does masking change organizing quality? One organizing run with masking off or on, plus the checks.

Runs eval/run_eval.py (condition `skills`, the shipped organizer, same flags as the model comparison) on a
scenario with one of two masking conditions:

  off  nothing is masked anywhere: items go out as written and the Spark-side masking (organizer/store.py
       Store.mask_text / Store.mask_obj: intake, image and file readings, audit rows) is patched to identity
       in this process. This is the organizer as it behaved before privacy contract v6.
  on   the Mac side is simulated: every text field of every item (text, segment text, file name, person
       display names) is passed through organizer.masking.mask() with the library's mask key before it is
       posted, and the placeholder -> original map is kept here, as the Mac keeps it in remote_mask_map.
       The Spark-side masking runs as implemented (it is idempotent on Mac-masked text).

Both conditions unlock with the fixed synthetic library key, so the mask key is the same one the Spark derives.

After the run it writes <out>/mask_report.json:
  wire         identifiers (from --identifiers) still readable in the posted payload, per format
  prompts      identifiers readable in any model or embedding request the Spark made
  store        identifiers readable in the Spark store after the run (decrypted with the synthetic key)
  outputs      every placeholder found in what comes back (titles, status lines, facts, reasons, gists,
               questions, person names, readings), per field, each checked against the Mac map:
               resolved / unknown tag / untagged / malformed; resolved ones are also checked for attribution
               (the original value occurs in one of the event's own items); plus raw identifiers in outputs
  shadow       (--shadow, mask on only) paired calls with the context held fixed: every event-assign,
               event-brief and item-split call whose prompt carries a placeholder is also sent unmasked
               (placeholders replaced by their originals) and sent masked a second time; decisions and
               card facts are compared masked vs unmasked and masked vs masked replay (server noise)
  scores       score.py summary on the raw snapshots (what the Spark holds) and on the unmasked snapshots
               (what the Mac shows after unmask()); both are also written as score.json / score_unmasked.json

  python3 eval/privacy/run_mask_eval.py --scenario S --mask on --identifiers DIR/identifiers.json \
      --out OUT --llm-url http://127.0.0.1:8000/v1 --embed-url http://127.0.0.1:8013/v1
Synthetic scenarios only (run_eval.py refuses anything else).
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import shutil
import sys
import threading
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Optional

HERE = Path(__file__).resolve().parent
EVAL = HERE.parent
ROOT = EVAL.parent
sys.path.insert(0, str(ROOT / "spark"))
sys.path.insert(0, str(EVAL / "tools"))
sys.path.insert(0, str(EVAL))

import run_eval  # noqa: E402
import score as scorer  # noqa: E402
import to_items  # noqa: E402
from organizer import clients as org_clients  # noqa: E402
from organizer import db as org_db  # noqa: E402
from organizer import masking  # noqa: E402
from organizer.keys import derive_keys, synthetic_library_key  # noqa: E402
from organizer.store import Store  # noqa: E402

MASK_KEY = derive_keys(synthetic_library_key())[2]
LOOSE_BRACKET = re.compile("〔[^〔〕\n]{0,24}〕")
LABELS = "|".join(re.escape(v) for v in masking.LABELS.values())
BARE_TAG = re.compile(f"(?:{LABELS})·[0-9a-f]{{2,6}}")
STRICT = masking.PLACEHOLDER_RX


# ------------------------------------------------------------------------------------------ identifiers

def squash(text: str) -> str:
    return re.sub(r"[\s\-]", "", text or "").lower()


class Needles:
    """Inserted identifier values, searched in normalized text (spaces and dashes removed, lower case)."""

    def __init__(self, path: Optional[str]):
        self.rows: list[dict] = []
        if path:
            self.rows = json.loads(Path(path).read_text(encoding="utf-8"))["occurrences"]
        self.values: dict[str, dict] = {}
        for r in self.rows:
            alts = {squash(r["surface"])}
            if r["type"] == "phone":  # also found without its country code (+86 / +65 / +61)
                alts.add(r["normalized"][2:] if r["format"].startswith(("sg", "au")) else r["normalized"])
            v = self.values.setdefault(r["slot"], {"type": r["type"], "format": r["format"], "alts": set()})
            v["alts"] |= alts
            if r["type"] == "otp":  # short codes: whole digit runs only, on the text as written
                v["rx"] = re.compile(r"(?<![0-9])" + re.escape(r["surface"]) + r"(?![0-9])")

    def found(self, text: str) -> list[str]:
        s = squash(text)
        return [slot for slot, v in self.values.items()
                if (v["rx"].search(text or "") if "rx" in v else any(a in s for a in v["alts"]))]


# ------------------------------------------------------------------------------------------ Mac side

class MacMasker:
    """Masks payload text the way the Mac does and keeps placeholder -> original."""

    def __init__(self):
        self.map: dict[str, str] = {}
        self.spans: Counter = Counter()

    def text(self, value: Optional[str]) -> Optional[str]:
        if not value:
            return value
        out, spans = masking.mask(value, MASK_KEY)[:2]
        for s in spans:
            self.map.setdefault(s["placeholder"], s["original"])
            self.spans[s["type"]] += 1
        return out

    def item(self, item: dict) -> dict:
        item = copy.deepcopy(item)
        for key in ("text", "filename"):
            if item.get(key):
                item[key] = self.text(item[key])
        for seg in item.get("segments") or []:
            seg["text"] = self.text(seg["text"])
        for p in item.get("persons") or []:
            if p.get("display_name"):
                p["display_name"] = self.text(p["display_name"])
        image = None
        if item.get("image_b64"):
            import base64
            image = base64.b64decode(item["image_b64"])
        item["sha256"] = to_items._sha256(item, image)  # of what is actually sent
        return item


# ------------------------------------------------------------------------------------------ request taps

class Tap:
    def __init__(self, needles: Needles):
        self.needles = needles
        self.lock = threading.Lock()
        self.chat_calls = self.embed_calls = 0
        self.chat_hits: Counter = Counter()
        self.embed_hits: Counter = Counter()

    def chat(self, messages) -> None:
        parts = []
        for m in messages:
            c = m.get("content")
            if isinstance(c, str):
                parts.append(c)
            elif isinstance(c, list):
                parts += [p.get("text", "") for p in c if p.get("type") == "text"]
        hits = self.needles.found("\n".join(parts))
        with self.lock:
            self.chat_calls += 1
            self.chat_hits.update(hits)

    def embed(self, texts) -> None:
        hits = set()
        for t in texts:
            hits |= set(self.needles.found(t))
        with self.lock:
            self.embed_calls += 1
            self.embed_hits.update(hits)


def install_taps(tap: Tap) -> None:
    base_chat = org_clients.OpenAIChatClient
    base_embed = org_clients.OpenAIEmbedClient

    class TappedChat(base_chat):
        def complete(self, messages, *a, **k):
            tap.chat(messages)
            return super().complete(messages, *a, **k)

    class TappedEmbed(base_embed):
        def embed(self, texts):
            tap.embed(texts)
            return super().embed(texts)

    run_eval.OpenAIChatClient = TappedChat
    org_clients.OpenAIEmbedClient = TappedEmbed  # run_eval.main imports it from organizer.clients at call time


def disable_spark_masking() -> None:
    Store.mask_text = lambda self, text: text
    Store.mask_obj = lambda self, value: value


# ------------------------------------------------------------------------------------------ shadow calls

SHADOW_JOBS = ("event_assign", "event_brief", "item_split")


def map_messages(messages, fn):
    out = []
    for m in messages:
        c = m.get("content")
        if isinstance(c, str):
            c = fn(c)
        elif isinstance(c, list):
            c = [dict(p, text=fn(p["text"])) if p.get("type") == "text" else p for p in c]
        out.append(dict(m, content=c))
    return out


def has_placeholder(messages) -> bool:
    found = []
    map_messages(messages, lambda t: found.append(bool(STRICT.search(t))) or t)
    return any(found)


class Shadow:
    """Paired calls: the masked prompt as sent, the same prompt unmasked, and the masked prompt again."""

    def __init__(self, mac: "MacMasker", scenario: dict, needles: "Needles"):
        self.mac, self.facts, self.needles = mac, scenario.get("facts", []), needles
        self.rows: list[dict] = []  # written to <out>/shadow.jsonl after the run (run_eval wants a fresh --out)
        self.lock = threading.Lock()

    def summary_of(self, job: str, text: str) -> dict:
        try:
            o = json.loads(text)
        except (TypeError, ValueError):
            return {"parse_error": True}
        if job == "event_assign":
            return {"decision": o.get("decision"), "event_id": o.get("event_id") or ""}
        if job == "event_brief":
            card = masking.unmask("\n".join([o.get("title") or "", o.get("status_line") or ""]
                                           + [str(f.get("text", "")) for f in o.get("status_facts") or []]), self.mac.map)
            return {"title": masking.unmask(o.get("title") or "", self.mac.map),
                    "facts": sorted(f["fact_id"] for f in self.facts if scorer.fact_matches(f["keys"], card)),
                    # identifiers readable on the card after unmask (for the unmasked prompt: as written)
                    "identifiers_on_card": sorted(self.needles.found(card)),
                    "placeholders_in_output": len(LOOSE_BRACKET.findall(o.get("status_line") or "")
                                                  + LOOSE_BRACKET.findall(o.get("title") or "")
                                                  + [x for f in o.get("status_facts") or []
                                                     for x in LOOSE_BRACKET.findall(str(f.get("text", "")))])}
        if job == "item_split":
            segs = o.get("segments") or []
            return {"n_matters": len(o.get("matters") or []),
                    "bounds": [[g.get("from"), g.get("to"), g.get("matter")] for g in segs]}
        return {}

    def record(self, job: str, sent: str, unmasked: str, replay: str) -> None:
        row = {"job": job, "sent": self.summary_of(job, sent), "unmasked": self.summary_of(job, unmasked),
               "replay": self.summary_of(job, replay)}
        with self.lock:
            self.rows.append(row)

    def report(self) -> dict:
        out = {}
        for job in SHADOW_JOBS:
            rows = [r for r in self.rows if r["job"] == job]
            if not rows:
                continue
            key = (lambda s: (s.get("decision"), s.get("event_id"))) if job == "event_assign" else \
                (lambda s: tuple(s.get("facts") or [])) if job == "event_brief" else \
                (lambda s: (s.get("n_matters"), json.dumps(s.get("bounds"))))
            same_un = sum(1 for r in rows if key(r["sent"]) == key(r["unmasked"]))
            same_rep = sum(1 for r in rows if key(r["sent"]) == key(r["replay"]))
            entry = {"calls": len(rows), "same_as_unmasked": same_un, "same_as_replay": same_rep}
            if job == "event_brief":
                entry["facts_sent"] = sum(len(r["sent"].get("facts") or []) for r in rows)
                entry["facts_unmasked"] = sum(len(r["unmasked"].get("facts") or []) for r in rows)
                entry["facts_replay"] = sum(len(r["replay"].get("facts") or []) for r in rows)
                entry["placeholders_in_sent_outputs"] = sum(r["sent"].get("placeholders_in_output") or 0 for r in rows)
                for side in ("sent", "unmasked", "replay"):
                    entry[f"identifiers_on_card_{side}"] = sum(len(r[side].get("identifiers_on_card") or []) for r in rows)
                    entry[f"calls_with_identifier_on_card_{side}"] = sum(
                        1 for r in rows if r[side].get("identifiers_on_card"))
            if job == "event_assign":
                entry["decision_same_as_unmasked"] = sum(1 for r in rows if r["sent"].get("decision") == r["unmasked"].get("decision"))
                entry["decision_same_as_replay"] = sum(1 for r in rows if r["sent"].get("decision") == r["replay"].get("decision"))
            out[job] = entry
        return out


def install_shadow(shadow: Shadow) -> None:
    tapped = run_eval.OpenAIChatClient
    plain = org_clients.OpenAIChatClient.complete  # not tapped: shadow calls are not what the Spark was sent

    class ShadowChat(tapped):
        def complete(self, messages, schema, schema_name, max_tokens):
            res = super().complete(messages, schema, schema_name, max_tokens)
            if schema_name in SHADOW_JOBS and has_placeholder(messages):
                un = plain(self, map_messages(messages, lambda t: masking.unmask(t, shadow.mac.map)), schema,
                           schema_name, max_tokens)
                rep = plain(self, messages, schema, schema_name, max_tokens)
                shadow.record(schema_name, res.text, un.text, rep.text)
            return res

    run_eval.OpenAIChatClient = ShadowChat


# ------------------------------------------------------------------------------------------ output audit

EVENT_FIELDS = ("title", "status_line", "importance_reason", "anchor")


def output_strings(state: dict):
    """(field, event_id or None, text) for every string the Mac shows from a /v1/state snapshot."""
    for e in state.get("events", []):
        if e.get("deleted") or e.get("merged_into"):
            continue
        for f in EVENT_FIELDS:
            if isinstance(e.get(f), str) and e[f]:
                yield f, e["event_id"], e[f]
        for fact in e.get("status_facts") or []:
            t = fact.get("text") if isinstance(fact, dict) else str(fact)
            if t:
                yield "fact", e["event_id"], t
        for s in e.get("segments") or []:
            if s.get("gist"):
                yield "segment_gist", e["event_id"], s["gist"]
    for q in state.get("questions", []):
        if q.get("prompt_zh"):
            yield "question", None, q["prompt_zh"]
    for p in state.get("persons", []):
        for t in [p.get("display_name")] + list(p.get("aliases") or []):
            if isinstance(t, str) and t:
                yield "person", None, t
    for u in state.get("unfiled", []):
        if u.get("gist"):
            yield "unfiled_gist", None, u["gist"]
    for iid, r in (state.get("readings") or {}).items():
        for t in _strings(r):
            yield "reading", None, t


def _strings(v: Any):
    if isinstance(v, str):
        yield v
    elif isinstance(v, dict):
        for x in v.values():
            yield from _strings(x)
    elif isinstance(v, list):
        for x in v:
            yield from _strings(x)


def tag_patterns(mac_map: dict) -> list:
    """One regex per known tag: the 6 hex characters of a placeholder, standing on their own."""
    tags = sorted({ph.split("·", 1)[1][:-1] for ph in mac_map if "·" in ph})
    return [(t, re.compile(r"(?<![0-9A-Fa-f])" + t + r"(?![0-9A-Fa-f])")) for t in tags]


def mangled_tags(text: str, patterns: list) -> list[str]:
    """Known tags left in the text outside a well-formed placeholder: a placeholder the model broke
    (brackets or label dropped, e.g. 验证码3feb18), which the Mac cannot restore."""
    rest = STRICT.sub("", text)
    return [t for t, rx in patterns if rx.search(rest)]


def audit_state(state: dict, mac_map: dict, needles: Needles, item_raw: dict) -> dict:
    """Placeholders and raw identifiers in one snapshot's outputs."""
    patterns = tag_patterns(mac_map)
    by_field: dict[str, Counter] = defaultdict(Counter)
    examples: list[dict] = []
    attribution = Counter()
    raw_hits: dict[str, Counter] = defaultdict(Counter)
    events = {e["event_id"]: e for e in state.get("events", [])}
    for field, eid, text in output_strings(state):
        for m in LOOSE_BRACKET.finditer(text):
            ph = m.group(0)
            if ph in mac_map:
                kind = "resolved"
                if eid:
                    member_text = squash("\n".join(item_raw.get(i.lower(), "") for i in events[eid]["item_ids"]))
                    attribution["in_own_event" if squash(mac_map[ph]) in member_text else "not_in_own_event"] += 1
            elif STRICT.fullmatch(ph):
                kind = "unknown_tag" if "·" in ph else "untagged"
            else:
                kind = "malformed"
            by_field[field][kind] += 1
            if kind != "resolved" and len(examples) < 20:
                examples.append({"field": field, "kind": kind, "token": ph})
        stripped = LOOSE_BRACKET.sub("", text)
        for m in BARE_TAG.finditer(stripped):  # a label·tag whose brackets were dropped or broken
            by_field[field]["broken_brackets"] += 1
            if len(examples) < 20:
                examples.append({"field": field, "kind": "broken_brackets", "token": m.group(0)})
        for t in mangled_tags(text, patterns):
            by_field[field]["mangled"] += 1
            if len(examples) < 20:
                examples.append({"field": field, "kind": "mangled", "token": t, "text": text[:80]})
        for slot in needles.found(stripped):
            raw_hits[field][needles.values[slot]["type"]] += 1
    total = Counter()
    for c in by_field.values():
        total.update(c)
    return {"placeholders": dict(total), "placeholders_by_field": {k: dict(v) for k, v in by_field.items()},
            "attribution": dict(attribution), "raw_identifiers_by_field": {k: dict(v) for k, v in raw_hits.items()},
            "raw_identifiers": sum(sum(c.values()) for c in raw_hits.values()), "examples": examples}


def audit_runs(path: Path, mac_map: dict, needles: Needles) -> Optional[dict]:
    """Every model output the Spark recorded (runs.jsonl: assign, brief, split, rank, readings, incl. cards
    that were later rewritten), checked like the snapshots."""
    if not path.exists():
        return None
    patterns = tag_patterns(mac_map)
    per: dict[str, Counter] = defaultdict(Counter)
    examples: list[dict] = []
    for line in path.open(encoding="utf-8"):
        row = json.loads(line)
        out = row.get("output")
        if out is None:
            continue
        job = row.get("job_type") or "?"
        per[job]["outputs"] += 1
        texts = list(_strings(out)) if not isinstance(out, str) else [out]
        seen = Counter()
        for text in texts:
            for m in LOOSE_BRACKET.finditer(text):
                ph = m.group(0)
                kind = "resolved" if ph in mac_map else ("unknown_tag" if STRICT.fullmatch(ph) and "·" in ph
                                                         else "untagged" if STRICT.fullmatch(ph) else "malformed")
                seen[kind] += 1
                if kind != "resolved" and len(examples) < 30:
                    examples.append({"job": job, "kind": kind, "token": ph})
            for t in mangled_tags(text, patterns):
                seen["mangled"] += 1
                if len(examples) < 30:
                    examples.append({"job": job, "kind": "mangled", "token": t, "text": text[:80]})
            seen["raw_identifiers"] += len(needles.found(LOOSE_BRACKET.sub("", text)))
        per[job].update(seen)
        if seen["resolved"] or seen["unknown_tag"] or seen["untagged"] or seen["malformed"] or seen["mangled"]:
            per[job]["outputs_with_placeholder_or_tag"] += 1
    total = Counter()
    for c in per.values():
        total.update(c)
    return {"total": dict(total), "per_job": {k: dict(v) for k, v in per.items()}, "examples": examples}


def unmask_state(state: Any, mac_map: dict, key: Optional[str] = None) -> Any:
    if isinstance(state, str):
        return state if key in masking._STRUCTURAL_KEYS else masking.unmask(state, mac_map)
    if isinstance(state, dict):
        return {k: unmask_state(v, mac_map, k) for k, v in state.items()}
    if isinstance(state, list):
        return [unmask_state(v, mac_map, key) for v in state]
    return state


def scan_store(db_path: Path, needles: Needles) -> dict:
    conn = org_db.open_for_analysis(db_path)
    hits: dict[str, Counter] = defaultdict(Counter)
    cells = 0
    tables = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")]
    for t in tables:
        for row in conn.execute(f'SELECT * FROM "{t}"'):
            for v in row:
                if isinstance(v, bytes):
                    try:
                        v = v.decode("utf-8")
                    except UnicodeDecodeError:
                        continue
                if isinstance(v, str) and v:
                    cells += 1
                    for slot in needles.found(v):
                        hits[t][slot] += 1
    conn.close()
    return {"text_cells": cells, "tables_with_raw": {t: dict(c) for t, c in hits.items()},
            "raw_identifier_slots": sorted({s for c in hits.values() for s in c})}


# ------------------------------------------------------------------------------------------ main

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scenario", required=True)
    ap.add_argument("--mask", choices=["off", "on"], required=True)
    ap.add_argument("--identifiers", help="identifiers.json from mask_stress.py (stress set)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--llm-url", default="http://127.0.0.1:8000/v1")
    ap.add_argument("--embed-url", required=True)
    ap.add_argument("--shadow", action="store_true",
                    help="mask on only: paired unmasked and replayed calls for every assign/brief/split prompt with a placeholder")
    ap.add_argument("--post-only", action="store_true",
                    help="redo the checks on an existing --out (no model calls; prompts and store are not re-measured)")
    args = ap.parse_args(argv)
    out = Path(args.out)
    needles = Needles(args.identifiers)
    tap = Tap(needles)
    install_taps(tap)
    mac = MacMasker()
    shadow = None
    if args.shadow:
        if args.mask != "on":
            raise SystemExit("--shadow needs --mask on")
        shadow = Shadow(mac, json.loads(Path(args.scenario).read_text(encoding="utf-8")), needles)
        install_shadow(shadow)
    build_items = to_items.build_items
    if args.mask == "off":
        disable_spark_masking()
    else:
        def masked_build(*a, **k):
            return [mac.item(it) for it in build_items(*a, **k)]
        run_eval.to_items.build_items = masked_build

    if not args.post_only:
        run_eval.main(["--scenario", args.scenario, "--condition", "skills", "--out", str(out),
                       "--llm-url", args.llm_url, "--embed-url", args.embed_url, "--keep-db"])
    old = json.loads((out / "mask_report.json").read_text(encoding="utf-8")) \
        if args.post_only and (out / "mask_report.json").exists() else {}

    if shadow:
        (out / "shadow.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in shadow.rows),
                                          encoding="utf-8")
    scenario = json.loads(Path(args.scenario).read_text(encoding="utf-8"))
    raw_items = build_items(args.scenario, render_missing=False)
    item_raw = {it["item_id"].lower(): "\n".join([it.get("text") or ""] + [s["text"] for s in it.get("segments") or []])
                for it in raw_items}
    sent = [mac.item(it) for it in raw_items] if args.mask == "on" else raw_items
    wire_left = Counter()
    for it in sent:
        text = "\n".join([it.get("text") or ""] + [s["text"] for s in it.get("segments") or []])
        wire_left.update(needles.values[s]["format"] for s in needles.found(text))
    snaps = scorer.load_snapshots(str(out / "snapshots"))
    order = [cp["checkpoint_id"] for cp in scenario["checkpoints"] if cp["checkpoint_id"] in snaps]
    per_cp = {cid: audit_state(snaps[cid], mac.map, needles, item_raw) for cid in order}
    final = per_cp[order[-1]] if order else {}
    all_cp = Counter()
    for a in per_cp.values():
        all_cp.update(a["placeholders"])
    unmasked = {cid: unmask_state(s, mac.map) for cid, s in snaps.items()}
    (out / "snapshots_unmasked").mkdir(exist_ok=True)
    for cid, s in unmasked.items():
        (out / "snapshots_unmasked" / f"{cid}.json").write_text(json.dumps(s, ensure_ascii=False, indent=1),
                                                                 encoding="utf-8")
    score_raw = json.loads((out / "score.json").read_text(encoding="utf-8"))
    score_unm = scorer.score(scenario, unmasked)
    (out / "score_unmasked.json").write_text(json.dumps(score_unm, ensure_ascii=False, indent=1), encoding="utf-8")
    db_path = out / "data" / "organizer.db"
    store = scan_store(db_path, needles) if db_path.exists() and needles.values else None
    shutil.rmtree(out / "data", ignore_errors=True)  # synthetic run store: scanned, then removed
    stats = json.loads((out / "stats.json").read_text(encoding="utf-8"))
    report = {
        "scenario": scenario.get("scenario_id"), "mask": args.mask,
        "identifier_occurrences": len(needles.rows), "identifier_values": len(needles.values),
        "mac_map_size": len(mac.map), "mac_spans_by_type": dict(mac.spans),
        "wire_raw_left_by_format": dict(wire_left), "wire_raw_left": sum(wire_left.values()),
        "prompts": old.get("prompts") if args.post_only else {"chat_calls": tap.chat_calls, "chat_calls_with_raw": sum(tap.chat_hits.values()),
                    "raw_slots_in_chat": sorted(tap.chat_hits), "embed_calls": tap.embed_calls,
                    "raw_slots_in_embed": sorted(tap.embed_hits)},
        "shadow": shadow.report() if shadow else old.get("shadow"),
        "outputs_all_calls": audit_runs(out / "runs.jsonl", mac.map, needles),
        "store": store if store is not None or not args.post_only else old.get("store"),
        "outputs_final": final, "outputs_all_checkpoints": dict(all_cp),
        "outputs_per_checkpoint": {cid: {"placeholders": a["placeholders"], "raw_identifiers": a["raw_identifiers"]}
                                   for cid, a in per_cp.items()},
        "score_raw": score_raw["summary"], "score_unmasked": score_unm["summary"],
        "score_diff_unmasked_vs_raw": {k: [score_raw["summary"][k], v] for k, v in score_unm["summary"].items()
                                       if score_raw["summary"].get(k) != v},
        "wall_s": stats.get("wall_s"), "model": json.loads((out / "meta.json").read_text())["model"],
        "git": json.loads((out / "meta.json").read_text())["git"],
    }
    (out / "mask_report.json").write_text(json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8")
    s = score_unm["summary"]
    print(f"[mask {args.mask}] B3 F1 {scorer.fmt(s['bcubed_f1'])}  link F1 {scorer.fmt(s['link_f1'])}  "
          f"card recall {scorer.fmt(s['card_fact_recall'])}  placeholders(final) {final.get('placeholders')}  "
          f"prompt raw slots {len(tap.chat_hits)}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
