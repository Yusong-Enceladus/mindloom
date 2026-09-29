"""The organizing pipeline and background worker.

Per new item (processed in started_at order):
  (a') kind=file -> file-read: the file is parsed in a sandboxed child process (organizer/fileparse), its
      image parts go through image-read, and the file-read skill writes a one-line summary (+ key fields);
      from here on the reading text is the item's text (retrieval, event-assign, event-brief, item-split).
      A kind=image item with parent_item_id (a video keyframe) is read, then filed with its parent.
  (a) kind=image -> image-read skill: the image type (chat, chart, slide, handwriting, receipt, scan,
      label/sign, other), then that type's extraction (text lines, key fields, numbers, chat messages
      with sender/time) and a one-line gist, stored apart and never used as source text
  (b) embed the item text (local embedding server; degrades to no-similarity if it is down)
  (c) deterministic candidate retrieval (skills/event-assign/scripts/candidates.py), honouring decisions;
      the owner is never counted as a shared person
  (d) event-assign skill -> the model reports the item's concrete object, whether it is a matter at
      all, and per plausible candidate whether it is the same object. The action (attach / new /
      none = stay unfiled / ask) is derived deterministically from those facets
      (skills/event-assign/scripts/decide.py); an unconfirmed link is never attached.
      Questions have their own budgets: open same_event and same_person questions are capped
      separately, same_event questions per item-day and per target per day, and they expire.
  (e) event-brief skill for each touched event (title unless user-edited, status line, cited facts
      with plan/done states checked against their quoted evidence; items the brief flags as about
      another object are hidden from matching and may be asked about)
  (f) home-rank skill after each batch (and when the organizer's calendar day changes), then one
      deterministic floor: an open follow-up dated within 7 days never ranks below an event with
      only info / past items (skills/home-rank/scripts/floor.py)

Everything the model sees uses short stable handles (events E1.., items I1..) instead of UUIDs, and
model-visible time comes from the evidence (brief: the event's latest item) or the injected clock
(rank, question expiry) - never the wall clock during a replay.

A higher revision of an item replaces its content (the older revision stays stored as evidence) and
runs the pipeline again: persons are re-derived, the item is re-assigned unless a user placed it
(a model placement is re-decided; a singleton event keeps its id), and every touched event is
re-briefed. Each event link records the item revision it was decided on, so a retried job does not
re-assign twice.

Model output is applied as a proposal: it is re-checked against the current decisions under the
store lock right before it is written, so a user decision that arrived during a model call wins.
"""

from __future__ import annotations

import hashlib
import json
import logging
import math
import threading
import time
import uuid
from datetime import datetime, timedelta
from typing import Any, Optional

from .clients import EmbedClient, ModelUnavailable
from .clock import Clock
from . import transcripts
from .persons import People, speakers_in_text
from .file_read import read_file
from .image_read import read_image
from .skills import Harness, SkillRegistry
from .store import Store

log = logging.getLogger("organizer")

ASSIGN_TEXT_CHARS = 1500
ASSIGN_CAND_TEXT_CHARS = 300
BRIEF_TEXT_CHARS = 600
BRIEF_MAX_ITEMS = 30
# At scale 83% of briefs made a second call and 62% were still invalid after it (salvaged as partial):
# the retry rarely fixes a fact whose quote does not say it happened, an invented day or a relative date.
# Those errors are repaired deterministically (event-brief validate.salvage: drop the date, retag an
# unsupported done/in_progress fact as info or drop it, keep the previous line) without a second call;
# only format errors (and invalid JSON / schema) are retried.
BRIEF_NO_RETRY = frozenset({"unsupported_completion", "ungrounded_date", "relative_date", "length"})
EMBED_TEXT_CHARS = 2000
RANK_FACTS = 4


def excerpt(text: str, limit: int) -> str:
    text = (text or "").strip()
    return text if len(text) <= limit else text[: limit - 1] + "…"


