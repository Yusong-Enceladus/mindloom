#!/usr/bin/env python3
"""Deterministic action for an event-assign output (no model, stdlib only).

The model reports, per plausible candidate, whether the new item is about the *same concrete object*
(`judged[].match`), and whether the item is a matter the user is pursuing at all (`item_is_matter`).
The organizer derives the action from those facets instead of trusting the `decision` field, so a
question is asked only when the model itself reports doubt, and an unconfirmed link can never drag
the item (and every later item that cites it) into a look-alike event.

derive(output, rank, anchors) -> {"action": attach|new|none|ask, "target": event_id|"",
                                  "provisional": new|none|"", "why": str}

  rank:    {event_id: retrieval rank (0 = best)} for ordering judged entries; unknown ids rank last.
  anchors: {event_id: the event's fixed object}; optional.

Rules
  1. sames  = judged entries with match == same_object; unsure = entries with match == unsure.
  2. One or more same_object                                         -> attach to the best-ranked one, unless
     item_object shares fewer than 2 content characters with that event's anchor, title and seed item
     (the model matched a multi-matter item or a status line, not the object) - then ask about it. With two or more
     same_object candidates the doubt is only which fragment of one matter: attach to the best-ranked
     and propose merging it with the next one ("merge_with").
  3. Otherwise any unsure                                            -> ask about the best-ranked of them;
     provisional placement = new if item_is_matter else none (never attach).
  4. Otherwise item_is_matter is false                               -> none (stays unfiled).
  5. Otherwise                                                       -> new.
person_only / topic_only / different are not links: a shared person or a shared word is not the same
matter. An unsure entry next to a same_object one does not block the attach: the item can only live in
one event, and the same-object one is the better home.

An output without `judged` (the bare ablation and the no-LLM baseline) is taken at its word.

CLI: python decide.py output.json   (prints the derived action)
"""

from __future__ import annotations

import json
import sys

LINK_MATCHES = ("same_object", "unsure")
# Characters that say nothing about which object an event is about.
_STOP = set("的与和及并在了是有一个件事项目（）()、/，,。 -—:：0123456789月日号")


def object_overlap(a: str, b: str) -> int:
    """Shared content characters between an item's object and an event's anchor."""
    return len((set(a or "") - _STOP) & (set(b or "") - _STOP))


def derive(output: dict, rank: dict | None = None, anchors: dict | None = None) -> dict:
    rank = rank or {}
    decision = output.get("decision")
    if "judged" not in output:
        target = output.get("event_id") or ""
        if decision == "ask":
            return {"action": "ask", "target": target, "provisional": "new", "why": "legacy output"}
        return {"action": decision if decision in ("attach", "new", "none") else "new", "target": target,
                "provisional": "", "why": "legacy output"}
    is_matter = bool(output.get("item_is_matter", True))
    judged = [j for j in output.get("judged") or [] if j.get("event_id")]
    seen: set[str] = set()
    ordered = []
    for j in sorted(judged, key=lambda j: rank.get(j["event_id"], 10_000)):
        if j["event_id"] not in seen:  # a repeated id keeps its first judgement
            seen.add(j["event_id"])
            ordered.append(j)
    sames = [j for j in ordered if j.get("match") == "same_object"]
    links = [j for j in ordered if j.get("match") in LINK_MATCHES]
    provisional = "new" if is_matter else "none"
    if sames:
        target = sames[0]["event_id"]
        anchor = (anchors or {}).get(target)
        if anchor and object_overlap(output.get("item_object", ""), anchor) < 2:
            return {"action": "ask", "target": target, "provisional": provisional, "why": "object differs from anchor"}
        out = {"action": "attach", "target": target, "provisional": "", "why": "same_object"}
        if len(sames) > 1:
            out.update(merge_with=sames[1]["event_id"], why="several same_object")
        return out
    if links:
        return {"action": "ask", "target": links[0]["event_id"], "provisional": provisional, "why": "unsure"}
    if not is_matter:
        return {"action": "none", "target": "", "provisional": "", "why": "not a matter"}
    return {"action": "new", "target": "", "provisional": "", "why": "no same object"}


def main() -> int:
    output = json.load(open(sys.argv[1], encoding="utf-8"))
    json.dump(derive(output), sys.stdout, ensure_ascii=False)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
