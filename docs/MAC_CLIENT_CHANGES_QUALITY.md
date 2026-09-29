# Mac client changes for the organizer-quality branch

What the Mac client (bestASR `RemoteOrganizer*`) must adopt to stay correct against the organizer
after the `claude/organizer-quality` merge. The link contract (token, `store_id`, revision upsert,
Unix socket) is unchanged. Every field below is additive; old fields keep their meaning.

## Must change

1. **Send local time offsets.** Set `ISO8601DateFormatter.timeZone = .current` for `started_at` /
   `ended_at` (`GRDBRemoteOrganizerStore.swift`, the two item encoders). A `Z` stamp still works:
   the organizer reads it in `ORGANIZER_TZ` (default: the Spark's zone). But the item's own offset
   is the only reliable signal for 今天/明天, the capture day and the daily question budget.
2. **Accept the new decision kinds** in `isWellFormed` (`RemoteOrganizer.swift`):
   - `unfile_item {item_id}`: take the item out of every event and keep it in Unfiled. The organizer
     never re-files it on its own. An assignment that is already in flight does not override it.
   - `file_item_new_event {item_id, new_event_id?}`: file an item (unfiled, or taken out of its event)
     as a new event of its own. Pass a client-generated UUID as `new_event_id` so the local overlay
     and the Spark use the same id. Replaying the same decision is harmless. An id that belongs to a
     different event is rejected.
   - `move_item` still files an item into an existing event, including an unfiled one.
3. **`unfiled` in `/v1/state`:** `[{item_id, reason, since}]` with `reason` one of `none` (the
   organizer judged it not a matter), `removed_by_user` (after `remove_item`) or `user` (after
   `unfile_item`).
   - It is the complete current set on every pull, not a delta. Replace the local copy on each pull,
     and clear it when `store_id` changes.
   - Add an Unfiled tray. Without one, noise, pasted text that is not a matter, and items the user
     removed all disappear from Memory, because they no longer get a one-item event.
4. **`remove_item` overlay:** the removed item now goes to Unfiled (`removed_by_user`), not to a new
   event. It can still be attached later, when a matching event appears, or the organizer can ask
   about it. It never becomes a one-item event on its own.

## Should change

5. **Three shapes of `same_event` question** (`a`, `b` in the question):
   - item, event. Asked while placing a new item. Until the user answers, the item sits in its own
     new event or in Unfiled. Yes moves it into `b`; No keeps it out of `b` for good.
   - item, event, where the item is already inside `b`. A brief flagged it as about another object.
     Yes keeps it there (locked); No removes it: the organizer may place it in another existing
     event, otherwise it waits in Unfiled as `removed_by_user`.
   - event, event. A merge proposal (two fragments of one matter). Yes merges `b` into `a`; No keeps
     them apart for good.
   Show the prompt text `prompt_zh` as-is. Questions expire after 72 h, also while no new item arrives.
   An expired question disappears from `questions`, and the provisional placement stays.
6. **Event fields:**
   - `handle`: a short `E<n>` id, stable per store.
   - `anchor`: the fixed object of the event.
   - `status_facts[]` entries are now `{text, state, date, quote, item_ids}`:
     - `state` is one of `planned`, `in_progress`, `done`, `cancelled` or `info`.
     - `date` is `YYYY-MM-DD` or `""`.
     - `quote` is a short verbatim evidence clause for `done`, `in_progress` or `cancelled`.
     - `item_ids` are real item ids.

     Decode `state`, `date` and `quote` as optional. Use them to style plans differently from
     completions.
7. **`/v1/health`** also returns `clock` (`wall` in production). Anything other than `wall` means
   the Spark is running an eval or test configuration.

## No change needed

- The token, `store_id`, revision upsert and the socket-only listener come from `origin/main` and
  still apply. A standalone organizer on loopback TCP needs `ORGANIZER_TCP=1`.
- The decision idempotency through `decision_id` is unchanged.

## Polish round (2026-09-28, `claude/polish`)

All additive; nothing above changes.

1. **`readings` in `/v1/state`** — what the Spark read from an item the Mac cannot read itself (today:
   screenshots, via screenshot-read). An object keyed by `item_id`:

   ```json
   "readings": {
     "<item_id>": {
       "revision": 2,
       "source": "screenshot-read",
       "text": "<summary line>\n[10:02] <sender>：<message>\n…",
       "messages": [{"sender": "…", "is_self": false, "time": "10:02", "text": "…"}],
       "run_id": "<organizer run id>"
     }
   }
   ```

   - A delta like `events`: only readings written after `since`, and only for the item's current
     revision. Merge into a local table keyed by `item_id`; keep the entry whose `revision` matches the
     item's current revision and ignore an older one. Clear it when `store_id` changes.
   - `text` is the flattened reading (a one-line summary, then one line per message); it may be `""`
     when the model could not read the image. `messages` is `[]` for a non-chat screenshot.
   - Pass it to `MemoryProjection(remoteReadings:)` so `TimelineRow.text(of:)` and
     `EventPlainTextFormatter` show "[截图中的文字] …" instead of the title or `[截图]`.
   - Documents are not included: their extracted text is already the Mac's own.
   - Readings stored before this version are re-published once (with a fresh seq), so a client with
     an old cursor still receives them.

2. **People from pasted chat text.** `persons` can now contain people named in `kind=text` items
   ("名：…" / "名: …" lines with content on the same line, and "名 10:05" bylines). They use the same
   ids as screenshot senders (`chat-<uuid5 of the normalized name>`, `origin: "chat"`), and they
   appear in `events[].person_ids`. Field labels (时间：, 备注：, 付款方式：…) and headings are skipped.
   The owner is never a person: `我/本人/自己` always, plus `ORGANIZER_OWNER_ALIASES` on the Spark
   (comma separated, default `我`; set it to the user's own names, e.g. a real name and nickname).
   A near name (小满 / 林小满, 老周 / 周建国, a chat name vs a voice name) becomes a `same_person`
   question; nothing is merged silently. They are not used as matching evidence when the organizer
   files items (a shared name in pasted text says who talked, not which matter).

3. **Status line and facts.** `status_line` now targets one Home-card line: display width ≤ 24
   (a CJK character 1, ASCII 0.5; target 18), leading with the current state or the next dated step.
   Details (amounts, names) are in `status_facts`. A fact's `text` no longer repeats the date in its
   `date` field (the card shows `text · date`); a date with a relation ("3月10日前…") may stay in the
   text, so keep the UI guard that hides the date chip when the text already contains that date.

4. **Home order.** An event with an open follow-up (`planned` / `in_progress` fact) dated within the
   next 7 days is never scored below an event with nothing open; its `importance_reason` then reads
   "M月D日还有待办：…". The Mac's ordering rule (pinned, importance, updated_at) is unchanged.

## Polish round 2 (2026-09-28, `claude/polish2`)

Additive; an older Mac keeps working.

1. **`readings[item].summary`** (new, string, `""` when absent). The screenshot-read model's own
   one-line summary of the screenshot. It is **not** source text: label it separately (e.g. "Spark
   读图概要"), outside the "[截图中的文字]" block.
   - **`readings[item].text` is now the transcription only**: one line per chat message
     ("发送者：内容"), or the visible text of a non-chat screenshot. It no longer starts with the
     summary line. A `[time] ` prefix is written per line only when the messages carry different times;
     a time label shared by every message (the chat's one time header) is left out of the lines and
     stays available in `messages[].time`.
   - Readings stored by an older organizer (summary as the first line of `text`) are split and
     re-published once with a fresh seq, so a client with an old cursor receives the new form.
   - An older Mac that ignores `summary` simply shows the transcription without the summary.
2. **Dates in cards come only from the sources.** A `status_line` or fact never names a day the cited
   items do not give. A span the source gave without a day (下周, 月底, 下个月, 7天内…) is written as a
   range ("9月28日那周", "10月4日前"), or the date is left out ("热水器待修"-style lines, fact
   `date: ""`). Expect more facts with an empty `date`; keep rendering them without a date chip. A bare
   "下周" can appear in a status line while that week is still the week after the card's newest item.
3. **Facts.** Up to 4 facts when the items support them; the next dated meeting or appointment is kept
   as its own fact even when an earlier deadline exists. No field changes.

## Image reading (2026-09-29, `claude/multimodal`)

Additive; an older Mac keeps working. screenshot-read is replaced by **image-read**, which reads any
image item (not only chat screenshots) in two steps: the image type, then that type's extraction.

1. **`readings[item]` keeps `revision`, `text`, `summary`, `messages`, `run_id` with the same meaning.**
   `text` is still the transcription only (source text): one line per chat message, or the image's
   text lines in reading order (a struck-out handwritten line is prefixed "（已划掉）", a ticked one
   "[✓] "; a chart is written as its title, axes and "category value" per series). `summary` is the
   model's one-line gist (not source text). `messages` is `[]` for anything but a chat screenshot.
   `source` is now `"image-read"` (`"screenshot-read"` for a reading stored before this version).
2. **New: `type`** (string): `chat_screenshot`, `chart_dashboard`, `slide`, `whiteboard_handwriting`,
   `receipt_invoice`, `scanned_document`, `form_label_sign` or `other`. A reading stored by
   screenshot-read reports `chat_screenshot` (it has messages) or `other`.
3. **New: `fields`** (`[{key, label, value}]`): key fields as printed, only those the image shows —
   e.g. a receipt's `merchant`, `date_text`, `doc_no`, `total`, `payment_method`; a label's
   `recipient`, `tracking_no`; a slide's `title`, `page`; a chat's `chat_title`. `label` is the printed
   field name (may be `""`). Two derived fields are not verbatim: `date_iso` (a receipt date written as
   YYYY-MM-DD, only when the image prints a full date) and `currency` (CNY, USD, …).
4. **New: `numbers`** (`[{label, value}]`): key numbers as printed (amounts, chart points and KPIs,
   slide KPIs, numeric label fields). Each value appears in the image; the organizer's validator
   drops any it cannot find in the transcription.
5. Suggested use: show `type` as a small tag on the image row, and `fields` as a compact key/value list
   under the "[图中的文字]" block. Nothing is required: a Mac that ignores the new keys shows `text`
   and `summary` as before.