class Organizer:
    def __init__(self, store: Store, registry: SkillRegistry, harness: Harness,
                 embedder: Optional[EmbedClient], *, max_open_questions: int = 2, candidates_k: int = 5,
                 rank_max_events: int = 40, rank_every_n_items: int = 10, job_max_attempts: int = 3,
                 clock: Optional[Clock] = None, ask_per_day: int = 2, ask_per_event_per_day: int = 1,
                 question_ttl_h: float = 72.0, recheck_threshold: float = 0.70, recheck_window_days: float = 7.0,
                 recheck_max: int = 2, owner_ids: tuple[str, ...] | list[str] = (),
                 owner_aliases: tuple[str, ...] | list[str] = ("我",), workers: int = 1, pipeline_lag: int = 2,
                 image_clients: Optional[dict] = None):
        self.store = store
        self.registry = registry
        self.harness = harness
        self.embedder = embedder
        self.clock: Clock = clock or store.clock
        # Open questions allowed per kind (same_event and same_person have separate budgets).
        self.max_open_questions = max_open_questions
        self.people = People(store, max_open_questions, owner_ids, owner_aliases)
        self.candidates_k = candidates_k
        self.rank_max_events = rank_max_events
        self.rank_every_n_items = rank_every_n_items
        self.job_max_attempts = job_max_attempts
        self.ask_per_day = ask_per_day
        self.ask_per_event_per_day = ask_per_event_per_day
        self.question_ttl_h = question_ttl_h
        self.recheck_threshold = recheck_threshold
        self.recheck_window_s = recheck_window_days * 86400
        self.recheck_max = recheck_max
        self.rank_on_day_change = True
        self._candidates = registry.script("event-assign", "candidates")
        self._decide = registry.script("event-assign", "decide")
        self._dates = registry.script("event-brief", "dates")
        # Wall-clock view of a capture time: the item's own offset, or ORGANIZER_TZ for a UTC stamp.
        self._local = self._dates.local_iso
        self._brief_rules = registry.script("event-brief", "validate")
        # image-read endpoints per image type ("detect" for the type step); unmapped types use the harness client.
        self.image_clients: dict = dict(image_clients or {})
        self._rank_floor = registry.script("home-rank", "floor")
        self._units = registry.script("item-split", "units")
        # Pipeline mode (organizer/pipeline.py, workers > 1) runs model calls on a bounded pool and briefs
        # touched events at a fixed lag instead of inline; workers = 1 is the serial pipeline.
        self.workers = max(1, int(workers))
        self.defer_briefs = self.workers > 1
        self.pipeline = None
        if self.workers > 1:
            from .pipeline import Pipeline
            self.pipeline = Pipeline(self, self.workers, pipeline_lag)
        self._wake = threading.Event()
        self._feat_cache: dict[str, tuple] = {}
        self._items_since_rank = 0
        self._rank_dirty = False
        self._last_rank_day: Optional[str] = None
        self.last_error: Optional[str] = None
        self.clock_warning: Optional[str] = None
        self._restore_replay_clock()

    def _restore_replay_clock(self) -> None:
        """A replay clock restarts at the latest item already processed, so decisions and answers
        that arrive after a restart (before the next item) have a semantic time."""
        if self.clock.mode != "replay":
            return
        row = self.store.one(
            "SELECT COALESCE(li.ended_at, li.started_at) AS t FROM latest_items li"
            " JOIN jobs j ON j.item_id = li.item_id AND j.revision = li.revision AND j.state = 'done'"
            " ORDER BY COALESCE(li.ended_ts, li.started_ts) DESC LIMIT 1")
        if row:
            self.clock.observe(row["t"])

    # ---- intake -------------------------------------------------------------------

    def ingest(self, items: list[dict], images: list[Optional[bytes]]) -> tuple[int, int]:
        accepted = duplicates = 0
        for item, image in zip(items, images):
            if self.store.insert_item(item, image):
                accepted += 1
            else:
                duplicates += 1
        if accepted:
            self.wake()
        return accepted, duplicates

    def wake(self) -> None:
        self._wake.set()

    # ---- worker -------------------------------------------------------------------

    def run_worker(self, stop: threading.Event) -> None:
        self.store.reset_running_jobs()
        while not stop.is_set():
            try:
                did = self.step()
            except ModelUnavailable as exc:
                self.last_error = f"model_unavailable: {exc}"
                log.warning("model unavailable: %s", exc)
                stop.wait(5.0)
                continue
            except Exception as exc:  # keep the worker alive; the error is recorded on the job
                self.last_error = repr(exc)
                log.exception("worker step failed")
                stop.wait(1.0)
                continue
            if not did:
                self._wake.wait(1.0)
                self._wake.clear()

    def step(self) -> bool:
        """Do one unit of work. Returns False when there is nothing to do."""
        if self.pipeline is not None:
            return self.pipeline.step()
        job = self.store.claim_next_job()
        if job:
            self._run_job(job)
            return True
        ev = self.store.one("SELECT event_id FROM events WHERE needs_brief=1 AND deleted=0"
                            " ORDER BY updated_ts, handle LIMIT 1")
        if ev:
            self.brief(ev["event_id"])
            return True
        if self._rank_dirty or self._day_changed():
            self.rank()
            return True
        self._expire_questions()  # an idle organizer still retires questions past their TTL
        return False

    def _today(self) -> Optional[str]:
        try:
            return self._local(self.clock.now())[:10]
        except RuntimeError:  # a replay clock before its first item
            return None

    def _day_changed(self) -> bool:
        """Deadlines move with the calendar: re-rank once a day even when no item arrives."""
        if not self.rank_on_day_change or self._last_rank_day is None:
            return False
        today = self._today()
        return today is not None and today != self._last_rank_day

    def drain(self, max_steps: int = 10_000) -> int:
        steps = 0
        while steps < max_steps and self.step():
            steps += 1
        return steps

    def _run_job(self, job: dict) -> None:
        item_id, revision = job["item_id"], job["revision"]
        try:
            self.process_item(item_id, revision, reason=job.get("reason"))
        except ModelUnavailable as exc:
            self.store.finish_job(item_id, revision, "queued", str(exc), "model_unavailable", delay_s=10)
            self.store.x("UPDATE jobs SET attempts=MAX(attempts-1,0) WHERE item_id=? AND revision=?", (item_id, revision))
            raise
        except Exception as exc:
            log.exception("job %s/%s failed", item_id, revision)
            if job["attempts"] >= self.job_max_attempts:
                self.store.finish_job(item_id, revision, "failed", repr(exc), "internal")
            else:
                self.store.finish_job(item_id, revision, "queued", repr(exc), "internal", delay_s=2)
            return
        self.store.finish_job(item_id, revision, "done")
        self._items_since_rank += 1
        self._rank_dirty = True
        if self._items_since_rank >= self.rank_every_n_items:
            if self.pipeline is not None:
                self._items_since_rank = 0
                self.pipeline.launch_rank()
            else:
                self.rank()

    # ---- item pipeline --------------------------------------------------------------

    def process_item(self, item_id: str, revision: int, reason: Optional[str] = None) -> None:
        if self.store.latest_revision(item_id) != revision:
            return  # superseded by a newer revision; that job does the work
        seg = self.store.segment_of(item_id)
        if seg is not None and not seg["active"]:
            return  # a segment the parent's latest split no longer has
        item = self.store.get_item(item_id, revision)
        self.clock.observe(item.get("ended_at") or item["started_at"])
        self._check_clock(item)
        self._expire_questions()

        # (a) image-read / file-read
        derived = self.read_item(item)
        messages = derived.get("messages") or []

        # persons (voice persons from the Mac, chat senders from the screenshot, transcript speakers)
        self._record_item_persons(item, messages, seg)

        # (a'') a keyframe of a video (or an extra frame of a GIF) is filed with the media item it came from
        if seg is None and (item.get("meta") or {}).get("parent_item_id"):
            self._after_placement(self._follow_parent(item))
            return

        # (a') item-split: an item covering several matters is organized as one child item per segment.
        # A user placement (or a user unfiling) of the whole item is final: it is never split.
        pre_touched: list[str] = []
        if seg is None:
            link = self.store.current_event_link(item_id)
            user_placed = link is not None and not link["deleted"] and link["attached_by"] != "model"
            user_unfiled = self.store.one("SELECT 1 FROM unfiled WHERE item_id=? AND reason='user'", (item_id,))
            segments = [] if user_placed or user_unfiled else self.split_plan(item, derived)
            if segments:
                self._after_placement(self._apply_split(item, segments))
                return
            if self.store.segments_of(item_id):
                pre_touched = self._retire_children(item_id)  # one matter now: the item is filed whole

        if seg is not None and seg.get("no_matter"):
            # item-split marked this stretch as no matter at all: it stays unfiled, with no assign call.
            self._after_placement(self._unfile_no_matter(item))
            return

        body = self.match_body(item, derived)

        # (b) embedding
        embedding = self.embed_item(item, body, derived)

        # (c)+(d) assignment. A user placement is final; a model placement made for an older
        # revision is decided again for this revision's content. An unfiled item is decided again
        # when it is re-queued (a revision or a recheck after a matching event appeared).
        link = self.store.current_event_link(item_id)
        touched: list[str] = []
        unfiled = self.store.one("SELECT reason FROM unfiled WHERE item_id=?", (item_id,))
        if link is None and unfiled and unfiled["reason"] == "removed_by_user":
            # Removed by the user and waiting unfiled: a recheck or a new revision may attach it or
            # ask, but never turn it into a one-item event.
            reason = "removed_by_user"
        if link is None and unfiled and unfiled["reason"] == "user":
            pass  # the user took it out of every event; only the user files it again
        elif link is None:
            placed = self.assign(item, body, embedding, reason=reason)
            if placed:
                touched.append(placed)
        elif link["deleted"]:
            pass
        elif link["attached_by"] == "model" and (link["item_revision"] or 0) < revision:
            placed = self.assign(item, body, embedding, current=link, reason=reason)
            touched = [placed] if placed else []
            if link["event_id"] != placed:
                touched.append(link["event_id"])  # the item left it: re-brief (or retire if now empty)
        else:
            self.store.recompute_event(link["event_id"])
            touched.append(link["event_id"])

        # (e) brief touched events
        self._after_placement(pre_touched + [e for e in touched if e not in pre_touched])
        self.requeue_frames(item_id)

    BACKFILL_WARN_S = 2 * 86400

    def _check_clock(self, item: dict) -> None:
        """Warn once when a wall-clock organizer is fed a historical stream: questions would never expire
        and the question budget would stay full (the 2026-09-28 scale runs). Use ORGANIZER_CLOCK=replay."""
        if self.clock_warning or self.clock.mode != "wall" or item.get("reason") == "segment":
            return
        try:
            lag = time.time() - float(item.get("ended_ts") or item["started_ts"])
        except (TypeError, ValueError, KeyError):
            return
        if lag > self.BACKFILL_WARN_S:
            self.clock_warning = (f"wall clock on a historical stream (an item captured {lag / 86400:.0f} days ago); "
                                  "set ORGANIZER_CLOCK=replay for backfills")
            log.warning(self.clock_warning)

    def _unfile_no_matter(self, item: dict) -> list[str]:
        """Leave a no-matter segment unfiled. A user placement stays; a model placement from an earlier
        split is undone (returns that event, to re-brief)."""
        item_id = item["item_id"]
        link = self.store.current_event_link(item_id)
        if link is not None and (link["deleted"] or link["attached_by"] != "model"):
            return []
        if self.store.one("SELECT 1 FROM unfiled WHERE item_id=? AND reason='user'", (item_id,)):
            return []
        self._unfile(item, None, link, "none")
        self.store.record_proposal(None, "assign", item_id, {"rule": "no_matter_segment"}, "applied",
                                   "item-split: no matter; left unfiled")
        return [link["event_id"]] if link else []

    def prefetch(self, item_id: str, revision: int) -> None:
        """Item-local model work ahead of the serial stage (pipeline mode, on a pool thread): image-read,
        item-split and the embedding, each stored with the revision. Any failure is left for process_item
        to redo inline, so this never raises."""
        try:
            if self.store.latest_revision(item_id) != revision:
                return
            seg = self.store.segment_of(item_id)
            if seg is not None and not seg["active"]:
                return
            item = self.store.get_item(item_id, revision)
            derived = self.read_item(item)
            if seg is None and self.split_plan(item, derived):
                return  # the segments are embedded as their own jobs come up
            if item.get("text") or item["kind"] in ("image", "file"):
                # A voice-only item's body names its speakers, which the serial stage may still rename:
                # it is embedded there, in order.
                self.embed_item(item, self.match_body(item, derived), derived)
        except Exception as exc:  # noqa: BLE001 - redone inline by process_item
            log.info("prefetch of %s/%s left to the serial stage: %r", item_id, revision, exc)

    def _after_placement(self, touched: list[str]) -> None:
        """Brief the touched events now (serial mode). In pipeline mode they stay needs_brief=1 and the
        pipeline briefs them concurrently at a fixed lag (organizer/pipeline.py)."""
        if self.defer_briefs:
            return
        for event_id in dict.fromkeys(touched):
            self.brief(event_id)

    @staticmethod
    def _reading_entry(r: dict) -> dict:
        meta = r.get("reading") or {}
        if meta.get("source") == "file-read":
            # A file's reading (contract "file"): the extracted text (tables as markdown, image parts replaced
            # by their readings), a one-line summary, key fields (each value is in `text`), counts, the
            # attachments / archive entries read, and `error` when the file could not be read.
            out = {"revision": r["revision"], "source": "file-read", "type": meta.get("type") or "data",
                   "text": r["derived_text"] or "", "summary": r.get("summary") or "",
                   "fields": [{k: f.get(k, "") for k in ("key", "label", "value")}
                              for f in meta.get("fields") or [] if isinstance(f, dict)],
                   "counts": meta.get("counts") or {},
                   "attachments": [{k: a.get(k, "") for k in ("filename", "type", "summary")}
                                   for a in meta.get("attachments") or [] if isinstance(a, dict)],
                   "doc_kind": meta.get("doc_kind") or "",
                   "messages": [], "numbers": [], "run_id": r["screenshot_run_id"]}
            if meta.get("error"):
                out["error"] = meta["error"]
            return out
        return {"revision": r["revision"], "source": "image-read" if meta else "screenshot-read",
                "type": meta.get("type") or _legacy_reading_type(r),
                "text": r["derived_text"] or "",
                "summary": r.get("summary") or "",
                "messages": [{k: m.get(k) for k in ("sender", "is_self", "time", "text")}
                             for m in r["messages"] if isinstance(m, dict)],
                "fields": [{k: f.get(k, "") for k in ("key", "label", "value")}
                           for f in meta.get("fields") or [] if isinstance(f, dict)],
                "numbers": [{k: n.get(k, "") for k in ("label", "value")}
                            for n in meta.get("numbers") or [] if isinstance(n, dict)],
                "run_id": r["screenshot_run_id"]}

    def read_item(self, item: dict) -> dict:
        """The item's reading for this revision (image-read or file-read), made once. Returns derived."""
        if item["kind"] == "file":
            return self.read_file(item)
        return self.read_image(item)

    def read_file(self, item: dict) -> dict:
        """file-read for a file item's revision, once (stored with the revision). Returns derived."""
        item_id, revision = item["item_id"], item["revision"]
        derived = self.store.get_derived(item_id, revision)
        if derived.get("screenshot_run_id"):
            return derived
        blob = self.store.get_blob(item_id, revision) if item["has_image"] else None
        meta = dict(item.get("meta") or {})
        meta.setdefault("captured_at", item["started_at"])
        meta["source_app"] = item["source_app"]
        meta["sha256"] = item["sha256"]
        if not meta.get("local_text") and item.get("text"):
            meta["local_text"] = item["text"]
        res = read_file(self.harness, blob["data"] if blob else None, meta, subject=item_id,
                        clients=self.image_clients)
        # screenshot_run_id marks "read" (and publishes the reading); a reading made without a model call
        # gets a stable local id.
        run_id = res.run_id or f"file-read:{item['sha256'][:24]}:{revision}"
        self.store.save_derived(item_id, revision, derived_text=res.text, summary=res.summary, messages=[],
                                screenshot_run_id=run_id, reading=res.reading())
        return self.store.get_derived(item_id, revision)

    def _follow_parent(self, item: dict) -> list[str]:
        """File a keyframe with its media item: into the parent's event while the parent has one (a user's
        own placement of the frame is kept); nowhere while the parent has none (it follows once it is filed)."""
        item_id = item["item_id"]
        parent_id = item["meta"]["parent_item_id"]
        touched: list[str] = []
        with self.store.tx():
            own = self.store.current_event_link(item_id)
            if own is not None and not own["deleted"] and own["attached_by"] != "model":
                self.store.recompute_event(own["event_id"])
                return [own["event_id"]]
            if own is not None and own["deleted"]:
                return []
            parent = self.store.current_event_link(parent_id)
            target = parent["event_id"] if parent is not None and not parent["deleted"] else None
            if own is not None and own["event_id"] != target:
                self.store.detach(own["event_id"], item_id, "parent_moved")
                touched.append(own["event_id"])
            if target is not None:
                if own is None or own["event_id"] != target:
                    self.store.attach(target, item_id, "model", None, item["revision"])
                else:
                    self.store.mark_placed(target, item_id, item["revision"])
                touched.append(target)
            self.store.clear_unfiled(item_id)
        return touched

    def frames_of(self, parent_id: str) -> list[str]:
        return [r["item_id"] for r in self.store.all(
            "SELECT DISTINCT item_id FROM items WHERE meta IS NOT NULL AND json_extract(meta, '$.parent_item_id') = ?",
            (parent_id,))]

    def requeue_frames(self, parent_id: str) -> None:
        """A media item was (re)placed: its keyframes follow it."""
        for frame_id in self.frames_of(parent_id):
            link = self.store.current_event_link(frame_id)
            parent = self.store.current_event_link(parent_id)
            want = parent["event_id"] if parent is not None and not parent["deleted"] else None
            have = link["event_id"] if link is not None and not link["deleted"] else None
            if want != have and not (link is not None and link["attached_by"] != "model"):
                self.store.requeue_latest(frame_id, "parent_placed")
                self.wake()

    def read_image(self, item: dict) -> dict:
        """image-read for an image item's revision, once (stored with the revision). Returns derived."""
        item_id, revision = item["item_id"], item["revision"]
        derived = self.store.get_derived(item_id, revision)
        if item["kind"] == "image" and item["has_image"] and not derived.get("screenshot_run_id"):
            blob = self.store.get_blob(item_id, revision)
            try:
                res = read_image(self.harness, blob["data"],
                                 {"source_app": item["source_app"].get("name", ""), "captured_at": item["started_at"]},
                                 subject=item_id, clients=self.image_clients)
            except ValueError as exc:
                # The endpoint rejected the request (HTTP 4xx, e.g. a text-only model). Retrying cannot help;
                # organize the item without its text instead of failing the job and never placing it.
                # Nothing is saved, so a later reprocess with a vision model reads it.
                log.warning("image-read rejected for %s: %s", item_id, exc)
                res = None
            if res is not None:
                # The transcription (what the image shows) and the model's own one-line gist are kept apart:
                # only the transcription is source text (quotes, dates, the Mac's export).
                r = res.reading
                self.store.save_derived(
                    item_id, revision, derived_text=r["text"], summary=r["gist"], messages=r["messages"],
                    screenshot_run_id=res.run_id,
                    reading={"type": res.image_type, "fields": r["fields"], "numbers": r["numbers"],
                             "detected": res.detected, "detect_run_id": res.detect_run_id,
                             "sanitized": res.sanitized, "ok": res.ok})
                derived = self.store.get_derived(item_id, revision)
        return derived

    def embed_item(self, item: dict, body: str, derived: Optional[dict] = None) -> Optional[list[float]]:
        """The item's embedding for this revision, computed once (degrades to None when the server is down)."""
        derived = derived if derived is not None else self.store.get_derived(item["item_id"], item["revision"])
        embedding = derived.get("embedding")
        if embedding is None and self.embedder is not None and body.strip():
            try:
                embedding = self.embedder.embed([self.embed_doc(item, body)])[0]
                self.store.save_derived(item["item_id"], item["revision"], embedding=embedding,
                                        embed_model=self.embedder.model_id)
            except ModelUnavailable as exc:
                log.warning("embedding unavailable, retrieval uses time/persons/source only: %s", exc)
                embedding = None
        return embedding

    @staticmethod
    def embed_doc(item: dict, body: str) -> str:
        return f"{item['source_app'].get('name', '')}\n{excerpt(body, EMBED_TEXT_CHARS)}"

    # ---- item-split ---------------------------------------------------------------

    def organizing_text(self, item: dict, derived: Optional[dict] = None) -> str:
        """The item's own text, or for a file item its reading text (what split / assign / brief read)."""
        if item.get("kind") == "file":
            derived = derived if derived is not None else self.store.get_derived(item["item_id"], item["revision"])
            return derived.get("derived_text") or ""
        return item.get("text") or ""

    def transcript_of(self, item: Optional[dict]) -> Optional[dict]:
        if not item or item.get("kind") == "image":
            return None
        text = self.organizing_text(item)
        # A meeting transcript saved as a file (txt / docx / srt export) reads like the pasted one.
        return transcripts.parse(text) if text else None

    def split_plan(self, item: dict, derived: Optional[dict] = None) -> list[dict]:
        """Segments [{seg_id, start, end, gist}] for this revision, or [] (one matter / not eligible).

        Decided once per revision and stored (idempotent under retries): a cheap pre-filter first (length
        and unit count, skills/item-split/scripts/units.py), then the item-split skill. Output that stays
        invalid after the retry leaves the item whole."""
        item_id, revision = item["item_id"], item["revision"]
        if self.store.segment_of(item_id) is not None:
            return []  # a segment is never split again
        derived = derived if derived is not None else self.store.get_derived(item_id, revision)
        stored = derived.get("split")
        if isinstance(stored, dict):
            return list(stored.get("segments") or [])
        text = self.organizing_text(item, derived)
        transcript = self.transcript_of(item)
        units = self._units.build_units(text, transcript["turns"] if transcript else None) if text else []
        split_kind = "document" if item["kind"] == "file" else item["kind"]
        if not text or not self._units.prefilter(text, len(units), split_kind, transcript is not None):
            self.store.save_derived(item_id, revision, split={"segments": [], "skipped": "prefilter"})
            return []
        ids = [u["u"] for u in units]
        data = self._units.build_data(split_kind, item["source_app"].get("name", ""), self._local(item["started_at"]),
                                      units, transcript["format"] if transcript else "")
        schema = _deepcopy(self.registry.for_job("split").schema)
        seg_props = schema["properties"]["segments"]["items"]["properties"]
        _enum(seg_props["from"], ids)
        _enum(seg_props["to"], ids)
        try:
            res = self.harness.run("split", data, context={"unit_ids": ids}, schema=schema, subject=item_id)
        except ValueError as exc:  # the endpoint rejected the request: organize the item whole
            log.warning("item-split rejected for %s: %s", item_id, exc)
            return []
        out, status = (res.output, "applied") if res.ok else (None, "rejected")
        if out is None:
            validator = self.registry.for_job("split").validator
            out = self._units.salvage(res.candidate, res.errors, lambda o: validator(o, {"unit_ids": ids}))
            status = "salvaged" if out else status
        segments = self._units.segments_from_output(out, units) if out else []
        self.store.save_derived(item_id, revision, split={
            "segments": segments, "run_id": res.run_id, "ok": res.ok, "matters": (out or {}).get("matters") or []})
        self.store.record_proposal(res.run_id, "split", item_id,
                                   {"segments": segments, "units": len(units), "errors": res.errors}, status,
                                   f"{len(segments)} segments" if segments else "whole")
        return segments

    def _apply_split(self, item: dict, segments: list[dict]) -> list[str]:
        """Make one child item per segment (revision = the parent's), retire segments the new split no
        longer has, and take the parent itself out of any model-made event. Returns touched events."""
        item_id = item["item_id"]
        touched: list[str] = []
        base = datetime.fromisoformat(item["started_at"])
        parent_text = self.organizing_text(item)
        with self.store.tx():
            wanted = {segment_child_id(item_id, seg["seg_id"]): seg for seg in segments}
            for old in self.store.segments_of(item_id):
                if old["child_id"] not in wanted:
                    touched += self._retire_child(old["child_id"])
            link = self.store.current_event_link(item_id)
            if link is not None and not link["deleted"]:
                self.store.detach(link["event_id"], item_id, "split")
                touched.append(link["event_id"])
            self.store.clear_unfiled(item_id)
            self.store.expire_questions_touching([item_id])
            for index, (child_id, seg) in enumerate(wanted.items()):
                self.store.upsert_segment(child_id, item_id, item["revision"], seg, index)
                text = parent_text[seg["start"]:seg["end"]]
                digest = hashlib.sha256(f"{item['sha256']}#{seg['seg_id']}#{seg['start']}#{seg['end']}".encode())
                self.store.insert_item({
                    # A file's segments are text slices of its reading.
                    "item_id": child_id, "revision": item["revision"],
                    "kind": "document" if item["kind"] == "file" else item["kind"],
                    "source_app": item["source_app"],
                    # Keeps the parent's time; a millisecond per segment keeps the segments in text order.
                    "started_at": (base + timedelta(milliseconds=index + 1)).isoformat(),
                    "ended_at": item.get("ended_at"), "text": text, "segments": None, "persons": None,
                    "sha256": digest.hexdigest()}, None, reason="segment")
        self.wake()
        return touched

    def _retire_child(self, child_id: str) -> list[str]:
        touched = []
        link = self.store.current_event_link(child_id)
        if link is not None and not link["deleted"]:
            self.store.detach(link["event_id"], child_id, "resplit")
            touched.append(link["event_id"])
        self.store.clear_unfiled(child_id)
        self.store.expire_questions_touching([child_id])
        self.store.retire_segment(child_id)
        return touched

    def _retire_children(self, parent_id: str) -> list[str]:
        touched: list[str] = []
        with self.store.tx():
            for seg in self.store.segments_of(parent_id):
                touched += self._retire_child(seg["child_id"])
        return touched

    def _expire_questions(self) -> None:
        try:
            now_ts = self.clock.now().timestamp()
        except RuntimeError:
            return
        self.store.expire_stale_questions(now_ts, self.question_ttl_h)

    def _record_item_persons(self, item: dict, messages: list[dict], segment: Optional[dict] = None) -> None:
        # The current revision's persons replace whatever an earlier revision contributed.
        self.store.x("DELETE FROM item_persons WHERE item_id=?", (item["item_id"],))
        names = {p["person_id"]: p.get("display_name") for p in item.get("persons") or []}
        for seg in item.get("segments") or []:
            if seg.get("person_id") and seg["person_id"] not in names:
                names[seg["person_id"]] = None
        for pid, name in names.items():
            if self.people.upsert_voice(pid, name):
                self.people.link_all_chat_persons()
            self.people.add_item_person(item["item_id"], pid, "speaker")
        senders = [((msg.get("sender") or "").strip(), "screenshot", bool(msg.get("is_self"))) for msg in messages]
        transcript = self.transcript_of(item)
        if segment is not None:
            # A segment's speakers are the parent transcript's turns inside the segment.
            parent_tx = self.transcript_of(self.store.get_item(segment["parent_id"]))
            if parent_tx:
                transcript = {"format": parent_tx["format"],
                              "turns": [t for t in parent_tx["turns"]
                                        if t["start"] < segment["end"] and t["end"] > segment["start"]]}
        if transcript:
            # A meeting transcript export (Tencent Meeting / Feishu / Zoom / VTT / SRT): its speakers become
            # people with origin "transcript", through the same near-name same_person path.
            senders += [(name, "transcript", False) for name in transcripts.speakers(transcript)]
        elif item["kind"] == "text" and item.get("text"):
            # Pasted chat text ("周经理：…" lines, "周经理 10:05" bylines) names its speakers the same way a
            # screenshot does; they go through the same person path.
            senders += [(name, "text", False) for name in speakers_in_text(item["text"])]
        roles = {"screenshot": "sender", "text": "text_speaker", "transcript": "transcript_speaker"}
        for sender, source, is_self in senders:
            if is_self or not sender or sender == "对方" or self.people.is_owner_name(sender):
                continue
            pid = self.people.upsert_chat(sender, source)
            self.people.add_item_person(item["item_id"], pid, roles[source])
            self.people.link_chat_person(pid)

    def item_body(self, item: dict, derived: Optional[dict] = None) -> str:
        if item.get("text") and item.get("kind") != "file":
            name = (item.get("meta") or {}).get("filename")
            # A file too big to send arrives as kind=text with its extracted text and its name.
            return f"文件：{name}\n{item['text']}" if name and item["kind"] == "text" else item["text"]
        if item.get("segments"):
            lines = []
            for seg in item["segments"]:
                who = self.people.label(seg["person_id"]) if seg.get("person_id") else "说话人"
                lines.append(f"{who}：{seg['text']}")
            return "\n".join(lines)
        derived = derived if derived is not None else self.store.get_derived(item["item_id"], item["revision"])
        body = derived.get("derived_text") or ""
        if item.get("kind") == "file":
            name = (item.get("meta") or {}).get("filename") or ""
            return f"文件：{name}\n{body}" if name else body
        return body

    def reading_summary(self, item: dict, derived: Optional[dict] = None) -> str:
        """The image-read gist of an image item / the file-read summary of a file: the model's words, not
        source text."""
        if item.get("kind") not in ("image", "file") or (item.get("kind") == "image" and (item.get("text") or item.get("segments"))):
            return ""
        derived = derived if derived is not None else self.store.get_derived(item["item_id"], item["revision"])
        return (derived.get("summary") or "").strip()

    def match_body(self, item: dict, derived: Optional[dict] = None) -> str:
        """What retrieval and event-assign read: for a screenshot, its summary line then its transcription
        (the same text they read before the two were stored apart)."""
        derived = derived if derived is not None else (
            self.store.get_derived(item["item_id"], item["revision"]) if item.get("kind") in ("image", "file") else {})
        body = self.item_body(item, derived)
        summary = self.reading_summary(item, derived)
        return f"{summary}\n{body}" if summary and body else (summary or body)

    def other_persons(self, item_id: str, for_matching: bool = False) -> list[str]:
        """Non-owner persons of an item. For matching (retrieval, event-assign, rechecks) people named in
        pasted text are left out: they are the item's own words, which the model already reads, and a
        shared name there says who was talking, not which matter it is (the same contractor, two jobs)."""
        return self.people.others(self.people.item_person_ids(
            item_id, exclude_roles=("text_speaker", "transcript_speaker") if for_matching else ()))

    def item_view(self, item: dict, limit: int) -> dict:
        """The item as event-assign sees it (matching persons only)."""
        return {
            "item_id": self.store.item_handle(item["item_id"]),
            "kind": item["kind"],
            "source_app": item["source_app"].get("name", ""),
            "started_at": self._local(item["started_at"]),
            "persons": [self.people.label(p) for p in self.other_persons(item["item_id"], for_matching=True)],
            "text": excerpt(self.match_body(item), limit),
        }

    def brief_item_view(self, item: dict) -> dict:
        text = excerpt(self.item_body(item), BRIEF_TEXT_CHARS)
        view = {
            "item_id": self.store.item_handle(item["item_id"]),
            "kind": item["kind"],
            "source_app": item["source_app"].get("name", ""),
            "captured_at": self._dates.format_captured(item["started_at"]),
            "persons": [self.people.label(p) for p in self.other_persons(item["item_id"])],
            "text": text,
            # Exact days, then spans the source gave without a day (下周 -> from..to).
            "dates": self._dates.resolve(text, item["started_at"]) + self._dates.resolve_ranges(text, item["started_at"]),
        }
        summary = self.reading_summary(item)
        if summary:
            view["reading_summary"] = summary  # labelled, and never part of the evidence text
        return view

    # ---- (c) retrieval + (d) event-assign ---------------------------------------------

    def event_features(self, exclude_item: Optional[str] = None) -> list[dict]:
        """Retrieval features of every live event (centroid, time span, persons, sources), in handle order.

        Cached per event and recomputed only when the event changed (its seq moves on every membership,
        revision or brief update) or any person changed (merges and names move persons.seq), so a stream of
        thousands of items does not re-read every embedding for every new item. The item being assigned
        is left out of its own event's features."""
        persons_v = int(self.store.scalar("SELECT COALESCE(MAX(seq), 0) FROM persons") or 0)
        live = self.store.all("SELECT event_id, seq FROM events WHERE deleted = 0 ORDER BY handle")
        out = []
        for e in live:
            key = (e["seq"], persons_v)
            cached = self._feat_cache.get(e["event_id"])
            if cached is None or cached[0] != key:
                cached = (key, self._event_feature(e["event_id"]))
                self._feat_cache[e["event_id"]] = cached
            feat = cached[1]
            if feat is not None and exclude_item is not None and exclude_item in feat["item_ids"]:
                feat = self._event_feature(e["event_id"], exclude_item)
            if feat is not None:
                out.append(feat)  # shared with the cache: callers only read it
        if len(self._feat_cache) > len(live) + 64:
            alive = {e["event_id"] for e in live}
            self._feat_cache = {k: v for k, v in self._feat_cache.items() if k in alive}
        return out

    def _event_feature(self, event_id: str, exclude_item: Optional[str] = None) -> Optional[dict]:
        # Off-anchor members (flagged by event-brief) do not shape an event's identity for matching.
        rows = self.store.all(
            "SELECT ei.event_id, e.handle, li.item_id, li.source_app, li.started_ts,"
            " COALESCE(li.ended_ts, li.started_ts) AS end_ts, d.embedding"
            " FROM event_items ei JOIN events e ON e.event_id = ei.event_id AND e.deleted = 0"
            " JOIN latest_items li ON li.item_id = ei.item_id"
            " LEFT JOIN item_derived d ON d.item_id = li.item_id AND d.revision = li.revision"
            " WHERE ei.event_id = ? AND ei.removed = 0 AND ei.off_anchor = 0 ORDER BY li.started_ts, li.item_id",
            (event_id,))
        f: Optional[dict] = None
        vecs: list[list[float]] = []
        for r in rows:
            if r["item_id"] == exclude_item:
                continue
            if f is None:
                f = {"event_id": r["event_id"], "order": r["handle"] or 0, "first_ts": r["started_ts"],
                     "last_ts": r["end_ts"], "person_ids": set(), "sources": set(), "item_ids": []}
            f["first_ts"] = min(f["first_ts"], r["started_ts"])
            f["last_ts"] = max(f["last_ts"], r["end_ts"])
            f["sources"].add(_source_key(json.loads(r["source_app"])))
            f["item_ids"].append(r["item_id"])
            if r["embedding"]:
                vecs.append(json.loads(r["embedding"]))
            f["person_ids"].update(self.other_persons(r["item_id"], for_matching=True))
        if f is None:
            return None
        vecs = [v for v in vecs if v]
        if vecs:
            dim = len(vecs[0])
            f["centroid"] = [sum(v[i] for v in vecs) / len(vecs) for i in range(dim)]
            f["centroid_norm"] = math.sqrt(sum(x * x for x in f["centroid"]))
        else:
            f["centroid"] = None
        f["person_ids"] = sorted(f["person_ids"])
        f["sources"] = sorted(f["sources"])
        return f

    def assign(self, item: dict, body: str, embedding: Optional[list[float]],
               current: Optional[dict] = None, reason: Optional[str] = None) -> Optional[str]:
        """Place an item. With `current` (its model-made link), decide again for a new revision.

        Returns the event the item ends up in, or None if it stays unfiled or a user decision
        removed it meanwhile.
        """
        item_id = item["item_id"]
        feats = {f["event_id"]: f for f in self.event_features(exclude_item=item_id)}
        query = {
            "embedding": embedding,
            "ts": item["started_ts"],
            "person_ids": self.other_persons(item_id, for_matching=True),
            "source": _source_key(item["source_app"]),
        }
        forbidden = self.store.forbidden_events_for(item_id)
        cands = self._candidates.rank_candidates(query, feats.values(), forbidden, self.candidates_k)
        handle_to_event: dict[str, str] = {}
        cand_views, cand_item_handles, cand_meta = [], [], []
        for rank_i, c in enumerate(cands):
            ev = self.store.get_event(c["event_id"])
            h = self.store.event_handle(c["event_id"])
            handle_to_event[h] = c["event_id"]
            members = [i for i in self.store.matching_item_ids(c["event_id"]) if i != item_id]
            first_view = None
            recent_views = []
            for n, iid in enumerate(members[:1] + members[1:][-2:]):
                it = self.store.get_item(iid)
                if not it:
                    continue
                view = self.item_view(it, ASSIGN_CAND_TEXT_CHARS)
                cand_item_handles.append(view["item_id"])
                if n == 0:
                    first_view = view
                else:
                    recent_views.append(view)
            cand_views.append({
                "event_id": h,
                "anchor": ev["anchor"] or ev["title"],
                "title": ev["title"],
                "status_line": ev["status_line"],
                "started_at": ev["started_at"],
                "updated_at": ev["updated_at"],
                "item_count": len(members),
                "persons": [self.people.label(p) for p in feats[c["event_id"]]["person_ids"]],
                "first_item": first_view,
                "recent_items": recent_views,
                "retrieval": {k: c[k] for k in ("score", "similarity", "time", "same_source")}
                | {"shared_persons": [self.people.label(p) for p in c["shared_persons"]]},
            })
            cand_meta.append({"event_id": c["event_id"], "handle": h, "rank": rank_i, "score": c["score"],
                              "similarity": c["similarity"], "margin": c.get("margin"),
                              # object guard text: the fixed anchor, the current title and the seed item
                              "anchor": " ".join(x for x in (ev["anchor"], ev["title"],
                                                             excerpt((first_view or {}).get("text", ""), 60)) if x)})
        data = {"item": self.item_view(item, ASSIGN_TEXT_CHARS), "candidates": cand_views}
        handles = list(handle_to_event)
        skill = self.registry.for_job("assign")
        schema = _deepcopy(skill.schema)
        props = schema["properties"]
        _enum(props["event_id"], handles + [""])
        if handles:
            _enum(props["judged"]["items"]["properties"]["event_id"], handles)
        else:
            props["judged"]["maxItems"] = 0
        ev_ids = props["evidence"]["items"]["properties"]["item_ids"]
        if cand_item_handles:
            _enum(ev_ids["items"], cand_item_handles)
        else:
            ev_ids["maxItems"] = 0
        context = {"candidate_ids": handles, "candidate_item_ids": cand_item_handles}
        res = self.harness.run("assign", data, context=context, schema=schema, subject=item_id)
        if not res.ok and res.candidate:
            # Invalid twice, but the last output was schema-valid: its per-candidate judgements still
            # decide the action through derive() (never an attach on doubt, none for a non-matter).
            return self._apply_assign(item, res.candidate, handle_to_event, cand_meta, res.run_id, current, reason,
                                      status="fallback")
        if not res.ok:
            payload = {"errors": res.errors, "candidates": cand_meta}
            if reason == "removed_by_user":
                self._unfile(item, res.run_id, current, "removed_by_user")
                self.store.record_proposal(res.run_id, "assign", item_id, payload, "fallback",
                                           "skill output invalid twice; left unfiled (removed by user)")
                return None
            event_id = self._new_event(item, res.run_id, current)
            self.store.record_proposal(res.run_id, "assign", item_id, payload, "fallback",
                                       "skill output invalid twice; started a new event")
            if event_id:
                self.recheck_unfiled(event_id)
            return event_id
        return self._apply_assign(item, res.output, handle_to_event, cand_meta, res.run_id, current, reason)

    def _apply_assign(self, item: dict, out: dict, handle_to_event: dict[str, str], cand_meta: list[dict],
                      run_id: str, current: Optional[dict] = None, reason: Optional[str] = None,
                      status: str = "applied") -> Optional[str]:
        item_id = item["item_id"]
        real = _unalias_assign(out, handle_to_event)
        rank = {m["event_id"]: m["rank"] for m in cand_meta}
        anchors = {m["event_id"]: m["anchor"] for m in cand_meta if m.get("anchor")}
        d = self._decide.derive(real, rank, anchors)
        payload = dict(out)
        payload.update({"derived": d, "candidates": cand_meta})
        anchor = str(out.get("item_object") or "").strip()
        with self.store.tx():
            link = self.store.current_event_link(item_id)
            if not self._placement_unchanged(item_id, link, current):
                # a user decision moved, removed or unfiled it while the model was thinking
                self.store.record_proposal(run_id, "assign", item_id, payload, "superseded", "item placement changed")
                return link["event_id"] if link else None
            action, target = d["action"], d["target"]
            ev = self.store.get_event(target) if target else None
            blocked = action in ("attach", "ask") and (
                ev is None or ev["deleted"] or target in self.store.forbidden_events_for(item_id))
            note = "invalid twice; derived from the last schema-valid output -> " if status == "fallback" else ""
            if blocked:
                status = "rejected"
                note = "target event unknown, deleted or forbidden by a decision -> "
                action = d["provisional"] or ("new" if real.get("item_is_matter", True) else "none")
            if action == "attach":
                if current is not None and current["event_id"] == target:
                    self.store.mark_placed(target, item_id, item["revision"])
                else:
                    if current is not None:
                        self.store.detach(current["event_id"], item_id, "revision")
                    self.store.attach(target, item_id, "model", run_id, item["revision"])
                merge = d.get("merge_with")
                if merge and not blocked:
                    note += self._ask_merge(item, target, merge, run_id)
                self.store.record_proposal(run_id, "assign", item_id, payload, status, note)
                self.recheck_unfiled(target)
                return target
            if action == "ask":
                placed = self._place_provisional(item, run_id, current, d["provisional"], anchor, reason)
                prompt = self._same_event_prompt(item, ev)
                qid = self.store.create_question(
                    "same_event", item_id, target, prompt, self.max_open_questions, item_id=item_id, run_id=run_id,
                    day_key=self._day_key(item), per_day=self.ask_per_day, per_event_per_day=self.ask_per_event_per_day,
                    provisional={"action": d["provisional"], "event_id": placed or ""},
                    b_items=self.store.event_item_ids(target))
                note = f"question {qid}" if qid else f"ask_budget -> {d['provisional']}"
                payload["provisional_event_id"] = placed or ""
                self.store.record_proposal(run_id, "assign", item_id, payload, status, note)
                if placed:
                    self.recheck_unfiled(placed)
                return placed
            if action == "none":
                self._unfile(item, run_id, current, "none")
                self.store.record_proposal(run_id, "assign", item_id, payload, status, note + "none: left unfiled")
                return None
            placed = self._place_provisional(item, run_id, current, "new", anchor, reason)
            self.store.record_proposal(run_id, "assign", item_id, payload, status,
                                       note + ("new" if placed else "removed by user: left unfiled"))
            if placed:
                self.recheck_unfiled(placed)
            return placed

    def _ask_merge(self, item: dict, a: str, b: str, run_id: str) -> str:
        """Two events the model saw as the same object: ask whether to merge b into a (yes merges)."""
        ea, eb = self.store.get_event(a), self.store.get_event(b)
        if not ea or not eb or ea["deleted"] or eb["deleted"] or self.store.has_constraint("apart_events", a, b):
            return ""
        name = lambda e: e["title"] or e["anchor"] or "那件事"  # noqa: E731
        qid = self.store.create_question(
            "same_event", a, b, f"「{name(ea)}」和「{name(eb)}」是同一件事吗？", self.max_open_questions,
            run_id=run_id, day_key=self._day_key(item), per_day=self.ask_per_day,
            per_event_per_day=self.ask_per_event_per_day, provisional={"action": "merge", "event_id": a},
            b_items=self.store.event_item_ids(b))
        return f"merge question {qid}" if qid else "merge ask_budget"

    def _place_provisional(self, item: dict, run_id: str, current: Optional[dict], action: str, anchor: str,
                           reason: Optional[str]) -> Optional[str]:
        """new -> own event (anchored on the item's object); none -> unfiled. An item the user just
        removed from an event never becomes a one-item event: it waits unfiled for a matching event."""
        if action == "none" or reason == "removed_by_user":
            self._unfile(item, run_id, current, "removed_by_user" if reason == "removed_by_user" else "none")
            return None
        return self._new_event(item, run_id, current, anchor)

    def _new_event(self, item: dict, run_id: Optional[str], current: Optional[dict] = None,
                   anchor: str = "") -> Optional[str]:
        """Give the item an event of its own. On re-assignment an event holding only this item is kept."""
        item_id = item["item_id"]
        with self.store.tx():
            link = self.store.current_event_link(item_id)
            if not self._placement_unchanged(item_id, link, current):
                return link["event_id"] if link else None
            if current is not None:
                others = [i for i in self.store.event_item_ids(current["event_id"]) if i != item_id]
                if not others:
                    self.store.mark_placed(current["event_id"], item_id, item["revision"])
                    return current["event_id"]
                self.store.detach(current["event_id"], item_id, "revision")
            event_id = self.store.create_event(item, anchor)
            self.store.attach(event_id, item_id, "model", run_id, item["revision"])
        return event_id

    def _unfile(self, item: dict, run_id: Optional[str], current: Optional[dict], why: str) -> None:
        item_id = item["item_id"]
        with self.store.tx():
            link = self.store.current_event_link(item_id)
            if not self._placement_unchanged(item_id, link, current):
                return
            if current is not None:
                self.store.detach(current["event_id"], item_id, "revision")
            self.store.set_unfiled(item_id, why, run_id)

    def _placement_unchanged(self, item_id: str, link: Optional[dict], current: Optional[dict]) -> bool:
        """True if the item is still where the caller found it. An item the user unfiled meanwhile has
        no link either, but the user's decision wins: that counts as changed."""
        if not _same_link(link, current):
            return False
        return not (current is None and self.store.one(
            "SELECT 1 FROM unfiled WHERE item_id=? AND reason='user'", (item_id,)))

    def _day_key(self, item: dict) -> str:
        """The item's own local calendar date, used for per-day question budgets."""
        return self._local(item["started_at"])[:10]

    def recheck_unfiled(self, event_id: str) -> int:
        """Re-queue unfiled items that may belong to this (new or grown) event, at most recheck_max times.

        An item left unfiled because no matter existed yet can join the matter once it appears. Items
        the user unfiled, and items forbidden from this event, are never touched.
        """
        rows = self.store.unfiled_items()
        if not rows:
            return 0
        feat = next((f for f in self.event_features() if f["event_id"] == event_id), None)
        if feat is None:
            return 0
        n = 0
        for u in rows:
            iid = u["item_id"]
            if u["reason"] == "user" or u["recheck_count"] >= self.recheck_max:
                continue
            if event_id in self.store.forbidden_events_for(iid) or iid in feat["item_ids"]:
                continue
            seg = self.store.segment_of(iid)
            if seg is not None and seg["no_matter"]:
                continue
            if self.store.one("SELECT 1 FROM jobs WHERE item_id=? AND state IN ('queued','running')", (iid,)):
                continue
            it = self.store.get_item(iid)
            if not it:
                continue
            gap = 0.0 if feat["first_ts"] <= it["started_ts"] <= feat["last_ts"] else min(
                abs(it["started_ts"] - feat["first_ts"]), abs(it["started_ts"] - feat["last_ts"]))
            if gap > self.recheck_window_s:
                continue
            emb = self.store.get_derived(iid, it["revision"]).get("embedding")
            sim = _cosine(emb, feat["centroid"])
            shared = set(self.other_persons(iid, for_matching=True)) & set(feat["person_ids"])
            if sim < self.recheck_threshold and not shared:
                continue
            self.store.x("UPDATE unfiled SET recheck_count = recheck_count + 1 WHERE item_id=?", (iid,))
            self.store.requeue_latest(iid, "unfiled_recheck")
            n += 1
        if n:
            self.wake()
        return n

    def _same_event_prompt(self, item: dict, ev: Optional[dict]) -> str:
        snippet = excerpt(self.match_body(item).replace("\n", " "), 24)
        name = (ev or {}).get("anchor") or (ev or {}).get("title") or ""
        if not name and ev:
            first = self.store.event_item_ids(ev["event_id"])[:1]
            it = self.store.get_item(first[0]) if first else None
            name = excerpt(self.match_body(it).replace("\n", " "), 16) if it else "那件事"
        return f"这条「{snippet}」和「{name or '那件事'}」是同一件事吗？"

    # ---- (e) event-brief --------------------------------------------------------------

    def brief(self, event_id: str) -> None:
        ctx = self.brief_prepare(event_id)
        if ctx is not None:
            self.brief_apply(ctx, self.brief_call(ctx))

    def brief_prepare(self, event_id: str) -> Optional[dict]:
        """Snapshot what event-brief reads (under the store lock). None when there is nothing to brief."""
        ev = self.store.get_event(event_id)
        if not ev or ev["deleted"]:
            return None
        item_ids = self.store.event_item_ids(event_id)
        if not item_ids:
            self.store.update_event(event_id, deleted=1, needs_brief=0)
            self.store.record_proposal(None, "brief", event_id, {"rule": "empty_event"}, "applied", "no items left")
            return None
        # Snapshot membership and source revisions together. A user can remove/move
        # an item or upload a revision while the model is generating its summary.
        with self.store.tx():
            item_ids = self.store.event_item_ids(event_id)
            source_versions = [(i, self.store.latest_revision(i)) for i in item_ids]
            shown = item_ids[-BRIEF_MAX_ITEMS:]
            rows = [self.store.get_item(i) for i in shown]
            items = [self.brief_item_view(it) for it in rows]
            # "As of" is the event's own latest evidence, never the wall clock: a card describes where
            # things stood at its newest item, however late it is (re)written.
            as_of = self._local(max((it.get("ended_at") or it["started_at"] for it in
                                     (self.store.get_item(i) for i in item_ids)),
                                    key=lambda t: datetime.fromisoformat(t)))
            persons = sorted({p for i in item_ids for p in self.other_persons(i)})
            person_labels = [self.people.label(p) for p in persons]
        handle_to_item = {v["item_id"]: iid for v, iid in zip(items, shown)}
        data = {
            "event": {
                "title": ev["title"],
                "title_locked": ev["title_user_edited"],
                "anchor": ev["anchor"],
                "previous_status_line": ev["status_line"],
                "persons": person_labels,
                "earlier_items_not_shown": len(item_ids) - len(shown),
            },
            "items": items,
            "as_of": as_of,
        }
        skill = self.registry.for_job("brief")
        schema = _deepcopy(skill.schema)
        handles = list(handle_to_item)
        _enum(schema["properties"]["status_facts"]["items"]["properties"]["item_ids"]["items"], handles)
        _enum(schema["properties"]["off_anchor_item_ids"]["items"], handles)
        context = {"item_ids": handles, "title_locked": ev["title_user_edited"], "current_title": ev["title"],
                   "as_of": as_of,
                   "items": {v["item_id"]: {"text": v["text"], "captured_at": self._local(it["started_at"])}
                             for v, it in zip(items, rows)}}
        return {"event_id": event_id, "data": data, "schema": schema, "context": context, "as_of": as_of,
                "source_versions": source_versions, "handle_to_item": handle_to_item}

    def brief_call(self, ctx: dict):
        """The model call (no store writes besides the run record): safe to run on a pool thread."""
        return self.harness.run("brief", ctx["data"], context=ctx["context"], schema=ctx["schema"],
                                subject=ctx["event_id"], as_of=ctx["as_of"], no_retry=BRIEF_NO_RETRY,
                                repairable=lambda out: self._brief_repair_usable(out, ctx["context"]))

    def _brief_repair_usable(self, out: dict, context: dict) -> bool:
        """Skip the retry only when the deterministic repair still gives a card: at least one fact and a
        status line (a new event's first brief would otherwise stay empty)."""
        try:
            s = self._brief_rules.salvage(out, context)
        except Exception:  # a repair bug must not lose the retry
            return False
        return bool(s and s.get("status_facts") and s.get("status_line"))

    def brief_apply(self, ctx: dict, res, accept_growth: bool = False) -> None:
        """Write a brief result if its sources still hold. With accept_growth (pipeline mode), a result
        written for a snapshot the event has since only grown past (items added, none removed or
        revised) is kept, and the event stays marked for a fresh brief."""
        event_id, context, source_versions = ctx["event_id"], ctx["context"], ctx["source_versions"]
        handle_to_item = ctx["handle_to_item"]
        partial = False
        if res.ok:
            out = res.output
        else:
            cats = sorted({e[1:e.index("]")] for e in res.errors if e.startswith("[") and "]" in e})
            # Invalid output (evidence / date / length errors are not retried: BRIEF_NO_RETRY; format
            # errors after a retry): keep the individually valid parts (facts that pass the evidence rules,
            # an unsupported done fact retagged as info, a line or title with no errors) instead of leaving
            # a new card empty or an old one stale.
            salvaged = self._brief_rules.salvage(res.candidate, context) if res.candidate else None
            if not salvaged:
                self.store.update_event(event_id, needs_brief=0)
                self.store.record_proposal(res.run_id, "brief", event_id, {"errors": res.errors, "categories": cats},
                                           "rejected", "skill output invalid twice; previous card kept")
                return
            out, partial = salvaged, True
            out["_errors"], out["_categories"] = res.errors, cats
        # A fact's date lives in its date field; the text does not repeat it (the card shows both).
        out = self._brief_rules.tidy(out)
        flagged: list[str] = []
        stale = False
        with self.store.tx():
            ev = self.store.get_event(event_id)
            if not ev or ev["deleted"]:
                self.store.record_proposal(res.run_id, "brief", event_id, out, "superseded", "event deleted")
                return
            current_ids = self.store.event_item_ids(event_id)
            current_versions = [(i, self.store.latest_revision(i)) for i in current_ids]
            if current_versions != source_versions:
                if not (accept_growth and set(source_versions) <= set(current_versions)):
                    self.store.update_event(event_id, needs_brief=1)
                    self.store.record_proposal(res.run_id, "brief", event_id, out, "superseded",
                                               "source membership or revision changed during generation")
                    return
                stale = True  # only grew: keep this card now, brief again for the new items
            current = set(current_ids)
            facts = []
            for f in out["status_facts"]:
                ids = [handle_to_item[h] for h in f["item_ids"] if h in handle_to_item]
                if ids and set(ids) <= current:
                    facts.append(dict(f, item_ids=ids))
            prov = dict(ev["provenance"])
            fields: dict[str, Any] = {"needs_brief": 1 if stale else 0}
            if out.get("status_line") is not None:
                fields["status_line"] = out["status_line"].strip()
                prov["status_line"] = res.provenance
            if facts or not partial:
                fields["status_facts"] = facts
            title = out.get("title")
            if not ev["title_user_edited"] and title is not None and title.strip():
                fields["title"] = title.strip()
                prov["title"] = res.provenance
            if not ev["anchor"] and (ev["title_user_edited"] or (title and title.strip())):
                # No seed object (first item placed without a model call): the first title becomes the
                # fixed anchor. Later briefs never rewrite it.
                fields["anchor"] = (ev["title"] if ev["title_user_edited"] else title).strip()
                fields["anchor_source"] = "brief"
            fields["provenance"] = prov
            self.store.update_event(event_id, **fields)
            if not partial:
                # A valid brief states the whole off-anchor set: newly listed items are flagged, items it no
                # longer lists are cleared. A salvaged (invalid) brief leaves the flags as they were.
                off = [handle_to_item[h] for h in out.get("off_anchor_item_ids") or [] if h in handle_to_item]
                flagged = self.store.set_off_anchor(event_id, off, clear_others=True)
            dropped = len(out["status_facts"]) - len(facts)
            note = (("partial: " + ",".join(out.get("_categories") or []) + "; ") if partial else "") \
                + (("repaired without retry; ") if partial and res.attempts == 1 else "") \
                + ("title locked by user; " if ev["title_user_edited"] else "") \
                + (f"dropped {dropped} facts citing removed items; " if dropped else "") \
                + (f"off-anchor {len(flagged)}; " if flagged else "") \
                + ("stale (event grew during generation)" if stale else "")
            self.store.record_proposal(res.run_id, "brief", event_id, out, "partial" if partial else "applied", note)
        if flagged:
            self._ask_off_anchor(event_id, flagged, res.run_id)
        self._rank_dirty = True

    def _ask_off_anchor(self, event_id: str, flagged: list[str], run_id: str) -> Optional[str]:
        """Ask whether the most recent flagged item belongs here. The item stays in place meanwhile;
        it is only hidden from matching, so it cannot pull later items in."""
        ev = self.store.get_event(event_id)
        latest = max(flagged, key=lambda i: (self.store.get_item(i) or {}).get("started_ts", 0))
        item = self.store.get_item(latest)
        if not item or not ev:
            return None
        return self.store.create_question(
            "same_event", latest, event_id, self._same_event_prompt(item, ev), self.max_open_questions,
            item_id=latest, run_id=run_id, day_key=self._day_key(item), per_day=self.ask_per_day,
            per_event_per_day=self.ask_per_event_per_day, provisional={"action": "stay", "event_id": event_id},
            b_items=[i for i in self.store.event_item_ids(event_id) if i != latest])

    # ---- (f) home-rank ---------------------------------------------------------------

    def _rank_dates(self, ev: dict, ids: list[str], today: str) -> dict:
        dates: set[str] = set()
        for f in ev["status_facts"]:
            if f.get("date") and f.get("state") in ("planned", "in_progress", None):
                dates.add(f["date"])
        for iid in ids[-3:]:
            it = self.store.get_item(iid)
            if it:
                for d in self._dates.resolve(excerpt(self.item_body(it), BRIEF_TEXT_CHARS), it["started_at"]):
                    dates.add(d["date"])
        return {"upcoming": sorted(d for d in dates if d >= today)[:4],
                "past": sorted((d for d in dates if d < today), reverse=True)[:4]}

    def _any_upcoming(self, ids: list[str], today: str) -> list[str]:
        """Dates on or after today mentioned by any item of the event (not only the card's 1-4 facts):
        an event is "only info / past" for the follow-up floor only if none of its items looks ahead."""
        out: set[str] = set()
        for iid in ids:
            it = self.store.get_item(iid)
            if it:
                out.update(d["date"] for d in self._dates.resolve(excerpt(self.item_body(it), BRIEF_TEXT_CHARS),
                                                                  it["started_at"]) if d["date"] >= today)
        return sorted(out)

    def rank(self) -> None:
        ctx = self.rank_prepare()
        if ctx is not None:
            self.rank_apply(ctx, self.rank_call(ctx))

    def _rank_shortlist(self, events: list[dict], today: str) -> tuple[list[dict], list[dict]]:
        """(shortlist for the model, the rest). Pinned events first, then events with an open dated step
        ahead (by their card facts), then the most recently updated, up to rank_max_events. The model
        scores the shortlist; the rest are ordered by recency alone (rank_apply)."""
        if len(events) <= self.rank_max_events:
            return events, []

        def open_ahead(ev: dict) -> bool:
            return any(f.get("date") and f["date"] >= today and f.get("state") in ("planned", "in_progress", None)
                       for f in ev["status_facts"])
        picked: list[dict] = []
        seen: set[str] = set()
        for group in ([e for e in events if e["pinned"]], [e for e in events if open_ahead(e)], events):
            for e in group:  # each group keeps the recency order of `events`
                if len(picked) >= self.rank_max_events:
                    break
                if e["event_id"] not in seen:
                    seen.add(e["event_id"])
                    picked.append(e)
        order = {e["event_id"]: i for i, e in enumerate(events)}
        picked.sort(key=lambda e: order[e["event_id"]])
        return picked, [e for e in events if e["event_id"] not in seen]

    def rank_prepare(self) -> Optional[dict]:
        self._rank_dirty = False
        self._items_since_rank = 0
        events = self.store.live_events()
        if not events:
            return None
        now_iso = self._local(self.clock.now())
        today = now_iso[:10]
        self._last_rank_day = today
        ranked, rest = self._rank_shortlist(events, today)
        now_ts = self.clock.now().timestamp()
        # Events outside the shortlist are not scored now; an old high score must not keep them on top.
        # They get a recency score (at most 0.3, halving every 30 days without an update), rounded so it
        # changes rarely.
        for ev in rest:
            age_days = max(0.0, (now_ts - (ev["updated_ts"] or now_ts)) / 86400)
            imp = round(max(0.05, 0.3 * 0.5 ** (age_days / 30)), 2)
            if ev["feature_less"]:
                imp = min(imp, 0.2)
            if abs(imp - ev["importance"]) >= 0.005:
                self.store.update_event(ev["event_id"], importance=imp,
                                        importance_reason=ev["importance_reason"] or "较久没有更新")
        touches = {r["target"]: r["n"] for r in self.store.all(
            "SELECT json_extract(payload, '$.event_id') AS target, COUNT(*) AS n FROM decisions"
            " WHERE json_extract(payload, '$.event_id') IS NOT NULL GROUP BY target")}
        views, handle_to_event, floor_input = [], {}, {}
        for ev in ranked:
            ids = self.store.event_item_ids(ev["event_id"])
            kinds: dict[str, int] = {}
            for iid in ids:
                it = self.store.get_item(iid)
                kinds[it["kind"]] = kinds.get(it["kind"], 0) + 1
            persons = {p for i in ids for p in self.other_persons(i)}
            h = self.store.event_handle(ev["event_id"])
            handle_to_event[h] = ev["event_id"]
            dates = self._rank_dates(ev, ids, today)
            floor_input[h] = {"status_facts": ev["status_facts"], "upcoming": self._any_upcoming(ids, today),
                              "feature_less": ev["feature_less"], "pinned": ev["pinned"]}
            views.append({
                "event_id": h, "title": ev["title"], "status_line": ev["status_line"],
                "status_facts": [{"text": f.get("text", ""), "state": f.get("state", "info"), "date": f.get("date", "")}
                                 for f in ev["status_facts"][:RANK_FACTS]],
                "dates": dates,
                "started_at": ev["started_at"], "updated_at": ev["updated_at"], "item_count": len(ids),
                "kinds": kinds, "person_count": len(persons), "pinned": ev["pinned"],
                "feature_less": ev["feature_less"], "user_touches": touches.get(ev["event_id"], 0),
            })
        ids = list(handle_to_event)
        skill = self.registry.for_job("rank")
        schema = _deepcopy(skill.schema)
        schema["properties"]["ranking"]["minItems"] = len(ids)
        schema["properties"]["ranking"]["maxItems"] = len(ids)
        _enum(schema["properties"]["ranking"]["items"]["properties"]["event_id"], ids)
        less = [h for h, eid in handle_to_event.items() if self.store.get_event(eid)["feature_less"]]
        return {"data": {"now": now_iso, "events": views}, "context": {"event_ids": ids, "feature_less": less},
                "schema": schema, "now_iso": now_iso, "today": today, "handle_to_event": handle_to_event,
                "floor_input": floor_input}

    def rank_call(self, ctx: dict):
        return self.harness.run("rank", ctx["data"], context=ctx["context"], schema=ctx["schema"], subject="home",
                                as_of=ctx["now_iso"])

    def rank_apply(self, ctx: dict, res) -> None:
        if not res.ok:
            self.store.record_proposal(res.run_id, "rank", "home", {"errors": res.errors}, "rejected", "invalid twice")
            return
        handle_to_event = ctx["handle_to_event"]
        # General rule on top of the model's scores: an open follow-up within the next week never ranks
        # below an event with only info / past items (skills/home-rank/scripts/floor.py).
        ranking, lifted = self._rank_floor.apply_floor(res.output["ranking"], ctx["floor_input"], ctx["today"])
        with self.store.tx():
            for r in ranking:
                event_id = handle_to_event.get(r["event_id"])
                ev = self.store.get_event(event_id) if event_id else None
                if not ev or ev["deleted"]:
                    continue
                imp = max(0.0, min(1.0, float(r["importance"])))
                if ev["feature_less"]:
                    imp = min(imp, 0.2)
                if abs(imp - ev["importance"]) < 1e-6 and r["reason"] == ev["importance_reason"]:
                    continue
                prov = dict(ev["provenance"])
                prov["importance"] = res.provenance
                self.store.update_event(event_id, importance=round(imp, 3), importance_reason=r["reason"],
                                        provenance=prov)
            self.store.record_proposal(res.run_id, "rank", "home", dict(res.output, floor_lifted=lifted), "applied",
                                       f"follow-up floor lifted {','.join(lifted)}" if lifted else "")

    # ---- read model -------------------------------------------------------------------

    def state(self, since: int) -> dict:
        with self.store.tx():
            cursor = self.store.cursor()
            # Segment children are internal: the client sees the parent item id plus the segment.
            segs = {r["child_id"]: r for r in self.store.all("SELECT * FROM item_segments")}

            def public(iid: str) -> str:
                return segs[iid]["parent_id"] if iid in segs else iid

            def seg_ref(iid: str) -> dict:
                r = segs[iid]
                return {"item_id": r["parent_id"], "seg_id": r["seg_id"], "start": r["start"], "end": r["end"],
                        "gist": r["gist"]}

            events = []
            for row in self.store.all("SELECT event_id FROM events WHERE seq > ? ORDER BY seq", (since,)):
                ev = self.store.get_event(row["event_id"])
                ids = self.store.event_item_ids(ev["event_id"])
                person_ids: list[str] = []
                for iid in ids:
                    for p in self.people.item_person_ids(iid):
                        if p not in person_ids:
                            person_ids.append(p)
                facts = []
                for f in ev["status_facts"]:
                    f = dict(f)
                    cited = f.get("item_ids") or []
                    if any(i in segs for i in cited):
                        f["segment_refs"] = [{"item_id": segs[i]["parent_id"], "seg_id": segs[i]["seg_id"]}
                                             for i in cited if i in segs]
                        f["item_ids"] = list(dict.fromkeys(public(i) for i in cited))
                    facts.append(f)
                events.append({
                    "event_id": ev["event_id"],
                    "handle": f"E{ev['handle']}" if ev.get("handle") is not None else None,
                    "title": ev["title"],
                    "title_user_edited": ev["title_user_edited"],
                    "anchor": ev.get("anchor", ""),
                    "status_line": ev["status_line"],
                    "status_facts": facts,
                    "importance": ev["importance"],
                    "importance_reason": ev["importance_reason"],
                    "started_at": ev["started_at"],
                    "updated_at": ev["updated_at"],
                    # Unique item ids; an item filed by segments appears here once, its parts in `segments`.
                    "item_ids": list(dict.fromkeys(public(i) for i in ids)),
                    "segments": [seg_ref(i) for i in ids if i in segs],
                    "person_ids": person_ids,
                    "pinned": ev["pinned"],
                    "feature_less": ev["feature_less"],
                    "deleted": ev["deleted"],
                    "merged_into": ev["merged_into"],
                    "provenance": ev["provenance"],
                })
            persons = []
            for p in self.store.all("SELECT * FROM persons WHERE seq > ? ORDER BY seq", (since,)):
                persons.append({
                    "person_id": p["person_id"],
                    "display_name": p["display_name"],
                    "aliases": self.people.aliases(p["person_id"]) if not p["merged_into"] else [],
                    "origin": p["origin"],
                    "merged_into": p["merged_into"],
                })
            questions = []
            for q in self.store.open_questions():
                out = {k: q[k] for k in ("question_id", "kind", "a", "b", "prompt_zh", "created_at")}
                for side in ("a", "b"):
                    if q[side] in segs:
                        out[side] = segs[q[side]]["parent_id"]
                        out[f"{side}_seg_id"] = segs[q[side]]["seg_id"]
                questions.append(out)
            # The complete current set (not a delta): an item leaves it when it is filed into an event.
            unfiled = []
            for u in self.store.unfiled_items():
                entry = {"item_id": public(u["item_id"]), "reason": u["reason"], "since": u["since"]}
                if u["item_id"] in segs:
                    entry.update(seg_id=segs[u["item_id"]]["seg_id"], start=segs[u["item_id"]]["start"],
                                 end=segs[u["item_id"]]["end"], gist=segs[u["item_id"]]["gist"])
                unfiled.append(entry)
            # What the organizer read from an item the Mac cannot read itself (an image), keyed by
            # item_id, for the revision it was derived from. A delta like events: only readings written
            # after `since`, and only for the item's current revision.
            # `text` is the transcription only; `summary` is the model's own one-line summary, to be
            # labelled as such (added 2026-09-28; absent/"" from an older organizer). `messages` is the
            # chat's messages ([] for any other image). Added with image-read (2026-09-29): `type` (the
            # image type) and `fields` / `numbers` (key fields and key numbers as printed; each value is
            # in `text`); a reading stored by screenshot-read has type "chat_screenshot" or "other".
            readings = {r["item_id"]: self._reading_entry(r) for r in self.store.readings_since(since)}
        return {"cursor": cursor, "events": events, "questions": questions, "persons": persons,
                "unfiled": unfiled, "readings": readings}


