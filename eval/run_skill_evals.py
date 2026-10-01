#!/usr/bin/env python3
"""Run the executable cases in skills/*/evals/evals.json against a live model, n repeats each.

Cases with a "fixture" carry the exact <data> the organizer would send (short handles E1/I1) and a
machine check. Each call goes through the real Harness (SKILL.md, schema-guided decoding with the same
per-call enums as the organizer, scripts/validate.py, one retry). Pass criteria:

  event-assign  check on the action the organizer derives (decide.derive), not on the raw decision:
                decision_in, event_id, not_attach.
  event-brief   status_line_not (regex must not match), off_anchor_includes.
  home-rank     constraints: {"above": [a, b]} importance(a) > importance(b); {"max": {id: v}}; {"min": {id: v}}.
  event-consolidate  check: verdict_in, target (for a merge), not_target.
  person-resolve  check: kind_in, same_as ("" = merged with nobody), common_word.
  matter-map    check: n_strands, apart / together (item handles), kinds_include, health_in, blocks, no_blocks,
                forbid (see check_map). A repaired output (only repairable errors) counts as valid, as in the organizer.
  matter-group  check: together / apart / rope_of / under / unplaced / type_in / not_title (see check_group).
  item-split    fixture {text, kind, source_app, started_at}: units are built exactly as the organizer
                builds them; check on the segments the organizer derives (units.segments_from_output):
                unsplit, n_segments [min, max], apart [[Ua, Ub]] (both covered, different segments),
                together [[Ua, Ub]] (same segment), skip [U] (in no segment). fixture.known (optional) is the
                known_matters list [{"id", "title"}] the organizer would show.

All fixtures are dev-week-v1 derived or invented; never add holdout material here.
vLLM on a shared server is nondeterministic at temperature 0: judge by pass counts over n >= 3.

  python3 eval/run_skill_evals.py --llm-url http://127.0.0.1:8000/v1 --n 3 --out /tmp/skill-evals.json
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "spark"))

from organizer.skills import Harness, SkillRegistry  # noqa: E402
from organizer.store import Store  # noqa: E402

JOB = {"event-assign": "assign", "event-brief": "brief", "home-rank": "rank", "item-split": "split",
       "event-consolidate": "consolidate", "person-resolve": "person", "matter-map": "map", "matter-group": "group"}
# The user's own names in the matter-map fixtures (the organizer passes ORGANIZER_OWNER_ALIASES).
MAP_OWNER = ["许念", "念念"]


def _enum(prop: dict, values: list[str]) -> None:
    prop["enum"] = list(values)
    prop.pop("pattern", None)


def build_request(registry: SkillRegistry, skill_name: str, case: dict) -> tuple[str, dict, dict, dict]:
    """(job, data, schema, context) exactly as the organizer builds them for this input."""
    job = JOB[skill_name]
    if job == "split":
        return ("split",) + split_request(registry, case)
    data = case["fixture"]["data"]
    if job in ("map", "group"):
        # exactly organizer/matter_map.py / matter_group.py: the skill's own build script makes schema and context
        build = registry.script(skill_name, "build")
        schema = build.schema_for(registry.skills[skill_name].schema, data)
        context = build.context_for(data, owner=MAP_OWNER) if job == "map" else build.context_for(data)
        return job, data, schema, context
    schema = copy.deepcopy(registry.skills[skill_name].schema)
    props = schema["properties"]
    if job == "assign":
        handles = [c["event_id"] for c in data["candidates"]]
        item_ids = [i["item_id"] for c in data["candidates"]
                    for i in ([c["first_item"]] if c.get("first_item") else []) + c.get("recent_items", [])]
        _enum(props["event_id"], handles + [""])
        if handles:
            _enum(props["judged"]["items"]["properties"]["event_id"], handles)
        else:
            props["judged"]["maxItems"] = 0
        ev_ids = props["evidence"]["items"]["properties"]["item_ids"]
        if item_ids:
            _enum(ev_ids["items"], item_ids)
        else:
            ev_ids["maxItems"] = 0
        context = {"candidate_ids": handles, "candidate_item_ids": item_ids}
    elif job == "consolidate":
        # exactly organizer/consolidate.py _context: enums for target / verdict / quote item, validator context
        targets = list(data["targets"])
        _enum(props["target"], targets + [""])
        if not data["can_unfile"]:
            props["verdict"]["enum"] = ["merge", "own_matter"]
        elif not targets:
            props["verdict"]["enum"] = ["own_matter", "not_matter"]
        texts = {i["item_id"]: i["text"] for i in data["small"]["items"]}
        _enum(props["quote"]["properties"]["item_id"], list(texts))
        views = {v["event_id"]: v for v in data["matters"] + data["more_matters"]}
        context = {"targets": targets, "can_unfile": data["can_unfile"], "items": texts,
                   "target_text": {h: " ".join(str(views[h].get(k) or "") for k in ("title", "anchor", "status_line", "sample"))
                                   for h in targets if h in views}}
    elif job == "person":
        # exactly organizer/people_pass.py _judge: same_as may only name an offered candidate
        handles = [c["handle"] for c in data["candidates"]]
        props["same_as"] = {"type": "string", "enum": [""] + handles}
        context = {"candidates": handles}
    elif job == "brief":
        handles = [i["item_id"] for i in data["items"]]
        _enum(props["status_facts"]["items"]["properties"]["item_ids"]["items"], handles)
        _enum(props["off_anchor_item_ids"]["items"], handles)
        context = case["fixture"]["context"]
    else:
        ids = [e["event_id"] for e in data["events"]]
        props["ranking"]["minItems"] = props["ranking"]["maxItems"] = len(ids)
        _enum(props["ranking"]["items"]["properties"]["event_id"], ids)
        context = {"event_ids": ids, "feature_less": [e["event_id"] for e in data["events"] if e.get("feature_less")]}
    return job, data, schema, context


def split_units(registry: SkillRegistry, case: dict) -> tuple[list[dict], str]:
    from organizer import transcripts

    fx = case["fixture"]
    tx = transcripts.parse(fx["text"])
    units = registry.script("item-split", "units").build_units(fx["text"], tx["turns"] if tx else None)
    return units, tx["format"] if tx else ""


def split_request(registry: SkillRegistry, case: dict) -> tuple[dict, dict, dict]:
    fx = case["fixture"]
    units, fmt = split_units(registry, case)
    known = fx.get("known") or []
    data = registry.script("item-split", "units").build_data(fx.get("kind", "dictation"), fx.get("source_app", "备忘录"),
                                                             fx.get("started_at", "2026-05-06T09:00:00+08:00"),
                                                             units, fmt, known=known)
    schema = copy.deepcopy(registry.skills["item-split"].schema)
    ids = [u["u"] for u in units]
    seg = schema["properties"]["segments"]["items"]["properties"]
    _enum(seg["from"], ids)
    _enum(seg["to"], ids)
    if "known" in schema["properties"]:
        schema["properties"]["known"]["items"] = {"type": "string", "enum": [""] + [k["id"] for k in known]}
    return data, schema, {"unit_ids": ids, "known": [k["id"] for k in known]}


def check_split(registry: SkillRegistry, case: dict, out: dict) -> tuple[bool, str]:
    c = case["check"]
    units, _ = split_units(registry, case)
    segs = registry.script("item-split", "units").segments_from_output(out, units)
    where = {}
    for n, s in enumerate(segs):
        for u in units:
            if u["start"] >= s["start"] and u["end"] <= s["end"]:
                where[u["u"]] = n
    shown = " | ".join(f"{s['gist']}" for s in segs) or "whole"
    if c.get("unsplit") and segs:
        return False, f"split into {len(segs)}: {shown}"
    lo, hi = c.get("n_segments", [0, 99])
    if not c.get("unsplit") and not lo <= len(segs) <= hi:
        return False, f"{len(segs)} segments: {shown}"
    for a, b in c.get("apart", []):
        if a not in where or b not in where or where[a] == where[b]:
            return False, f"{a}/{b} not apart: {shown}"
    for a, b in c.get("together", []):
        if where.get(a) is None or where.get(a) != where.get(b):
            return False, f"{a}/{b} not together: {shown}"
    for u in c.get("skip", []):
        if u in where:
            return False, f"{u} should be in no segment"
    return True, shown


def check_map(case: dict, out: dict) -> tuple[bool, str]:
    """matter-map: n_strands [min, max]; apart [[Ia, Ib]] (both in strands, different ones); together [[Ia, Ib]]
    (same strand); kinds_include [kind]; health_in [level]; blocks [{other, direction}] (each present);
    no_blocks [E] (no blocks entry names them); forbid (regex that no strand name / summary or knot text matches)."""
    c = case["check"]
    where = {i: s["id"] for s in out["strands"] for i in s["item_ids"]}
    got = f"{len(out['strands'])} strands {[s['name'] for s in out['strands']]} knots {[k['kind'] for k in out['knots']]}" \
          f" health {out['health']['level']} blocks {[(b['other'], b['direction']) for b in out['blocks']]}"
    lo, hi = c.get("n_strands", [1, 6])
    if not lo <= len(out["strands"]) <= hi:
        return False, got
    for a, b in c.get("apart", []):
        if where.get(a) is None or where.get(b) is None or where[a] == where[b]:
            return False, f"{a}/{b} not apart: {got}"
    for a, b in c.get("together", []):
        if where.get(a) is None or where.get(a) != where.get(b):
            return False, f"{a}/{b} not together: {got}"
    kinds = {k["kind"] for k in out["knots"]}
    if not set(c.get("kinds_include", [])) <= kinds:
        return False, got
    if c.get("health_in") and out["health"]["level"] not in c["health_in"]:
        return False, got
    pairs = {(b["other"], b["direction"]) for b in out["blocks"]}
    for want in c.get("blocks", []):
        if (want["other"], want["direction"]) not in pairs:
            return False, got
    if any(b["other"] in c.get("no_blocks", []) for b in out["blocks"]):
        return False, got
    if c.get("forbid"):
        texts = [s["name"] for s in out["strands"]] + [s["summary"] for s in out["strands"]] + [k["text"] for k in out["knots"]]
        if any(re.search(c["forbid"], t) for t in texts):
            return False, f"forbidden text: {got}"
    return True, got


def check_group(case: dict, out: dict) -> tuple[bool, str]:
    """matter-group: together [[Ea, Eb]] (on the same rope); apart [[Ea, Eb]] (not on the same rope); rope_of
    {E: R}; under {E: R} (E's rope is R or inside R); unplaced [E]; type_in {E: [types]}; not_title (regex no new
    rope title matches)."""
    c = case["check"]
    rope = {p["matter"]: p["rope"] for p in out["placements"]}
    parent = {r["key"]: r["parent"] for r in out["new_ropes"]}
    parent.update({n["rope"]: n["parent"] for n in out.get("nest") or []})
    for r in case["fixture"]["data"]["ropes"]:
        parent.setdefault(r["id"], r.get("parent") or "")
    got = f"ropes {[(r['key'], r['title'], r['parent']) for r in out['new_ropes']]} placed {rope}"
    for a, b in c.get("together", []):
        if not rope.get(a) or rope.get(a) != rope.get(b):
            return False, f"{a}/{b} not together: {got}"
    for a, b in c.get("apart", []):
        if rope.get(a) and rope.get(a) == rope.get(b):
            return False, f"{a}/{b} not apart: {got}"
    for e, r in c.get("rope_of", {}).items():
        if rope.get(e) != r:
            return False, f"{e} not on {r}: {got}"
    for e, r in c.get("under", {}).items():
        cur, seen = rope.get(e), set()
        while cur and cur != r and cur not in seen:
            seen.add(cur)
            cur = parent.get(cur)
        if cur != r:
            return False, f"{e} not under {r}: {got}"
    for e in c.get("unplaced", []):
        if rope.get(e):
            return False, f"{e} placed: {got}"
    types = {p["matter"]: p["type"] for p in out["placements"]}
    for e, allowed in c.get("type_in", {}).items():
        if types.get(e) not in allowed:
            return False, f"{e} type {types.get(e)}: {got}"
    if c.get("not_title") and any(re.search(c["not_title"], r["title"]) for r in out["new_ropes"]):
        return False, f"forbidden title: {got}"
    return True, got


def check(registry: SkillRegistry, skill_name: str, case: dict, out: dict) -> tuple[bool, str]:
    if skill_name == "item-split":
        return check_split(registry, case, out)
    if skill_name == "matter-map":
        return check_map(case, out)
    if skill_name == "matter-group":
        return check_group(case, out)
    c = case["check"]
    if skill_name == "event-assign":
        rank = {x["event_id"]: i for i, x in enumerate(case["fixture"]["data"]["candidates"])}
        anchors = {x["event_id"]: " ".join(v for v in (x["anchor"], x.get("title", ""),
                                                        ((x.get("first_item") or {}).get("text") or "")[:60]) if v)
                   for x in case["fixture"]["data"]["candidates"]}
        d = registry.script("event-assign", "decide").derive(out, rank, anchors)
        if d["action"] not in c.get("decision_in", [d["action"]]):
            return False, f"action {d['action']}"
        if "event_id" in c and d["target"] != c["event_id"]:
            return False, f"target {d['target']}"
        if d["action"] == "attach" and d["target"] in c.get("not_attach", []):
            return False, f"attached to {d['target']}"
        return True, f"{d['action']} {d['target']}".strip()
    if skill_name == "event-consolidate":
        got = f"{out['verdict']} {out['target']}".strip()
        if out["verdict"] not in c.get("verdict_in", [out["verdict"]]):
            return False, got
        if "target" in c and out["verdict"] == "merge" and out["target"] != c["target"]:
            return False, got
        if out["verdict"] == "merge" and out["target"] == c.get("not_target"):
            return False, got
        return True, got
    if skill_name == "person-resolve":
        got = f"{out['kind']} same_as={out['same_as'] or '-'} common={out['common_word']}"
        if out["kind"] not in c.get("kind_in", [out["kind"]]):
            return False, got
        if "same_as" in c and (out["same_as"] or "") != c["same_as"]:
            return False, got
        if "common_word" in c and bool(out["common_word"]) != c["common_word"]:
            return False, got
        return True, got
    if skill_name == "event-brief":
        if c.get("status_line_not") and re.search(c["status_line_not"], out["status_line"]):
            return False, out["status_line"]
        if c.get("off_anchor_includes") and c["off_anchor_includes"] not in out.get("off_anchor_item_ids", []):
            return False, f"off_anchor {out.get('off_anchor_item_ids')}"
        return True, out["status_line"]
    imp = {r["event_id"]: r["importance"] for r in out["ranking"]}
    for con in c.get("constraints", []):
        if "above" in con and not imp[con["above"][0]] > imp[con["above"][1]]:
            return False, f"{con['above'][0]}={imp[con['above'][0]]} !> {con['above'][1]}={imp[con['above'][1]]}"
        for k, v in con.get("max", {}).items():
            if imp[k] > v:
                return False, f"{k}={imp[k]} > {v}"
        for k, v in con.get("min", {}).items():
            if imp[k] < v:
                return False, f"{k}={imp[k]} < {v}"
    return True, json.dumps(imp)


def cases(skills: list[str]) -> list[tuple[str, dict]]:
    out = []
    for name in skills:
        for case in json.loads((ROOT / "skills" / name / "evals" / "evals.json").read_text(encoding="utf-8")):
            if "fixture" in case:
                out.append((name, case))
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--llm-url", default="http://127.0.0.1:8000/v1")
    ap.add_argument("--llm-model", default="auto")
    ap.add_argument("--n", type=int, default=3)
    ap.add_argument("--skills", default="event-assign,event-brief,home-rank")
    ap.add_argument("--only", help="comma list of case ids")
    ap.add_argument("--out", required=True)
    args = ap.parse_args(argv)
    from organizer.clients import OpenAIChatClient

    registry = SkillRegistry(ROOT / "skills")
    store = Store(":memory:")
    harness = Harness(registry, OpenAIChatClient(args.llm_url, args.llm_model, 300.0), store)
    only = set(args.only.split(",")) if args.only else None
    report = []
    for skill_name, case in cases(args.skills.split(",")):
        if only and case["id"] not in only:
            continue
        job, data, schema, context = build_request(registry, skill_name, case)
        rows = []
        for _ in range(args.n):
            rules = registry.script(skill_name, "validate") if job in ("map", "group") else None
            res = harness.run(job, data, context=context, schema=schema, subject=case["id"],
                              no_retry=rules.REPAIRABLE if rules else None)
            run = store.one("SELECT completion_tokens FROM runs WHERE run_id=?", (res.run_id,))
            if rules is not None and not res.ok:
                # as the organizer does: a repairable failure is repaired and used (matter_map / matter_group _usable)
                fixed = rules.salvage(res.candidate, res.errors, context, **({"after_retry": res.attempts >= 2}
                                                                            if job == "map" else {}))
                if fixed is not None:
                    res.ok, res.output = True, fixed
            ok, note = check(registry, skill_name, case, res.output) if res.ok else (False, "; ".join(res.errors)[:200])
            raw = store.one("SELECT output FROM runs WHERE run_id=?", (res.run_id,))
            rows.append({"pass": ok, "valid": res.ok, "attempts": res.attempts, "note": note,
                         "completion_tokens": run["completion_tokens"] if run else None,
                         "completion_tokens_per_attempt": round((run["completion_tokens"] or 0) / max(1, res.attempts))
                         if run else None,
                         "output": res.output if res.ok else (raw or {}).get("output"), "errors": res.errors})
        entry = {"skill": skill_name, "id": case["id"], "passes": sum(r["pass"] for r in rows), "n": len(rows),
                 "first_attempt_valid": sum(r["valid"] and r["attempts"] == 1 for r in rows),
                 "completion_tokens_max": max((r["completion_tokens"] or 0) for r in rows),
                 "completion_tokens_per_attempt_max": max((r["completion_tokens_per_attempt"] or 0) for r in rows),
                 "runs": rows}
        report.append(entry)
        print(f"{skill_name:13} {case['id']:24} {entry['passes']}/{entry['n']}  first-valid {entry['first_attempt_valid']}"
              f"  max-out/attempt {entry['completion_tokens_per_attempt_max']}  {rows[-1]['note'][:70]}", flush=True)
    summary = {"cases": len(report), "all_pass": sum(e["passes"] == e["n"] for e in report),
               "pass_rate": statistics.mean(e["passes"] / e["n"] for e in report) if report else None,
               "model": harness.client.model_id, "n": args.n}
    Path(args.out).write_text(json.dumps({"summary": summary, "cases": report}, ensure_ascii=False, indent=1),
                              encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
