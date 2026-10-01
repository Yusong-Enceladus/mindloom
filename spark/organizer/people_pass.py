"""People pass: keep the people list clean and link people to the items that mention them
(skill person-resolve).

The organizer reads people off speaker lines, chat senders and meeting transcripts. At scale (1,500-1,600
items) that left 116-222 person records for 36-43 real people: field labels, code keys and phrases read as
speakers ("X：…"), the same person under several names (a Chinese name, its English form, a nickname), and
people linked only to the items where they speak, not to the items that talk about them.

Schedule (the organizer's scheduler calls this; no user action): every `every_items` processed item jobs and
when the queue is empty and there is work (items read with older speaker rules, people not judged yet, or
items not yet searched with the current mention index); at most `max_calls` people judged per pass.

Per pass:
  1. re-read: an item whose people were derived with older speaker rules (persons.speakers_in_text) gets
     its people derived again (Organizer._record_item_persons), so a store built before a rule change is
     cleaned without re-organizing anything;
  2. deterministic merges: a bilingual record ("谭悦 Yue TAN") goes to its Chinese name, a Latin-only record
     to the one bilingual record whose Latin part it is, a remark form ("周建国-装修") to the one full-name
     record it decorates;
  3. person-resolve judges each new chat/transcript person (most linked first): person / role / not_person,
     whether its name is also an ordinary word, and which offered look-alike (scripts/candidates.py) it is
     the same as. not_person -> its links are removed and it is never linked again; role -> kept, never
     searched for; same_as -> merged only when scripts/candidates.py allows it for these names (a family
     name + title or a given name must fit exactly one candidate), the two never speak in one item, no user
     decision says they differ, neither was named by the user, and the target is not a voice person (a voice
     person gets a same_person question instead, as before);
  4. mentions: every judged person whose name is searchable (People.mention_index) is linked, with role
     'mention', to the items whose text names them. Mentions show on events and person pages; they are not
     used for matching, briefs or ranking (Organizer.other_persons leaves them out).

Every verdict is recorded (person_checks, proposals kind 'person'). Nothing leaves the Spark; no item content
is stored by the pass.

Privacy (docs/PRIVACY.md): the pass runs only while the store is unlocked, inside the worker's step; its model
calls on the pool are bound to the unlock session (Organizer.in_session), so a lock or a wipe meanwhile leaves
nothing written. A person-resolve call records the items whose lines it shows (reads), so deleting any of them
clears the run and its proposal. Deleted items are never re-read or searched; a purge drops their person_scan
rows and the person_checks of records left with no item. The mention index (names) is dropped on lock.
"""

from __future__ import annotations

import hashlib
import json
import logging
import re
import time
from typing import Any, Optional

from .clients import ModelUnavailable, safe_error
from .persons import _searchable_names, canonical_form, looks_like_person_name, name_base, norm, split_bilingual
from .store import StoreLocked

log = logging.getLogger("organizer.people")

RULES = "speakers-2"          # bump when persons.speakers_in_text / transcript speaker rules change
# Items still waiting for (or in) their organize job are left to it: it derives their people itself. Items the
# user deleted (purged) are never read again.
_SETTLED = "i.purged = 0 AND i.item_id NOT IN (SELECT item_id FROM jobs WHERE state IN ('queued', 'running'))"
SPEAKER_ROLES = ("speaker", "sender", "text_speaker", "transcript_speaker")
LINE_CHARS = 80
LINES = 3


def _line_with(text: str, name: str) -> str:
    for line in (text or "").splitlines():
        k = line.find(name)
        if k >= 0:
            line = line.strip()
            k = line.find(name)
            start = max(0, k - 20)
            out = line[start:start + LINE_CHARS]
            return ("…" if start else "") + out + ("…" if start + LINE_CHARS < len(line) else "")
    return ""