_SEGMENT_NS = uuid.UUID("6f1f7c1e-2b0a-4e4f-9a57-0c0ffee00002")


def segment_child_id(parent_id: str, seg_id: str) -> str:
    """The internal item id of a segment: stable per (parent item, seg_id) across revisions."""
    return str(uuid.uuid5(_SEGMENT_NS, f"{parent_id.lower()}#{seg_id}"))


def _legacy_reading_type(r: dict) -> str:
    return "chat_screenshot" if r.get("messages") else "other"


def _unalias_assign(out: dict, handle_to_event: dict[str, str]) -> dict:
    """Map short event handles in a model output back to event ids. Unknown handles become a marker
    that is never a live event, so they take the rejected path instead of being silently remapped."""
    def real(h: str) -> str:
        if not h:
            return ""
        return handle_to_event.get(h, f"unknown:{h}")

    res = dict(out)
    res["event_id"] = real(out.get("event_id") or "")
    if "judged" in out:
        res["judged"] = [dict(j, event_id=real(j.get("event_id") or "")) for j in out.get("judged") or []]
    return res


def _cosine(a: Optional[list[float]], b: Optional[list[float]]) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


def _same_link(link: Optional[dict], current: Optional[dict]) -> bool:
    """True if the item's placement is still the one the caller started from."""
    if current is None:
        return link is None
    return (link is not None and link["event_id"] == current["event_id"] and link["attached_by"] == "model"
            and not link["deleted"])


def _source_key(source_app: dict) -> str:
    return (source_app.get("bundle_id") or source_app.get("name") or "").strip().lower()


def _enum(prop: dict, values: list[str]) -> None:
    """Restrict a string property to this call's handles. The static pattern is dropped: the enum is
    stricter, and guided decoding need not combine the two."""
    prop["enum"] = list(values)
    prop.pop("pattern", None)


def _deepcopy(value: Any) -> Any:
    import copy
    return copy.deepcopy(value)