class PeoplePass:
    def __init__(self, org: Any, *, enabled: bool = True, every_items: int = 25, max_calls: int = 40,
                 idle_min_items: int = 5, candidates_k: int = 6):
        self.org = org
        self.store = org.store
        self.people = org.people
        self.enabled = enabled
        self.every_items = max(1, int(every_items))
        self.max_calls = max(1, int(max_calls))
        self.idle_min_items = max(1, int(idle_min_items))
        self.candidates_k = int(candidates_k)
        self.jobs_since = 0
        self._idle_cursor: Optional[int] = None
        self._index: Optional[tuple[int, list, str]] = None
        self._cand = org.registry.script("person-resolve", "candidates")
        self.stats = {"passes": 0, "calls": 0, "reread_items": 0, "merged_rules": 0, "merged_model": 0,
                      "not_person": 0, "role": 0, "person": 0, "asked": 0, "invalid": 0, "mention_items": 0}

    # ---- scheduling ---------------------------------------------------------------------

    def reset(self) -> None:
        """A lock, a wipe or a new unlock session: drop the mention index (person names) and the idle cursor."""
        self._index = None
        self._idle_cursor = None

    def note_job(self) -> None:
        self.jobs_since += 1

    def due(self) -> bool:
        return self.enabled and self.jobs_since >= self.every_items and self.has_work()

    def idle_due(self) -> bool:
        if not self.enabled:
            return False
        cursor = self.store.cursor()
        if cursor == self._idle_cursor:
            return False
        if self.has_work():
            return True
        self._idle_cursor = cursor
        return False

    def has_work(self) -> bool:
        if self.store.one("SELECT 1 FROM items i LEFT JOIN person_scan s ON s.item_id = i.item_id"
                          f" WHERE (s.item_id IS NULL OR s.rules != ?) AND {_SETTLED} LIMIT 1", (RULES,)):
            return True
        if self._unjudged(limit=1):
            return True
        _, _, digest = self.index()
        return self.store.one("SELECT 1 FROM person_scan s JOIN items i ON i.item_id = s.item_id"
                              f" WHERE s.mentions != ? AND {_SETTLED} LIMIT 1", (digest,)) is not None

    # ---- mention index (cached per persons revision) --------------------------------------

    def index(self) -> tuple[int, list, str]:
        """(persons revision, [(name, person id)], digest), rebuilt when any person or verdict changed."""
        rev = int(self.store.scalar("SELECT COALESCE(MAX(seq), 0) FROM persons") or 0)
        n_checks = int(self.store.scalar("SELECT COUNT(*) FROM person_checks") or 0)
        key = rev * 100_003 + n_checks
        index = self._index  # reset() may drop it from another thread (a lock)
        if index is None or index[0] != key:
            pairs = self.people.mention_index()
            digest = hashlib.sha256(json.dumps(pairs, ensure_ascii=False).encode()).hexdigest()[:16]
            index = self._index = (key, pairs, digest)
        return index

    def link_mentions(self, item: dict, text: str) -> bool:
        """Set the item's 'mention' links to the indexed people its text names. Returns True if they changed."""
        _, pairs, digest = self.index()
        found = [p for p in self.people.find_mentions(text, pairs) if not self.people.is_self(p)]
        iid = item["item_id"]
        with self.store.tx():
            rows = self.store.all("SELECT person_id, role FROM item_persons WHERE item_id=?", (iid,))
            others = {self.people.canonical(r["person_id"]) for r in rows if r["role"] != "mention"}
            current = {r["person_id"] for r in rows if r["role"] == "mention"}
            want = {p for p in found if p not in others}
            changed = want != current
            if changed:
                self.store.x("DELETE FROM item_persons WHERE item_id=? AND role='mention'", (iid,))
                for p in sorted(want):
                    self.people.add_item_person(iid, p, "mention")
            self.store.x("INSERT INTO person_scan(item_id, rules, mentions) VALUES (?,?,?)"
                         " ON CONFLICT(item_id) DO UPDATE SET rules=excluded.rules, mentions=excluded.mentions", (iid, RULES, digest))
        return changed

    # ---- the pass -------------------------------------------------------------------------

    def run(self, pool=None) -> dict:
        """One pass. The model being down propagates (the worker backs off); any other failure is logged."""
        self.jobs_since = 0
        self._idle_cursor = None
        stats = {"reread_items": 0, "merged_rules": 0, "judged": 0, "mention_items": 0}
        try:
            touched: set[str] = set()
            stats["reread_items"] = self._reread(touched)
            stats["merged_rules"] = self._rule_merges()
            stats["judged"] = self._judge(pool)
            stats["mention_items"] = self._mentions(touched)
            self._touch_events(touched)
            self.stats["passes"] += 1
            return stats
        except ModelUnavailable:
            self.jobs_since = self.every_items
            raise
        except StoreLocked:
            raise  # locked (or a new session) meanwhile: nothing more of this pass is written
        except Exception as exc:  # never stops item processing
            log.warning("people pass failed: %s", safe_error(exc))
            return stats

    def _item_text(self, item: dict) -> str:
        try:
            return self.org.match_body(item)
        except Exception:
            return item.get("text") or ""

    def _latest_items(self, where: str, args: tuple = ()) -> list[dict]:
        rows = self.store.all(
            "SELECT i.item_id, MAX(i.revision) AS rev FROM items i LEFT JOIN person_scan s ON s.item_id = i.item_id"
            f" WHERE ({where}) AND {_SETTLED} GROUP BY i.item_id ORDER BY MIN(i.started_ts), i.item_id", args)
        return [self.store.get_item(r["item_id"], r["rev"]) for r in rows]

    def _reread(self, touched: set[str]) -> int:
        n = 0
        linked_before = {self.people.canonical(r["person_id"]) for r in self.store.all(
            "SELECT DISTINCT person_id FROM item_persons WHERE role != 'mention'")}
        for item in self._latest_items("s.item_id IS NULL OR s.rules != ?", (RULES,)):
            if item is None:
                continue
            before = set(self.people.item_person_ids(item["item_id"]))
            derived = self.store.get_derived(item["item_id"], item["revision"]) or {}
            seg = self.store.segment_of(item["item_id"])
            self.org._record_item_persons(item, derived.get("messages") or [], seg)
            if set(self.people.item_person_ids(item["item_id"])) != before:
                touched.add(item["item_id"])
            n += 1
        self.stats["reread_items"] += n
        if n:
            # A chat/transcript "person" the speaker rules no longer read anywhere (a label, a code key, a phrase)
            # is marked not_person, as if person-resolve had said so: it keeps no links and is never linked again.
            linked_now = {self.people.canonical(r["person_id"]) for r in self.store.all(
                "SELECT DISTINCT person_id FROM item_persons WHERE role != 'mention'")}
            for r in self._live_named():
                pid = r["person_id"]
                if (pid in linked_before and pid not in linked_now and r["origin"] != "voice" and not r["status"]
                        and r["name_source"] != "user"):
                    with self.store.tx():
                        self.store.x("DELETE FROM item_persons WHERE person_id=? AND role='mention'", (pid,))
                        self.store.x("UPDATE persons SET status='not_person', seq=? WHERE person_id=?",
                                     (self.store.bump(), pid))
                        self._record(pid, r["display_name"], "not_person", 1, None, "rule_unread", None)
                    self.stats["not_person"] += 1
        return n

    def _mentions(self, touched: set[str]) -> int:
        _, _, digest = self.index()
        n = 0
        for item in self._latest_items("s.item_id IS NULL OR s.mentions != ?", (digest,)):
            if item is None:
                continue
            if self.link_mentions(item, self._item_text(item)):
                touched.add(item["item_id"])
                n += 1
        self.stats["mention_items"] += n
        return n

    def _touch_events(self, item_ids: set[str]) -> None:
        """Move the events holding these items so the Mac sees their new people (no re-brief)."""
        if not item_ids:
            return
        ids = sorted(item_ids)
        with self.store.tx():
            events: set[str] = set()
            for i in range(0, len(ids), 500):
                chunk = ids[i:i + 500]
                marks = ",".join("?" * len(chunk))
                events |= {r["event_id"] for r in self.store.all(
                    f"SELECT DISTINCT event_id FROM event_items WHERE removed=0 AND item_id IN ({marks})", chunk)}
            for eid in sorted(events):
                self.store.x("UPDATE events SET seq=? WHERE event_id=?", (self.store.bump(), eid))

    # ---- guards shared by rule and model merges --------------------------------------------

    def _aliases_of(self, pid: str) -> list[str]:
        return [pid] + [r["person_id"] for r in self.store.all("SELECT person_id FROM persons WHERE merged_into IS NOT NULL")
                        if self.people.canonical(r["person_id"]) == pid and r["person_id"] != pid]

    def _co_speakers(self, a: str, b: str) -> bool:
        """Both speak (or send) in one item: two people talking to each other are never one person."""
        ia, ib = self._aliases_of(a), self._aliases_of(b)
        roles = ",".join("?" * len(SPEAKER_ROLES))
        return self.store.one(
            f"SELECT 1 FROM item_persons x JOIN item_persons y ON x.item_id = y.item_id"
            f" WHERE x.person_id IN ({','.join('?' * len(ia))}) AND y.person_id IN ({','.join('?' * len(ib))})"
            f" AND x.role IN ({roles}) AND y.role IN ({roles}) LIMIT 1",
            (*ia, *ib, *SPEAKER_ROLES, *SPEAKER_ROLES)) is not None

    def _mergeable(self, keep: str, drop: str) -> Optional[str]:
        """None if the two records may be merged by the pass, else why not."""
        a, b = self.people.get(keep), self.people.get(drop)
        if not a or not b or a["merged_into"] or b["merged_into"]:
            return "gone"
        if self.people.are_different(keep, drop):
            return "user_different"
        if "user" in (a["name_source"], b["name_source"]):
            return "user_named"
        if a["origin"] == "voice" or b["origin"] == "voice":
            return "voice"
        if self.people.is_self(keep) or self.people.is_self(drop):
            return "owner"
        if self._co_speakers(keep, drop):
            return "co_speakers"
        return None

    def _merge(self, a: str, b: str, source: str) -> str:
        """Merge two live records, keeping the one with the fullest name (candidates.keep_rank; then the one
        with more items). Returns the kept id."""
        na, nb = self.people.name(a) or "", self.people.name(b) or ""
        ra, rb = self._cand.keep_rank(na), self._cand.keep_rank(nb)
        if rb > ra or (rb == ra and len(self._links(b)) > len(self._links(a))):
            a, b = b, a
        return self.people.merge(a, b, source)

    def _live_names(self) -> list[str]:
        return [r["display_name"] for r in self._live_named() if r["status"] not in ("not_person", "role")]

    def _live_named(self) -> list[dict]:
        return [dict(r) for r in self.store.all(
            "SELECT person_id, display_name, origin, name_source, status FROM persons"
            " WHERE merged_into IS NULL AND display_name IS NOT NULL ORDER BY seq, person_id")
            if not self.people.is_self(r["person_id"])]

    # ---- 2. deterministic merges -------------------------------------------------------------

    def _rule_merges(self) -> int:
        n = 0
        live = self._live_named()
        by_name: dict[str, list[str]] = {}
        for r in live:
            by_name.setdefault(norm(r["display_name"]), []).append(r["person_id"])
        # 2a. a bilingual record kept under its full form (a store built before canonical_form): to its Chinese name.
        for r in live:
            if r["origin"] == "voice" or r["status"]:
                continue
            kept = canonical_form(r["display_name"])
            if kept == r["display_name"]:
                continue
            target = self.people.upsert_chat(kept, "transcript" if r["origin"] == "transcript" else "text")
            target = self.people.canonical(target)
            if target != r["person_id"] and self._mergeable(target, r["person_id"]) is None:
                target = self._merge(target, r["person_id"], "rule_bilingual")
                self._record(r["person_id"], r["display_name"], "person", 0, target, "merged_bilingual", None)
                n += 1
        # 2b. a Latin-only name equal to the Latin part of exactly one bilingual record (live or already merged).
        latin_of: dict[str, set[str]] = {}
        for r in self.store.all("SELECT person_id, display_name FROM persons WHERE display_name IS NOT NULL"):
            cjk, latin = split_bilingual(r["display_name"])
            if cjk and latin and len(latin.split()) >= 2:
                latin_of.setdefault(norm(latin), set()).add(self.people.canonical(r["person_id"]))
        for r in self._live_named():
            name = r["display_name"].strip()
            if r["origin"] == "voice" or r["status"] or not re.fullmatch(r"[A-Za-z][A-Za-z .'\-]*", name):
                continue
            targets = {t for t in latin_of.get(norm(name), set()) if t != r["person_id"]}
            if len(targets) == 1:
                target = targets.pop()
                if self._mergeable(target, r["person_id"]) is None:
                    target = self._merge(target, r["person_id"], "rule_latin")
                    self._record(r["person_id"], name, "person", 0, target, "merged_latin", None)
                    n += 1
        # 2c. a contact remark ("周建国-装修") of exactly one live full-name record ("周建国").
        live = self._live_named()
        by_name = {}
        for r in live:
            by_name.setdefault(norm(r["display_name"]), []).append(r["person_id"])
        for r in live:
            name = r["display_name"].strip()
            base = name_base(name)
            if r["origin"] == "voice" or r["status"] or base == name or not re.fullmatch(r"[一-鿿]{2,4}", base):
                continue
            if not looks_like_person_name(base) or self._cand.short_form_surname(base):
                continue  # "纪老师-数学": a title form may be what tells two people apart
            targets = [t for t in by_name.get(norm(base), []) if t != r["person_id"]]
            if len(targets) == 1 and self._mergeable(targets[0], r["person_id"]) is None:
                self._merge(targets[0], r["person_id"], "rule_remark")
                self._record(r["person_id"], name, "person", 0, targets[0], "merged_remark", None)
                n += 1
        self.stats["merged_rules"] += n
        return n

    # ---- 3. person-resolve ---------------------------------------------------------------------

    def _links(self, pid: str) -> list[dict]:
        ids = self._aliases_of(pid)
        return [dict(r) for r in self.store.all(
            f"SELECT item_id, role FROM item_persons WHERE person_id IN ({','.join('?' * len(ids))})"
            f" AND role != 'mention'", ids)]

    def _unjudged(self, limit: int) -> list[dict]:
        out = []
        # A verdict dropped as stale (the record changed during the call) is asked again.
        checked = {r["person_id"]: r["name"] for r in self.store.all(
            "SELECT person_id, name FROM person_checks WHERE outcome != 'stale'")}
        for r in self._live_named():
            if r["origin"] == "voice" or r["status"] or checked.get(r["person_id"]) == r["display_name"]:
                continue
            links = self._links(r["person_id"])
            if not links:
                continue
            out.append(dict(r, links=links))
        out.sort(key=lambda r: (-len({x["item_id"] for x in r["links"]}), r["person_id"]))
        return out[:limit]

    def _events_of(self, item_ids: set[str]) -> set[str]:
        if not item_ids:
            return set()
        ids = sorted(item_ids)
        out: set[str] = set()
        for i in range(0, len(ids), 500):
            chunk = ids[i:i + 500]
            out |= {r["event_id"] for r in self.store.all(
                f"SELECT event_id FROM event_items WHERE removed=0 AND item_id IN ({','.join('?' * len(chunk))})", chunk)}
        return out

    def _lines(self, name: str, item_ids: list[str], n: int = LINES, reads: Optional[list] = None) -> list[str]:
        """Up to n lines naming `name` from these items; `reads` collects the ids of the items a line came from."""
        out: list[str] = []
        for iid in item_ids:
            rev = self.store.latest_revision(iid)
            item = self.store.get_item(iid, rev) if rev is not None else None
            if not item or item.get("purged"):
                continue
            line = _line_with(self._item_text(item), name_base(name) or name)
            if line and line not in out:
                out.append(line)
                if reads is not None:
                    reads.append(iid)
            if len(out) >= n:
                break
        return out

    def _elsewhere(self, name: str, linked: set[str], n: int = LINES, reads: Optional[list] = None) -> list[str]:
        """Lines of other items (not linked to this record) that contain its searchable name: the evidence for
        whether the name is also an ordinary word (common_word), since mentions will be searched by it."""
        forms = _searchable_names(name)
        out: list[str] = []
        seen_parents: set[str] = set()
        for form in forms:
            for r in self.store.all("SELECT item_id, text FROM items WHERE purged = 0 AND text LIKE ? LIMIT 60",
                                    (f"%{form}%",)):
                seg = self.store.segment_of(r["item_id"])
                key = seg["parent_id"] if seg else r["item_id"]
                if r["item_id"] in linked or key in linked or key in seen_parents:
                    continue
                seen_parents.add(key)
                line = _line_with(r["text"] or "", form)
                if line and line not in out:
                    out.append(line)
                    if reads is not None:
                        reads.append(r["item_id"])
                if len(out) >= n:
                    return out
        return out

    def _request(self, subject: dict) -> tuple[dict, dict, list[dict]]:
        roles = {x["role"] for x in subject["links"]}
        sources = sorted({{"text_speaker": "text", "transcript_speaker": "transcript", "sender": "screenshot",
                           "speaker": "voice"}.get(r, "text") for r in roles})
        items = sorted({x["item_id"] for x in subject["links"]})
        s_events = self._events_of(set(items))
        others = []
        for r in self._live_named():
            if r["person_id"] == subject["person_id"] or r["status"] in ("not_person", "role"):
                continue
            links = self._links(r["person_id"])
            o_items = {x["item_id"] for x in links}
            others.append({"person_id": r["person_id"], "name": r["display_name"], "items": len(o_items),
                           "shared_events": len(s_events & self._events_of(o_items)), "item_ids": sorted(o_items),
                           "handle": ""})
        cands = self._cand.candidates({"name": subject["display_name"]}, others, self.candidates_k)
        for n, c in enumerate(cands, 2):
            c["handle"] = f"P{n}"
        reads: list[str] = []  # the items whose lines the call shows (store.purge_item clears the run by them)
        data = {
            "person": {"handle": "P1", "name": subject["display_name"], "sources": sources, "items": len(items),
                       "lines": self._lines(subject["display_name"], items, reads=reads),
                       "elsewhere": self._elsewhere(subject["display_name"], set(items), reads=reads)},
            "candidates": [{"handle": c["handle"], "name": c["name"], "items": c["items"],
                            "lines": self._lines(c["name"], c["item_ids"], 1, reads=reads)} for c in cands],
            "owner": list(self.org.owner_aliases)[:6],
        }
        return data, {"candidates": [c["handle"] for c in cands], "reads": list(dict.fromkeys(reads))}, cands

    def _judge(self, pool=None) -> int:
        subjects = self._unjudged(self.max_calls)
        if not subjects:
            return 0
        skill = self.org.registry.for_job("person")
        prepared = []
        for s in subjects:
            data, ctx, cands = self._request(s)
            schema = json.loads(json.dumps(skill.schema))
            schema["properties"]["same_as"] = {"type": "string", "enum": [""] + ctx["candidates"]}
            prepared.append((s, data, ctx, cands, schema))

        def call(p):
            s, data, ctx, cands, schema = p
            return self.org.harness.run("person", data, context={"candidates": ctx["candidates"]}, schema=schema,
                                        subject=s["person_id"], reads=ctx["reads"])

        # On the model pool, each call is bound to this unlock session (a lock or wipe meanwhile: nothing written).
        results = list(pool.map(self.org.in_session(call), prepared)) if pool is not None \
            else [call(p) for p in prepared]
        for (s, data, ctx, cands, schema), res in zip(prepared, results):
            self.stats["calls"] += 1
            self._apply(s, cands, res)
        return len(prepared)

    def _record(self, pid: str, name: str, verdict: str, common: int, same_as: Optional[str], outcome: str,
                run_id: Optional[str], n_items: int = 0) -> None:
        self.store.x(
            "INSERT INTO person_checks(person_id, name, verdict, common_word, same_as, outcome, run_id, n_items, created_at)"
            " VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(person_id) DO UPDATE SET name=excluded.name, verdict=excluded.verdict,"
            " common_word=excluded.common_word, same_as=excluded.same_as, outcome=excluded.outcome, run_id=excluded.run_id,"
            " n_items=excluded.n_items, created_at=excluded.created_at",
            (pid, name, verdict, int(common), same_as, outcome, run_id, n_items, self.store.now()))

    def _apply(self, subject: dict, cands: list[dict], res) -> None:
        pid, name = subject["person_id"], subject["display_name"]
        n_items = len({x["item_id"] for x in subject["links"]})
        if not res.ok or not res.output:
            self.stats["invalid"] += 1
            # Judged again only after a rename; until then it stays a person that is never searched for.
            self._record(pid, name, "unknown", 1, None, "invalid", res.run_id, n_items)
            self.store.record_proposal(res.run_id, "person", pid, {"errors": res.errors}, "rejected", "invalid")
            return
        out = res.output
        kind, common = out["kind"], bool(out.get("common_word")) or out["kind"] != "person"
        row = self.people.get(pid)
        if row is None or row["merged_into"] or row["display_name"] != name:
            self._record(pid, name, kind, int(common), None, "stale", res.run_id, n_items)
            return
        outcome, target = kind, None
        with self.store.tx():
            if kind == "not_person":
                ids = self._aliases_of(pid)
                items = {r["item_id"] for r in self.store.all(
                    f"SELECT item_id FROM item_persons WHERE person_id IN ({','.join('?' * len(ids))})", ids)}
                self.store.x(f"DELETE FROM item_persons WHERE role != 'speaker' AND person_id IN ({','.join('?' * len(ids))})", ids)
                self.store.x("UPDATE persons SET status='not_person', seq=? WHERE person_id=?", (self.store.bump(), pid))
                self._touch_events(items)
                self.stats["not_person"] += 1
            elif kind == "role":
                self.store.x("UPDATE persons SET status='role', seq=? WHERE person_id=?", (self.store.bump(), pid))
                self.stats["role"] += 1
            else:
                self.stats["person"] += 1
                handle = out.get("same_as") or ""
                chosen = next((c for c in cands if c["handle"] == handle), None)
                if chosen is not None:
                    target = self.people.canonical(chosen["person_id"])
                    chosen_id = target
                    allowed, rule = self._cand.merge_allowed(name, chosen["name"], self._live_names())
                    why = None if allowed else rule
                    if why is None:
                        why = self._mergeable(target, pid)
                    if why is None:
                        self._merge(target, pid, "person_resolve")
                        outcome = f"merged_{rule}"
                        self.stats["merged_model"] += 1
                    else:
                        outcome = f"same_not_applied_{why}"
                        if why in ("voice",) or why.endswith("_ambiguous"):
                            qid = self.store.create_question(
                                "same_person", pid, target,
                                f"「{name}」和「{self.people.label(target)}」是同一个人吗？", self.people.max_open_questions)
                            if qid:
                                outcome = f"asked_{why}"
                                self.stats["asked"] += 1
            self._record(pid, name, kind, int(common), target, outcome, res.run_id, n_items)
        self.store.record_proposal(res.run_id, "person", pid,
                                   {"kind": kind, "common_word": common, "same_as": target, "reason": out.get("reason")},
                                   "applied", outcome)
