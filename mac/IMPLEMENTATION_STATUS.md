# bestASR implementation status

This file is the delivery ledger for the product defined in
`PRODUCT_REQUIREMENTS.md`. It records user-visible implementation separately
from acceptance evidence. A protocol, fixture, database table, or passing unit
test does not by itself make a product capability complete.

Status date: 2026-10-01.

## 2026-10-01 v7 integration, Mac side (`claude/v7`)

`claude/v7-agents`, `claude/v7-map` and `claude/v7-spaces` (with the review
fixes) merged into `hackathon/base`, plus the connections that need all
three; design in the "v7 集成" section of `docs/architecture/TECHNICAL_DESIGN.md`.
New requirement IDs (PRD V1.8 §12.9–§12.11; no existing ID changed):
MAP-001–006, LINK-001–005, AGENT-001–009, SPACE-001–012, traced in
`config/traceability.json` with `artifacts/evidence/v7/e2e-summary.json`.
Not installed; the App was not launched. Synthetic data only.

- Delivered by the integration: agents see each shared space's matters
  labelled `space:<space>:<event>` and never folded into 我的 (a grant for
  我的 cannot reach a space); ropes and strands in the agent's view; agent
  reads and refusals of a space go to that space's log as `agent.access`
  (counts only); 整根绳 offers the matter's rope and the rope rule is followed
  for every matter on the rope and the ropes inside it (自动 sends only on a
  rope the owner confirmed); 全部 keeps the matter maps.
- Verified on the merged code: BestASRCore package suite **922 executed, 21
  skipped, 0 failed, 45 bundles** (`swift test --skip
  QwenWhisperFeaturesTests`; v6 829); MindloomLink 86 (1 skipped: the opt-in
  live test); iOS simulator 158 (157 passed, 1 skipped: on-device zh-CN
  recognition); App Debug build succeeded; `swift-format lint --strict` adds no
  finding in the files this integration changed; `privacy_scan.sh` 0 findings
  (two synthetic `…/Downloads/…` script paths in the agent tests were
  renamed); `validate_product_consistency.sh`, `validate_traceability.sh` (10
  entries), `check_project_drift.sh` pass.
- End to end against one fresh integrated organizing-device instance: privacy
  **68/68**, phone (simulator, real relay and SSH) **67/67** (`authorized_keys`
  on both hosts byte-identical afterwards), shared spaces (two synthetic
  libraries, lab Twin-7 matter) **57/57**, agent MCP **43/43** with the
  SwiftPM helper and with the helper inside the built App.

| requirement | state |
|---|---|
| MAP-001, MAP-002 | delivered (organizer); measured on the lab and pm demo copies, see the organizer's `skills/matter-map/BENCHMARK.md` |
| MAP-003, MAP-004, MAP-005 | delivered; checked by tests, renders and the App build, not in the running App; continuous zoom not seen moving; no VoiceOver pass by hand |
| MAP-006 | delivered on the organizer (tests with a fake model); in the live spaces run the grouping pass ran in the space, a drawn map was not inspected |
| LINK-001–005 | delivered; the lab data has no blocks edge, so 在等 / 被它等 is covered by tests and the synthetic fixture only |
| AGENT-001–009 | delivered; consent panel, notifications and Settings → Agent checked by build and service tests, not on screen; no real vendor agent driven (the MCP exchange is verified with an independent client) |
| SPACE-001–012 | delivered except: segment audio is not shared (text and speaker names only; user decision pending), 快照 is not offered in the share sheet, no UI for a member's second Mac or for adding org admins, a sole org admin removed from the org keeps the space (no key escrow), teammates still reach the organizing device through the owner's SSH account, shares made while the link is down fail with a message (no durable outbox) |

## 2026-10-01 v7 matter map and relations, Mac side (`claude/v7-map`)

The 线索 view and the Home lenses of the shared v7 contract A (matter map
and relations v2, §3); design in the "v7 线索与关系" section of
`docs/architecture/TECHNICAL_DESIGN.md`. The organizer side (the
`matter-map` and `matter-group` skills, `POST /v1/events/{id}/map`, the new
decisions) is the service branch. Not installed; the App was not launched.
Synthetic data only.

- `/v1/state` maps, facets, ropes and relations are decoded, stored and
  unmasked; all additive (an older service omits them; a malformed field or
  entry is dropped, never the pull). The six rope and relation decisions
  (confirm, reject, rename a rope; move a matter to a rope or none; reject a
  blocks edge; hide a crossing) are checked against the service limits,
  masked on the wire and applied at once by the local overlay. A matter page
  with no map asks for one once per link session.
- The matter page has four lenses: 线索 (default: status bar, strand map
  drawn natively with focusable knots and source tiles, evidence panel with
  the quote in its item, continuous zoom from the Home lane, facts on one
  thread under 正在整理线索… while there is no map), 结构, 网 (1–2 hop graph
  with its relations and their corrections) and 文本 (the page as it was).
  Home has 按时间 (as it was), 按绳, 按截止 and 按人. Light and dark; every
  knot, tile, pill and row has a spoken label.
- Verified: `BestASRMemoryTests` 73, `BestASRMemoryUITests` 38 (4 skipped:
  snapshot renders without an output directory), `BestASRRemoteOrganizerTests`
  85 (1 skipped: live smoke), `BestASRPersistenceTests` 100, all passed; App
  Debug build succeeded; `swift-format lint --strict` adds no finding;
  `script/privacy_scan.sh` 0 findings; `validate_product_consistency.sh`,
  `validate_traceability.sh`, `check_project_drift.sh` pass. The scenario
  harness rendered Home in each lens and three lab matters in each lens
  against an organizing-device instance serving the lab demo copy (27 maps,
  6 ropes, 231 crossings; nothing taken in or sent; the store locked again
  after the run). On that data the read model derives in 421 ms with the v7
  fields and 421 ms without; Home 按时间 draws in 66 ms (75 ms without them);
  the 277-row Twin-7 matter draws its 线索 lens in 95 ms (2×, PNG included).
- Not done here: the full package suite and the check gate (only the four
  affected suites ran); the App's own UI tests.

## 2026-09-30 v7 agents read 织机, Mac side (`claude/v7-agents`)

**Review fixes (2026-09-30, `v7/review/FINDINGS.md`).** V7-A1: a split recording names only
in-scope matters (none under "ask first"). V7-A2: with numbers masked, search matches the masked
text and refuses a query holding a number. V7-A3: the client identity adds the parent's code
signature and an interpreter's script; version folders fold only for a signed parent. V7-A4: no
counts or person answers that hint at refused matters. V7-A5: a grant revoked while a call waited
for approval wins. Tests: `AgentReviewFixTests` (7), updated identity test.

AGENT-CONTRACT on the Mac; design in the "v7 Agent 读取织机" section of
`docs/architecture/TECHNICAL_DESIGN.md`, dependency choice in ADR-0008,
user guide in `docs/AGENTS.md`, PRD §0.3 item 11. Not installed; the App was
not launched. Synthetic data only.

- `mindloom-mcp` (stdio MCP) is bundled at `Contents/Helpers/`; it forwards
  to the App over `<data root>/agent/mindloom.sock` (folder 0700, socket
  0600, peer-owner check both ways) and answers "织机没有在运行，请先打开织机"
  when the App is not running.
- Tools `search_matters`, `get_matter` (text lens under the data header,
  item ids, or JSON), `list_deadlines`, `list_recent`, `get_person`,
  `add_to_inbox`; resource `mindloom://matter/<id>`.
- Consent for unknown clients (notification + panel: spaces, range,
  permission, duration, numbers, per-new-matter approval); grants in the
  Keychain + a MAC'd scope row; expiry and revocation on the next call;
  numbers masked by default with per-grant placeholders; audit rows without
  content; the Agent 收件箱 (accept makes an `agent:<name>` item); Settings ->
  Agent page. Library schema v25 (local tables).
- Claude Code plugin (`integrations/claude-code-plugin`, validated with
  `claude plugin validate`), Claude Desktop manifest, Codex/Cursor snippets.
- Not yet: spaces, ropes and strands are carried by the snapshot type but
  every matter is in 我的 until the spaces/map work lands; the consent panel,
  notifications and Settings page were checked by the App build only, not by
  running the App.

## 2026-09-30 v7 shared spaces, Mac side (`claude/v7-spaces`)

**Review fixes (2026-09-30, findings in `v7/review/FINDINGS.md`).** Members
and devices come only from the signed op log (`SpaceRoster`; `join.approve`
names the joiner's member id and both keys), so a device the Spark lists
gets no rotation key and signs for no one (V7-S1); the epoch in use is the
log's newest and this device's keys come only from wraps inside signed ops
(V7-S10); joins send a gate token and an HMAC binding the inviter checks,
never the secret (V7-S9), and a request under a known member id with another
key cannot be approved (V7-S2); the invite's host key must be this Mac's own
known_hosts key (V7-S14); one recording goes at most 15 minutes per space,
parts start unticked, one per recording, never by a rule (V7-S5); a local
delete queues `item.delete` in every space, durably (V7-S12); decrypted
originals live in a per-launch folder purged at launch, quit, and when the
item leaves (V7-S11); fork copies to delete are persisted and privacy
removals take them (V7-S15); only a signed removal deletes local data
(V7-S16); maintainers' titles are masked before the organizer (V7-S13);
another member's rule clear is ignored (V7-S17). Tests: `ReviewFixTests`
(16) in `MindloomSpacesTests`, two more in `SpaceMacTests`.

The member side of shared spaces (PRD §0.3 item 8 "共享空间", the shared
SPACES-CONTRACT; wire formats from the organizer's `docs/SPACES.md`). Design
in the "v7 共享空间" section of `docs/architecture/TECHNICAL_DESIGN.md`. Not
installed; the App was not launched. Synthetic data only.

- `MindloomSpaces` (new target of `Packages/MindloomLink`, CryptoKit only):
  device signing keys, signed ops / joins / requests, every ciphertext format
  (byte for byte the shared `space_vectors.json`, SHA-256 `4c1c1a18…7d1a`
  asserted), the space routes, invite codes that pin the organizing device's
  host key, rights per role and space type, the share review list, and the
  member flows: create (group or org), invite, join, approve with the key
  wrapped to the new device, verified sync (an op that fails verification is
  never applied), share with per-item data keys and sealed originals,
  withdraw / delete (a takedown request past an org space's window) /
  remove / hide / fork, privacy and other takedowns, proposals, leave and
  remove with key rotation, lazy re-wrap, the organizer lease (re-keys a
  store an older epoch still locks), audit, and access loss (the space's
  content, keys and fork copies leave this Mac).
- Mac integration: device and space keys in the Keychain (0600 files only in
  a synthetic root), space organizing payloads masked with the space's own
  mask key (screenshots only as the redacted copy), shareable content read
  the way the organizing link reads it (never a voiceprint, the dictionary
  or a window title; recordings only as their filed parts, at most 15
  minutes each, text only), the space read model with numbers put back for
  members, the "共享版更完整 · +N 条，来自 …" badge, the 全部 overlay with
  others' items in a second tone, and the link's own forward for the space
  routes.
- UI: 我的 / each space / 全部 / ＋ above Home; the bar under a matter
  (badge, 共享这件事…, 素材和权限…, 提议修改…); sheets for a new space, joining,
  invites and members (QR and code, approvals with fingerprints, roles,
  remove and leave, policy, archive), sharing (three scales, the review
  list), items and rights, the maintainers' review queue, and the audit
  records. A space's matters are edited through proposals (or directly by
  maintainers), never through the personal organizer.
- Not done: segment audio (blocked by "audio never leaves the Mac" until the
  user decides); the 整根绳 scale needs the matter map's ropes
  (`SpacesModel.ropeOf`); a second device of the same member (`device.add`);
  org admin management beyond the first admin; the restricted SSH key for
  teammates (Spark side).
- Verified: package suite (`swift test --skip QwenWhisperFeaturesTests`) 856
  tests, 20 skipped, 0 failed in 44 bundles (v6: 848 with 19 skipped); `MindloomLink` package 70
  tests (MindloomSpaces 23, one opt-in skipped); App Debug build succeeded;
  `swift-format lint --strict` clean on every new file;
  `script/privacy_scan.sh`, `validate_product_consistency.sh`,
  `validate_traceability.sh` and `check_project_drift.sh` pass. Against the
  spaces test instance with the real model: the two-device protocol run
  19/19 and the two-synthetic-library end-to-end run 22/22 (one matter
  assembled from both members' items, rotation, no plaintext on the Spark).
- Two-member end-to-end run on the lab demo's Twin-7 matter
  (`SpacesEndToEndTests`, SPACES-CONTRACT §5; synthetic scale-lab items split
  between 林知远 and 韩策, each Mac's own library with Fn dictations, a
  recorded meeting with voiceprints, a dictionary entry and screenshots;
  every request either Mac sends is scanned): 56 checks, green on the
  spaces test instance with the real model. It found two defects, both
  fixed: a recording part was titled with the recording's first words
  (words from a line never filed into the matter reached members) and dated
  at the recording's start — a part is now named and timed by its own
  lines, and a whole-text edit sends only the filed characters
  (`testAPartIsNamedAndTimedByItsOwnLinesOnly`); and one of 24 items
  sometimes landed in another shared matter, now kept with its package by
  the organizer's package step (organizer branch `claude/v7-spaces`).

## 2026-09-30 v6 integration, Mac side (`claude/v6`)

`claude/privacy-v6` (with the review fixes) and `claude/phone-link-v6` (with
`claude/phone-v6`) merged; design in the "v6 集成" section of
`docs/architecture/TECHNICAL_DESIGN.md`. Not installed; the App was not
launched. Synthetic data only.

- Masking spec v3 ported from the organizer: the third `otp` pattern (a code
  handed over later in the sentence); the shared vectors file is
  byte-identical (200 vectors, SHA-256 `94a79aff…5760`) and every vector
  passes in Swift.
- People pass on the Mac: persons carry the optional `status`; `not_person`
  is never shown; the event page shows at most six chips, most involved
  first, then "+N"; only people who take part in a matter (heard in its
  recordings or writing a speaker line in its texts) relate two matters, so
  the organizer's `mention` links show but never relate matters. The Home
  people row keeps its cap of five and hides `not_person`.
- F9: the sealed phone path is the only one; the Mac only reads and
  acknowledges the inbox and still takes in legacy plain entries like a
  paste.
- Found by the phone end-to-end run and fixed: Vision text recognition runs
  one request at a time with a GPU, then CPU fallback (two recognitions at
  once broke the Neural Engine path for the process and parked the phone's
  photo); a send copy that fails for a reason that may pass is retried with
  backoff instead of parked.
- Verified: full package suite (`swift test --skip
  QwenWhisperFeaturesTests`) 829 passed, 19 skipped, 0 failed in 44 bundles;
  App Debug build succeeded; iOS simulator suite (`iOS/script/xcodebuild.sh
  test`) 157 passed, 1 skipped, 0 failed; `swift-format lint --strict` adds
  no finding; `script/privacy_scan.sh` 0 findings;
  `validate_product_consistency.sh`, `validate_traceability.sh` and
  `check_project_drift.sh` pass. Against the integrated organizing-device
  test instance: privacy end-to-end 68/68, phone end-to-end (simulator app,
  real pairing through the relay, sealed inbox, unpair) 67/67 with both
  `authorized_keys` files byte-identical to the start.

## 2026-09-30 privacy v6 review fixes, Mac side (`claude/privacy-v6`)

Fixes for the adversarial review (review/FINDINGS.md); design in the
"隐私复查之后" subsection of `docs/architecture/TECHNICAL_DESIGN.md`. Not
installed; package tests and App Debug build only.

- F1: every request carries the key-derived access proof; a 403 `access`
  re-unlocks; sleep and quit lock the organizer's store (quit waits at most
  2 s), a failed lock is sent once more; the Spark also locks itself after
  10 minutes without a request.
- F2: screenshot redaction reads small and narrow images enlarged (tiles for
  long screenshots), joins rows, columns and wrapped lines, covers long digit
  runs and look-alike separators; the review's 13 synthetic layouts: 0 leak
  (was 7), and the Spark vision model reads no number from the 13 copies.
- F3: file bytes leave only as a send copy (pictures redacted, audio/video
  and embedded objects emptied, scanned PDF pages redrawn and redacted,
  `pictures_redacted` set); pictures under another name are taken in as
  pictures.
- F6/F14: deleting a recording deletes its keyframe items and queues their
  remote deletion; an item whose send was in flight at revocation still gets
  its remote deletion.
- F8: masking spec v2 (184 shared vectors).
- F11: forgetting never goes on with a key it could not destroy.
- F16: a file too large to send carries the digest of the text sent.
- Verified: full package suite 801 pass, 18 skip, 0 fail
  (`--skip QwenWhisperFeaturesTests`); App Debug build succeeded.

## 2026-09-30 phone link, Mac side (`claude/phone-link-v6`)

Not installed; the App was not launched. Built on `claude/privacy-v6` with the
iPhone branch `claude/phone-v6` (MindloomLink, the iPhone app) merged in.
Covers the Mac half of the shared phone contract (§3–§6): the seal key,
sealed inbox ingest and pairing. Design in the 2026-09-30 "手机" section of
`docs/architecture/TECHNICAL_DESIGN.md`; PRD §0.3 items 2 and 8 and §2.2
extended (IDs unchanged). Not yet run end to end with the iPhone app and a
live organizer (see "Not done" below).

- Seal key: one X25519 key pair per data root in the login Keychain
  (`com.bestasr.phone-seal-key`; file store only for synthetic roots, 0600),
  made on the first pairing and kept across pairings.
- Sealed inbox: `{"kind":"sealed","blob":"mlseal1.…"}` entries are opened
  with `MindloomSeal.open(blob, entryID: inbox_id)` and validated with
  `InboxItemPayload.decode`; text, links (as title/note/URL text, never
  fetched), images and files go through the normal intake paths, the source
  App is the payload's `source` ("iPhone 键盘"/"iPhone 分享") and the time
  its `created_at`; commit, then acknowledge. Entries that do not open
  (old pairing's key, another Mac, changed, moved to another ID, never
  paired) or open to something that is not an item are acknowledged and
  counted once after the acknowledgement: "N 条手机内容无法打开（配对已更换）"
  in Settings → 数据 → iPhone, kept across launches until "知道了".
- Pairing ("连接 iPhone", only while the link is on): `ssh -G` for the
  organizing device and one `ProxyJump` relay; host keys only from the Mac's
  own known_hosts via `ssh-keygen -F` (ed25519 first, ECDSA, never RSA;
  missing → refused, nothing installed); `zhiji-inbox authorize-phone
  --key-id <id> --pubkey -` with the key on stdin; on the relay the pinned
  copy of `spark/relay-authorize` on stdin to `sh -s -- add …`; relay failure
  takes both lines back. QR (CoreImage) and "复制配对码" (pasteboard marked
  concealed); the code with the phone's private key lives only in memory
  while its window is open. "断开 iPhone" removes both lines (kept paired if
  either host fails). Every remote word checked with the link
  configuration's character rules.
- Package tests (`swift test`, build products on the offload volume):
  `PhoneLinkInboxTests` 4 and `PhonePairingTests` 13, all green, plus the
  existing inbox and copy-rule tests. They include the real `ssh -G` and
  `ssh-keygen -F` on synthetic config and known_hosts files (no network),
  the relay helper run with the Mac's exact commands on a synthetic home,
  and the QR code decoded back by CoreImage into the same `PairingPayload`.
  Whole package (`swift test --skip QwenWhisperFeaturesTests`): 819 tests,
  0 failures, 18 skipped (the usual opt-in/hardware ones). App:
  `xcodebuild -scheme BestASR -configuration Debug build` succeeded, no
  warnings in the changed files. `swift-format lint --strict` and
  `script/privacy_scan.sh` clean on the changed code;
  `validate_product_consistency.sh` and `validate_traceability.sh` pass.

Not done:

- No end-to-end run yet (iPhone simulator → organizing device → this Mac).
  The organizing device's `authorize-phone`, `--sealed` gate and sealed
  inbox are on its own `claude/phone-link-v6` branch, not yet merged there.
- Pairing was not run against the real organizing device or a real relay:
  it would write `authorized_keys` on hosts the user owns. Command lines,
  stdin and failure handling are covered by the tests above.
- The Keychain seal-key store is not exercised by automated tests (it would
  write to the user's login keychain); tests use the file and memory stores.
- A zip shared from the phone is kept on the Mac whole (not expanded as a
  dropped zip is); an image's caption text, if a phone ever sends one, is
  not kept.

## 2026-09-30 privacy v6, Mac side (`claude/privacy-v6`)

Not installed. Run end to end against a live organizer of the same contract
(SQLCipher store, `/v1/unlock`, `/lock`, `/wipe`, `DELETE /v1/items/{id}`,
read-then-delete; service branch `claude/privacy-v6`) on a synthetic data
root: `PrivacyEndToEndTests` (opt-in), 67 of 67 checks green. Design in the
2026-09-30 section of
`docs/architecture/TECHNICAL_DESIGN.md`; PRD §0.3 item 8 extended (IDs
unchanged).

- Masking spec v1 in Swift, byte-identical to the shared reference on all
  123 shared vectors (`privacy/mask_vectors.json`, SHA-256 asserted); every
  text field that leaves is masked when the wire body is built, the
  placeholder map is recorded first (`remote_mask_map`, local only), and
  every string that comes back is shown with the originals (a colliding or
  unknown placeholder shows as `〔手机号〕`); segment offsets are mapped back
  to the original text.
- Library key per data root in the login Keychain (file store only for
  synthetic roots); `POST /v1/unlock` is the first data call, 423 re-unlocks,
  a store of another key or a service that cannot lock gets nothing.
- Screenshots and video keyframes are sent only as redacted copies (Vision
  on this Mac, detectors per line and across lines stacked under one another,
  two readings with and without language correction, boxes painted, no
  metadata). The end-to-end run found a chat bubble that wrapped a card
  number and a key onto the next line, and a key prefix read as `Sk-`; both
  left unredacted before this fix (regression tests in `IntakePrivacyTests`).
- Audio or video never leaves as bytes whatever its name; zips are expanded
  here under limits; other archives and unreadable binaries stay here
  ("只保存在 Mac 上"); camera RAW goes through the image path.
- Deleting a sent item queues its deletion on the organizer (kept across
  revocation and archive import, sent first after unlock); turning the link
  off locks the organizer's store (best effort, 2 s); "让整理设备忘掉我的内容"
  (settings, with confirmation; the contract's "让 Spark 忘掉我的内容" in the
  pages' own words) wipes it and destroys the key; wrong-key status with
  "让整理设备忘掉旧内容".
- Identical file bytes are stored once (hard links + content index, removed
  with the last item).
- Schema v24 (local tables only; v23 archives import unchanged).
- Verified: package tests (masking vectors, unlock order, wrong key, 423,
  unsupported service, masking on the wire and restoring on screen,
  collisions, media never sent, deletions across revocation and import, lock
  on revoke with a hung organizer, forget, Vision redaction, zip limits,
  local-only rules through the store, dedup); the full package suite (784
  pass, 18 skip, 0 fail, `--skip QwenWhisperFeaturesTests`); App Debug build
  (before the redaction fix).
- End to end (`PrivacyEndToEndTests`, real SSH link, synthetic items with
  seven kinds of sentinel identifier and per-item markers in a dictation, a
  pasted text, a PDF, a chat screenshot and a spreadsheet): only placeholders
  in every text field on the wire; no sentinel, marker or key in any file of
  the organizer instance (about 14,500 files, 330 MB, scanned over SSH), while
  the markers are in its decrypted rows and no sentinel is; image and file
  bytes gone after reading; originals shown on the Mac where it knows them,
  `〔手机号〕` where it does not; a deleted item purged there within one scan,
  one deleted while the link was off sent first after the next unlock;
  link off → 423 and `locked: true`; "forget" wipes the store and replaces
  the key; the last store wiped while locked leaves no store files.

## 2026-09-28 every file type, Mac side (`claude/files`)

Not installed and not yet run against a live organizer; the organizing
device's file reader follows the same contract on the service branch. Design
in the "所有文件类型" section of `docs/architecture/TECHNICAL_DESIGN.md`.

- Any dropped or pasted file is taken in (no more "不支持 .xyz"). Documents the
  Mac reads completely stay text-only; everything else is a new `file` item
  kept byte for byte with the text read here, sent with its bytes (≤25 MiB),
  or as its text with the file facts when larger, or kept local with a
  visible reason. Scanned and password-protected PDFs are now sent.
- Images of every common format are normalized; SVG is drawn only when
  self-contained; a GIF sends up to three more distinct frames.
- Audio stays on the Mac; formats this Mac cannot decode are refused with a
  reason. Video gives up to 12 scene-change keyframes (no model) as image
  items under the recording, sent with `parent_item_id`/`frame_ms`.
- Schema v23 (`user_item_details` rebuilt; v22 archives upgrade with NULLs).
- Memory pages: file rows with type icon, name, size, counts, the device's
  summary, fields, text (tables drawn as tables) and inner files; keyframe
  strip under recordings. The event export carries the same, quoted.
- Scenario items may ship any asset file, dropped through the real intake.
- Verified: package tests for classification, extraction, size caps, GIF
  frames, keyframes from a synthetic AVAssetWriter video, the v23 upgrade,
  wire encoding against a fake Spark, reading-facts decoding, rows and export;
  file and video snapshots in light and dark.

## 2026-09-28 scale features, Mac side (`claude/scale-features`)

Not installed and not yet run against a live organizer; the organizing-device
side (item-split skill, `/v1/inbox`, concurrency) is on the service branch.
Details in the 2026-09-28 section of `docs/architecture/TECHNICAL_DESIGN.md`.

- Meeting transcripts exported by 腾讯会议, 飞书, Zoom and WebVTT/SRT read as
  turns in the event timeline and the text export (`MemoryTranscriptText`).
- Split items: `events[].segments` decode; each event shows only its part with
  "同一段…还涉及 N 件事 ›"; the export has only the part and names the other
  events; corrections on a part carry `seg_id`, applied by the local overlay.
- Phone inbox: the link pulls `/v1/inbox`, takes each entry in through the real
  intake as a user item from "iPhone" captured at `received_at`, and
  acknowledges after the local commit; idempotent per entry.
- Scale: the read model is built once and off the main thread; Home shows 24
  cards then "显示更多", eight people then "全部人物 ›"; timelines are lazy.
- `ScenarioEndToEndTests` ingests a whole scenario directory at a set pace.
- Verified: new package tests (transcript formats, segments, overlay, inbox
  with a fake Spark, 2000-item read model, offline scenario intake), the full
  package suite (696 pass, 14 skip, 0 fail, `--skip QwenWhisperFeaturesTests`),
  scale snapshots in light and dark, and the App Debug build.

## 2026-09-26 hackathon scope and own-device organizing

PRD §0.3 (user decision, 2026-09-26) sets the scope of the hackathon build
due 2026-09-29 23:59 China time. The Mac collects and recognizes; the user's
own DGX Spark organizes. EVENT-\*, PEOPLE-\*, IMPORT-\*, ROOM-\* and SYS-\*
are unfrozen for this scope with their IDs unchanged. Audio, voiceprints and
dictionaries never leave the Mac. Transcripts, user-provided items and their
source metadata may go only to the Spark, over an explicitly enabled,
revocable SSH link, only for organizing. The v1 organizer API, tunnel,
idempotency and failure behaviour are specified in the "Remote organizer"
section of `docs/architecture/TECHNICAL_DESIGN.md`. In this phase only
synthetic data is sent to the Spark; the user's real library is not sent.

Branch `hackathon/base` (from `dictation-fast-path` at `10c928d`) holds the
Mac foundation for this scope:

| Commit | Change | Verified |
|---|---|---|
| `d10703e` | Xcode 27.0 / Swift 6.4 toolchain migration | Bootstrap fixtures, project drift, Debug build, 160 hosted App tests |
| `f54c58c` | Swift 6.4 GRDB async-overload fixes; the Swift package compiles again | `swift test --skip QwenWhisperFeaturesTests`: 525 pass, 10 skip, 0 fail |
| `2d4bebf` | Silent takes keep their audio; startup cleanup removes only verified-empty journals | 165 hosted App tests, including 5 new |
| `981f4d6` | Clipboard restore only while bestASR still owns the clipboard; promise waiter races fixed | 24 Delivery tests pass, 4 skip (need Accessibility); 165 hosted App tests |
| `0cf17c2` | `check.sh` runs the Delivery test contract instead of the removed probe; stale traceability path and alpha-target fixture fixed | Probe 24/24, contract validation, traceability, shell fixtures |

Present in the code from earlier candidates. These are available to build
on; none is re-accepted for this scope:

- Fn dictation into any App with exactly-once delivery, History, Dictionary
  and the personal cleanup model. This path is in daily use (installed
  `d54fb45`).
- Room recording, system-audio recording (Process Tap) and audio/video
  import, with the shared speaker pipeline, global people, naming and
  merge/split/undo.
- Local event memory: events, candidates, the Events page and
  `LocalEventOrganizer` (on-device Apple NaturalLanguage). It is the
  fallback organizer when the Spark link is unavailable.
- Per-record TXT/Markdown/SRT/VTT/JSON export, source-audio export and the
  encrypted `.bestasrarchive`.

Bridge progress on `codex/spark-organizer-bridge` / `claude/bridge-fixes` and
the sibling Spark service branch (not yet accepted as an installed
product):

- The Mac has a default-off Spark setting stored per library (an enable
  watermark in `remote_organizer_meta`), and the link logic lives in the
  `BestASRRemoteOrganizer` package module.
- Data-provenance guard, in every build configuration (`script/lint.sh`
  rejects conditional compilation in the module and its app glue): the link
  starts only when the active data root holds a `SYNTHETIC_DATA_ROOT` marker,
  and that root's `history.sqlite`/`-wal`/`-shm` and `assets` are its own
  files (no symlinks, no hard links, not the real library's files). The real
  library is found from the account database (not `HOME`) and compared by
  file identity, so symlink, firmlink, case, `/.nofollow`, `/.resolve` and
  `/.vol` spellings are all refused, even with a marker. A demo root is
  chosen per launch with exactly `-BestASRDataRoot <absolute path>`; any
  other mention of the option (empty or missing value, misspelling, `--`,
  `=`, repetition) fails startup instead of falling back.
  `script/make_synthetic_data_root.sh` marks only a directory it creates
  itself. The one release switch,
  `RemoteOrganizerDataProvenance.productReleaseAllowsOwnLibrary`, stays
  `false`.
- Tunnel: the Mac forwards a kernel-chosen random loopback port to the
  organizer's Unix socket in its 0700 data directory
  (`-L 127.0.0.1:P:<absolute socket path>`), so no other process on the
  Spark can stand in for the organizer while it is down. Before every HTTP
  request the app checks, through libproc, that its own ssh child owns the
  listener. Every request carries the link token, read into memory only
  through a separate `ssh <host> cat <token path>` command. Stale forwards
  are cleaned at launch (independent of the library and preferences), before
  the provenance check on enable, and on disable, only on an exact
  command-line match. The HTTP transport can no longer create a task on an
  invalidated session (that aborted the app).
- Revocation is synchronous at the UI boundary (`revokeNow()` before any
  await) and fails closed: the link resumes at launch only when an "on"
  marker kept outside the library (keyed by the root's canonical `F_GETPATH`
  path) and the library watermark both exist. Turning it off only unlinks
  the marker (works on a full disk; a failed unlink shows "storage
  unavailable"), and a watermark without the marker makes the next launch
  retry the revocation before anything starts. Turning the link off clears
  the pending outbox; re-enabling sends nothing by itself. Only sessions the
  live capture path explicitly marks while the link is on are eligible
  (`markLiveCaptureRemoteEligible`; `create` never grants it), so archive
  and history imports and captures made while off are never sent
  automatically; the (unpublished) history importer refuses a library whose link is on. A
  decision in flight at revocation is shown as possibly delivered and cannot
  be discarded; "确认送达" re-issues it at the end of the commit order (like
  any retry) so the Spark and the local overlay end in the same state.
- Revision outbox: one job row per session holds the target, attempted and
  delivered revisions, content digests, state, retry count and error
  category. The payload is built when a send is claimed, from the latest
  committed text, the session's accepted speaker/person assignments (also
  for whole-text edits without segments) and display names clamped to the
  service limits in Unicode scalars. SQLite triggers mark a tracked session
  changed in the same transaction as each edit path; tests drive the real
  store APIs for confirm, rename, re-recognition, whole-text edit, restore,
  source metadata and retire. Unsendable sessions are parked, keeping their
  used revision numbers. The poll sweep adds eligible sessions missing a job.
- Decisions are delivered strictly in local commit order. A retry re-issues
  the correction under a new ID at the end of that order, as a plain
  decision, because the Spark replays stored receipts (including
  rejections). A permanently rejected decision stays in effect locally and is
  listed as "Spark 未接受" with its reason. A portable-archive import turns
  the link off; restored decisions are listed as not sent and leave only on
  retry, and a marked synthetic root refuses archive import.
- Store reset: on a new `store_id`, the Mac clears its projection and
  cursor, re-sends the latest revision of every delivered item, re-sends the
  people decisions in order, and retires decisions about the old store's
  events and questions (`store_reset`).
- While the link is on, the Events page shows only the Spark projection. When
  it is off, the local organizer remains the fallback.
- Schema v21 adds `remote_organizer_eligible` and the decision job's
  `store_id`, and clears pending v19/v20 work in libraries whose link is off.
  Portable archives from v12 through v20 import (missing `duration_ns` and
  `spoken_mode` are filled with NULL), tested from databases really migrated
  to each old version.
- Service side (Spark organizer, `claude/bridge-contract`): Unix-socket
  serving, a question whose decision could not be applied is stored as
  failed and replays its outcome, and the demo status check and recall
  script send the token.
- Evidence: `BestASRPersistenceTests` (71, including the organizer link rule,
  real edit-path, migration and portable-upgrade tests) and
  `BestASRRemoteOrganizerTests` (31 deterministic tests plus the opt-in live
  smoke, skipped) passed in SwiftPM; the Spark suite passed (72). The app
  build, the full package suite and the hosted App tests still have to run in
  the guarded build step, and the live smoke needs the Spark to serve the
  socket (`spark/ctl.sh restart`).
- The Spark service runs on the owner's Spark with Qwen 3.6 and the four required
  skills. Decision delivery has stable receipts, so retries do not apply a
  correction twice.
- Explicit Mac session deletion removes its item job. The v1 API has no
  remote source-deletion call: an item already delivered remains on the
  user's Spark. This is a material gap before ordinary private-library use.
- Not yet done: `name_person` decisions are not emitted. Person names reach
  the Spark through new item revisions. The local organizer still runs in the
  background while the link is on; only its list is hidden.

Intake, source labels, item outbox and event export on `claude/intake-export`
(from `hackathon/base`; design in the "收进来" section of
`docs/architecture/TECHNICAL_DESIGN.md`; not yet accepted as an installed
product). Requirement IDs touched: PRD §0.3.2/§0.3.5/§0.3.6/§0.3.8,
IMPORT-001, IMPORT-007, IMPORT-008, HIST-005, EVENT-005, EVENT-009.

- A pasted or dragged text, image, or document is a completed session with
  input mode `userItem`; its text is a `final` transcript revision, its files
  are retained source assets (`userProvidedOriginal`, `normalizedImage`) with
  digests, and schema v22 adds the portable `user_item_details` table. Search,
  explicit deletion, events, the portable archive, and the organizer outbox
  treat items like recordings; corrections are `userEdit` revisions.
- Intake (`BestASRIntake`, Apple frameworks only): ⌘V in the main window when
  no text is being edited, the "收进来" command (⇧⌘V), and drops anywhere on the
  main window. Plain/rich/HTML text, PNG/TIFF/JPEG/HEIC images (a ≤2560 px,
  ≤12 MB PNG/JPEG copy without EXIF next to the original), PDFs (PDFKit text
  layer; scans kept with empty text, titled by filename, not sent),
  .txt/.md and other system text types (csv, json, log, yaml, patch, source
  code), .rtf/.docx/.html documents, and several files at once. Screenshots
  get an on-device Vision text reading stored as a derived revision
  (searchable, exported, never sent). Files inside the real library or the
  active data root, web links, symlinks, text over 16 MB, and clipboards
  marked concealed/transient/auto-generated or written by bestASR itself are
  refused; holding ⌘V takes the clipboard in once. Audio/video goes to the existing
  import pipeline one file at a time. Unsupported types are refused with
  "不支持 .xyz，未收进来"; the user's file is only read. Staged files carry a
  marker until the rows commit; startup removes uncommitted staging.
- Source label: the App frontmost before bestASR became active (paste), or
  the drag source (Finder for files from Finder), with bundle ID and name;
  the user can change it from the history row, which is a new revision.
  Import sessions routed through intake carry the source App too. Accessory
  Apps (launchers, password panels) never become the source; files dropped
  while bestASR is active are labelled Finder.
- Outbox: same eligibility and revision rules as captures. Payloads carry
  kind text/image/document, the App label, capture time, and text; images
  are read at send time from the provenance-checked asset root without
  following links, verified by size and digest, and sent only as
  `image_b64`. Filenames and originals never leave. The privacy sentinel
  tests cover the new kinds.
- Export: "复制这件事" (marked as bestASR's own copy) and "导出为文本…" (.txt)
  for a Spark event (card menu) or a local fallback event (detail header),
  from a deterministic formatter: a date line, one preamble line, per item a
  time/source (and file name or user title) header, and every body line
  quoted with "> " so item text cannot forge another record; transcript
  speaker names match the 人物 line.
- `MemoryProjection` (`BestASRMemory`, Foundation only) gives the upcoming
  Home, Event, and People pages their read model; only a confirmation toast
  and "来源" chips were added to the current UI.
- Evidence (SwiftPM, synthetic data): `BestASRIntakeTests` 13,
  `BestASRMemoryTests` 5, `UserItemPersistenceTests` 7, domain
  `UserItemTests` 3, `RemoteOrganizerItemAssetTests` 2, plus the existing
  `RemoteOrganizerPersistenceTests`, schema/migration tests (including the
  v12–v21 portable upgrade), `DomainModelTests`, and all
  `BestASRRemoteOrganizerTests` passed. The whole package suite, skipping
  `QwenWhisperFeaturesTests` (needs Metal) and the Delivery tests (they use
  the real pasteboard), passed: 586 tests, 7 skipped, 0 failures. The App and
  its test bundles were built with `xcodebuild build-for-testing`; the App
  was not run, and hosted App tests and UI tests were not run. The full
  `script/check.sh` gate was not run.
- Review fixes (2026-09-27, same branch): the items above marked as
  refusals, the staging sweep that intake now waits for, a history list that
  carries at most 20,000 characters of an item (full text for detail, copy,
  export), local fallback organizing right after intake and source changes,
  date spans on `MemoryProjection` cards and details, and a one-line local
  status. The media queue is still memory-only; its confirmation now says
  so instead of promising a queued import. Evidence: `swift test` for
  BestASRPersistenceTests, BestASRDictationTests, BestASRIntakeTests,
  BestASRMemoryTests, BestASRRemoteOrganizerTests and BestASRDomainTests
  passed (synthetic data; one Vision test reads a rendered synthetic
  image); the App was built with `xcodebuild build`, not run.
- Not done: the Spark's per-item screenshot reading is not in the v1
  `/v1/state` response (the local Vision reading is used instead); OCR of
  scanned PDFs; a durable media-import queue; double-⌘C capture (P1); the Home/Event/People redesign;
  a source picker richer than typing an App name.

Memory pages, organizer-quality client changes and the 织机 display name on
`claude/memories-ui` (from `hackathon/base` at `018c7c3`; design in the
"记忆页" section of `docs/architecture/TECHNICAL_DESIGN.md`; not yet accepted
as an installed product). Requirement IDs touched: PRD §0.3.5–§0.3.8,
EVENT-005, EVENT-009, PEOPLE-*, IMPORT-007.

- Client adoption of the organizer-quality API: local UTC offsets on item
  times, `unfile_item` and `file_item_new_event` (client event ID), the
  complete `unfiled[]` set per pull (cleared on a store reset) with the local
  overlay for remove/unfile/file-new/move/answers, `handle`/`anchor`, status
  facts with state/date/quote, the three `same_event` shapes, 72 h question
  expiry, and the health `clock` (a non-`wall` clock is noted in Settings).
- `BestASRMemoryUI`: Home (people row, one question, Unfiled row, event
  grid with pin/feature-less on the card), Event (facts, day timeline with
  inline questions, in-place rename and item corrections, related events,
  copy/export as text), Person (rename in place, review rows, their events),
  People, Unfiled; 全部 is the existing history. With the link off the same
  pages run on the local organizer (pin and feature-less hidden).
- Display name 织机 (InfoPlist catalog en/zh-Hans, purpose strings, window,
  menu bar, visible copy); bundle IDs, `bestASR.app`, the data folder and
  module names are unchanged.
- Evidence (synthetic data): SwiftPM `BestASRPersistenceTests`,
  `BestASRMemoryTests`, `BestASRMemoryUITests`, `BestASRIntakeTests`,
  `BestASRDomainTests`, `BestASRRemoteOrganizerTests` passed; the App was
  built and the 167 hosted App tests passed (test host only, not launched);
  snapshots of Home, Event, Person, Home with a question, Unfiled, empty
  Home and the link-off fallback in light and dark were rendered by
  `MemorySnapshotTests` (`BESTASR_UI_SNAPSHOT_DIR`). UI tests were not run:
  `BestASRUITests` still address the old sidebar and need updating before
  the old Home/Events/People views are deleted. `script/check.sh` was not run.
- Review fixes (27 findings): on-accent label token; Reduce Motion without
  matched geometry; keyboard and VoiceOver paths for cards, rows, renames and
  item corrections; searchable move/file picker; first-run setup cards in the
  Zhiji style; item questions that name their item; stretch-only playback for
  voice questions; search over item text; owner excluded from people; no
  excerpt shown as a status; not-loaded vs empty; unaccepted corrections on
  Home; later removals supersede earlier placements in the overlay; events
  emptied by the user's corrections hidden; rename also recorded as a
  decision; move from the page the user is on; Unfiled from the unfiltered
  set; zone follows the Mac; copy rules extended to the reachable App pages
  by a source scan (status messages composed in `DictationAppModel+*.swift`
  are not yet covered). Evidence: SwiftPM suites above plus the new tests
  passed; 171 hosted App tests passed; snapshots re-rendered (adds Home with
  setup, Home with only Unfiled, Home with corrections not taken, People and a
  link-off Event page). The 全部 list is still the older history view.

Still to build for the hackathon product:

- Final product acceptance for the Mac organizer client, including the
  installed Release build launched on a synthetic data root, explicit Spark
  source deletion, reconnection and revocation under real failure, and the
  full project gate. The service and
  skills are in the sibling repository, not this branch.
- Acceptance of intake in the installed app (see the intake entry above;
  the data layer and minimal hooks exist, the page redesign does not).
- Double-⌘C capture (P1, later; it must work in every App).
- The Photos-Memories home: flat events with an automatic title, one status
  line, people, time-ordered items and one default order (importance plus
  recency), with pin, "feature less" and rate-limited yes/no questions.
- Acceptance of the one-event plain-text export in the installed app.

Gate state on this branch:

- The bridge branch's `script/check.sh` attempt stopped in `bootstrap`:
  a temporary build volume had about 17 GiB free against the repository's
  25 GiB soft reserve. A separate strict Swift-format run still reports
  inherited formatting debt in older App files; the newly added bridge files
  lint clean. The full gate must be rerun after build-storage capacity is
  available.
- UI tests were not run.
- Developer ID signing and notarization remain unavailable.
- Evidence regenerated by partial gate runs (check summary and readiness
  reports) was not committed.

## 2026-09-25 Xcode 27 toolchain migration

The active development toolchain is Xcode 27.0 (27A266a) with Swift 6.4. The
project generator, bootstrap version checks, Metal Toolchain check, and Swift
compatibility runtime inventory now match that toolchain. The Metal Toolchain
component was installed. The generated Xcode project is deterministic.

On a temporary internal build volume, preflight, Debug and Release builds,
`build-for-testing`, and 160 hosted App tests passed. The Release app passed
strict signature verification, package validation (45 registered files), and
local DMG smoke. Developer ID signing and notarization remain unavailable in
this environment. These results verify the build and local package under Xcode
27; they do not establish installed product acceptance.

The complete `script/check.sh` gate stops at static analysis because of the
existing Swift formatting debt described below. The original external build
volume has less than the required 25 GiB free-space reserve, so builds here use
`BESTASR_BUILD_VOLUME=/Volumes/<build-volume>`; the disk safeguard was not
lowered. Historical Xcode 26.6 evidence below remains tied to its original
candidate and is not reinterpreted as Xcode 27 evidence.

## 2026-09-22 interaction recovery — signed candidate, installed check blocked

Direct inspection of installed revision `d54fb45` reproduced a roughly 60 pt dictionary selection layout shift. Read-only queries on the then-current 5,742-session library measured a source-filter first page at about 41 ms, while refresh also waited for full-library usage (~2.99 s), activity (~2.73 s), and legacy audio-index scan (~1.05 s). These are SQL timings, not end-to-end UI latency. Source clicks also triggered two refreshes; pagination checked row count rather than query identity. Code limited the source selector to ten Apps (the inspected library did not exceed that limit) and dictionary searches to 200 words without pagination.

Changes:

- Bounded, cancellable history queries publish independently of overview/maintenance. Query identity and request generation protect first-page, pagination, and Enter-to-open behavior. Candidate phases are filtered before pagination; errors retain readable context and expose retry. Timing logs contain only elapsed milliseconds and result count.
- Four stable condition summaries open a searchable in-page inspector. Dictionary selection reuses a measured toolbar; editing and transfer use pages with working Escape/back behavior. All matching words are reachable through 100-word pages.
- Secondary capabilities have direct sidebar entries marked as being improved. History details expose their existing actions directly. This is not acceptance of recording, people, events, or other remaining popup-based flows.
- Release signing uses the available stable development identity instead of a different hard-coded team. Replacing the App no longer implicitly relocates runtime caches or alters their symlink.

Verification: 160 hosted App tests and seven real UI tests passed, including query races, SQLite pagination, minimum-window selection geometry, transfer navigation, and existing history playback/search/keyboard journeys. After screenshot review found a false loading banner, its affected real UI test was rerun and passed. The installer fixture verifies that runtime-cache metadata is unchanged. The Release candidate at `87e808a764c1c0a0bd8f0d5dc2a5f2e8bac98184` built successfully, passed strict code-signature verification with the existing team, and passed package validation (61/61 files, valid SBOM/NOTICE, no unregistered binary/model). The real privacy scan and its exact Git-metadata exclusion regressions passed with zero findings. The candidate has not replaced the running installed App: the native UI observation tool repeatedly failed, including after reset and after compilation finished. Consequently current capture idleness and installed same-library filter latency could not be verified. No production restart or data mutation was performed, and fixture/SQL timings are not presented as installed UI performance.

The full `script/check.sh` was executed and stopped at `bootstrap` (`xcodeFirstLaunchIncomplete`, independent Xcode check exit 69); later stages were not run by that command. Actual Debug build and the tests above passed independently. An independent formatting comparison found 618 remaining diagnostics versus 795 at the base revision; the only new diagnostic was fixed, and affected files passed targeted lint. Existing repository formatting debt remains a separate blocker; no all-green release-gate claim is made. The Codex Security service is unavailable in this session; SQL, cancellation, logs, source evidence, and signing/cache changes received local diff review only.

Remaining product work includes continuous installed journeys for dictation/translation/commands and correction learning, recording/import/people/events, remaining popup interactions, long-library resource/performance limits, failure recovery, and distribution gates. Existing code, old reports, and passing fixtures do not establish those outcomes.

## 2026-09-18 dictation-first reset

PRD V1.6 §0.1 narrows the V1 release gate to daily-usable dictation and freezes
room, system-audio, and import recording, together with global people, events,
meeting organization and archives, at V1.x. The sections below this one describe
the 2026-08-30 candidate and remain the record for the frozen features.

The 2026-08-30 installed build was not usable day to day. Four causes were confirmed:

1. **Runtime refused to start.** `~/Library/Caches/com.bestasr.app` pointed at the
   unmounted `/Volumes/BestASRBuild`. `applicationCacheRoot()` threw, so no
   database, runtime, or hotkey was created.
2. **Insertion gave up.** It required the start element and selection to be
   unchanged and never pasted into apps without an AX text element, so results
   often went only into history.
3. **End-to-insert took about 3.5 s at best.** The full-utterance Qwen re-decode
   and forced alignment ran, then local LLM polish with no insertion deadline.
4. **Default pause shortcut conflicted with the IME.** It was Control-Space,
   which macOS uses for "previous input source".

About 19 days of uncommitted Codex work was preserved unchanged as
`archive/codex-wip-20260918` (`ccae056`). Work continues on
`dictation-fast-path` from `494f935`, the code-identical installed revision.

Changes in this batch:

- **Cache fallback.** A cache link whose target is unavailable now falls back to
  a local `com.bestasr.app.local` cache. The user's link is left untouched.
- **Insertion rules** (PRD 7.3):
  - Same app: insert at the current caret, even if the caret or field moved.
  - Retained for copy: an app switch, a protected field, or newly highlighted
    text.
  - Composers with no AX text element: `⌘V` into the same frontmost app, then
    restore the clipboard.
  - Every retained result is copied to the clipboard with an explicit "⌘V"
    prompt (DICT-007).
- **Polish deadline.** `TimeBoxedDictationPolishAdapter` limits model polish to
  0.8 s before insertion. A later model result that passes the protected-fact
  gate becomes the record's current polished text once insertion has committed.
- **Pause shortcut.** The default is now Fn-Space. A saved configuration still
  holding the retired Control-Space default migrates automatically.
- **Live windows.** The 30 s live-window starvation fix was taken from the
  archive: the oldest windows drain first and silent windows advance.
- **Timing logs.** Content-free `dictation timing stage=… ms=…` notices now cover
  start-to-capture, seal, live barrier, Qwen load/decode/align, model polish,
  insertion, and end-to-inserted.

Verification:

| Check | Result |
|---|---|
| Affected SwiftPM tests | 40 insertion/live, 3 polish-deadline, 11 hotkey: all pass |
| Hosted App tests (Debug) | 94 pass, including the cache fallback |
| Release build | Signed with the existing Apple Development identity |

The Release build is installed as `494f935+dictation-fast-path-uncommitted`. On
launch, the installed App logged the local cache fallback, registered both
shortcuts, and finished Qwen prewarm 13 s later. The saved Control-Space pause
migrated to Fn-Space.

The first installed timing breakdowns come from two user dictations at 23:19,
with content-free timing notices only:

| Stage (ms) | 10.4 s audio | 4.9 s audio |
|---|---|---|
| Start to capture | 203 | 242 |
| Seal | 68 | 60 |
| Qwen decode | 2795 | 269 |
| Qwen align | 274 | 95 |
| Model polish | 397 | 278 |
| Insertion | — (no captured target) | 463 |
| **End to inserted** | **3592** | **1214** |

The 10.4 s decode ran after 19 idle minutes. Its real-time factor of 0.27,
against 0.055 for the 4.9 s case and about 0.1 in the public benchmark, points to
cold model pages rather than length.

A lightweight dictation capsule replaced the 500×184 top panel, per PRD V1.6
§0.1 item 8:

- **Placement and states.** It sits at the bottom centre and never becomes key.
  A level-driven waveform shows while listening, then paused, processing,
  inserted, copied, and failed states.
- **Hover.** Hovering shows cancel (two-step) / pause / finish and the latest
  draft line.
- **Bare Space.** It pauses or resumes only while a dictation is recording or
  paused.
- **Fn as start/end.** When Fn alone is the start/end shortcut:
  - Holding it at least 350 ms ends on release; a shorter tap stays hands-free.
  - Another key within 700 ms of the Fn press cancels the dictation it started;
    the chord still reaches the app.
  - Fn-alone start rejects any Fn-modified pause.
- **Status.** Implemented and tested: MacUI/MacAudio 29 and hosted App 95 pass.
  - **Live switch done (2026-09-19).** Other dictation tools that also used Fn
    were quit before the switch.
  - **Installed shortcuts.** The App now runs Fn start/end with ⌥Space pause,
    the event tap is enabled, and the saved configuration persisted across
    relaunch.
  - **Still needed.** The macOS "Press 🌐 key to" setting must be set to "Do
    Nothing" by the user; the App does not change system settings.

Fn-era dictations (00:10–00:12, 1.3–1.9 s audio) measured:

| Stage | Time |
|---|---|
| Start to capture | 266–293 ms |
| Qwen decode | 177–437 ms (mostly fixed overhead) |
| Align | 55–68 ms |
| Polish | 256–301 ms |
| Insertion | 460–471 ms every time |
| **End to inserted** | **1.07–1.68 s** |

Speed round 1 (2026-09-19) targets those fixed costs:

- **Insertion.**
  - The element-path paste now confirms on the first AX-visible change,
    polling every 15 ms up to 250 ms, and restores the clipboard immediately.
  - The application-level paste returns right after `⌘V` and restores the
    user's clipboard 0.5 s later, off the insertion path. It skips the restore
    if anything newer was copied. A quick second paste reuses the still-pending
    original snapshot.
  - Each insertion now logs only its method and a coarse target category.
- **Capture order.**
  - `DictationCaptureCoordinator` starts the microphone before creating the
    session, journal, and track rows. Chunks queue in the capture stream until
    the drain begins.
  - A microphone start failure no longer leaves an empty session. Regression
    tests cover early chunks surviving and no session on failure.
  - A new `start-to-first-audio` notice measures when audio actually arrives.
    `target-capture` isolates the async AX read.
- **Warm recognizer.**
  - The Qwen runtime runs a 0.3 s throwaway decode after load, which compiles
    GPU kernels (573 ms at the installed launch).
  - The same decode runs whenever dictation starts after more than 90 s idle,
    while the user is still speaking.

Verification: affected package suites 115 pass with 1 environment skip, and
hosted App tests 95 pass. The Release build is installed and running.

Installed results after round 1 (00:47–01:00, 1.9–13.6 s audio):

| Stage | Result |
|---|---|
| Insertion | 89–98 ms, all `clipboardPaste` to an application-level target |
| Qwen warm-up at start | 134–136 ms |
| End to inserted, ≤7.3 s audio | 0.70–1.20 s |
| End to inserted, 13.6 s audio | 1.75 s (decode 762, align 235, polish 507) |

The start-path breakdown showed three things:

- **Prechecks took 64–71 ms.** Almost all of it is the volume "important usage"
  capacity query.
- **The microphone itself is fast.** Prepare is 50–57 ms and engine start about
  30 ms.
- **Start to first audio is 280–298 ms,** down from 355–371 ms once the focused
  target read became immediate.

Round 2 changes:

- **Immediate target capture.** It falls back to the application target at
  once instead of a stabilized AX read (about 70 ms). Insertion still
  re-resolves a precise AX element when one exists.
- **Cached disk check.** Dictation start uses a disk-space decision refreshed in
  the background at launch and after each dictation, valid for 5 minutes. A
  cached hard stop is always re-checked.
- **Microphone timing.** The `mic-prepare`, `mic-engine-start`, and
  `start-prechecks` notices now isolate startup stages.

Verification: hosted App tests 95 pass. Installed at 01:04; the launch warm-up
took 236 ms.

Round 3 (2026-09-19): microphone-first start and closing the "hard" gaps.

- **Microphone-first start.** Dictation start begins `prestart` on a fresh
  capture before prechecks, panel, or focus work. The coordinator adopts it,
  and every other exit path cancels it without journaling anything.
  - Installed measurements, 01:26–01:30: the engine runs 135–240 ms after start
    was requested; first audio arrives in 236–331 ms.
  - The main actor is the bottleneck. The prestart task waits about 95 ms for
    it, and prechecks grew to 116–146 ms, which points at main-thread UI work
    at key press. This is not yet fixed.
- **Auto-copy on every uninserted outcome** (PRD V1.6 §0.1 item 10).
  `uninsertedClipboardText` covers retained and failed dictations, falling back
  to the live draft (labelled as a draft) when processing failed with no final
  text.
- **Globe-key conflict notice.** Settings and the idle status warn when Fn is
  the start key and `AppleFnUsageType` is not 0 ("Do Nothing"), and open the
  Keyboard pane. The App never changes the setting itself. The user's setting
  is still the default.
- **Long utterances.** Recordings over 30 s are decoded as a hard 30 s window
  plus the remainder (e.g. 30.0 s + 0.9 s), and end to inserted was 2.4–3.0 s
  for 31–36 s audio. The PRD now requires silence-based splitting.
- **Evaluation corpus identified.** The owner's prior local dictation history
  (about 9,700 completed dictations, about 46 h of audio with AI-edited
  reference text) is used on this Mac only; only aggregates are recorded.

Verification: hosted App tests 97 pass. The Release build is installed.

Round 4 (2026-09-19), as agreed with the user:

- **Capsule result actions.** An uninserted result shows a copy button next to
  the "已复制 · ⌘V 粘贴" line, and stays visible while hovered. Live subtitles
  now show by default, with a Settings toggle for "只在鼠标悬停时显示实时字幕".
- **Microphone at key press.** The global-shortcut preflight, which runs inside
  the event tap, starts the microphone on a detached task. The start command
  adopts it (`keypress-to-start` is logged); an unadopted one is discarded after
  3 s.
- **Pause-aligned inference windows.**
  - `PauseAlignedWindowing` ends a window at the first pause of at least 250 ms
    (below about -42 dBFS) past two thirds of the limit.
  - Without such a pause, it cuts at the quietest 50 ms inside the limit, and
    only when the limit would be exceeded.
  - Journal materialization moved to algorithm
    `pcm-to-16khz-mono-f32le-v3-pause-aligned-windows`, which carries the
    remainder into the next window.
  - Five unit tests pass, and the existing journal and bounded-adapter suites
    are unchanged (32 pass).
- **Evaluation harness.**
  - A private script (not published) draws a duration-stratified, seeded
    sample of 240 dictations (89 min) from that local history into a private
    evaluation directory outside Git and iCloud.
  - The `DictationEvalCLI` package executable runs the production text path:
    Qwen with alignment, phrases, and the joiner, then MLX polish with the
    protected-fact gate and the 0.8 s insertion rule. It is resumable and
    records failures per item.
  - `script/score_dictation_eval.py` prints only aggregates: distance from the
    Typeless text, punctuation per 100 characters, sentence stops per 100
    characters, and latency.
- **Storage location.** Private evaluation data lives under Application
  Support, outside Git.

Round 5 (2026-09-19): evaluation results and the main-window redesign.

- **Evaluation set corrected.** `typeless-v1` mixed translation and voice
  command records, whose Typeless text is a translation or an answer, not what
  was said. `typeless-v2` keeps only plain dictation records: 240 dictations, 85 min,
  seed 20260919. Typeless text is AI-edited, so it is a reference, not ground
  truth. A private script (not published) writes a local `review.html` where
  the user corrects 40 stratified items to what was actually said.
- **Baseline (Qwen final path, fixed 30 s windows), distance from Typeless:**
  11.1% under 5 s, 17.4% for 5–15 s, 24.9% for 15–30 s, 43.4% for 30–60 s,
  53.5% for 60–120 s. Beyond 30 s the gap is mostly Typeless removing
  repetitions and fillers: our text is 15–25% longer, character recall stays
  81–83% while precision falls to 65–72%, and 嗯/呃 survive only in ours.
- **Punctuation.** Every result ends with a stop; Typeless ends only about 40%
  of short ones with one. Commas are 25–50% denser than Typeless. The
  punctuation comes from Qwen itself: raw and final text score the same.
- **Pause-aligned windows** do not change accuracy (36.9% vs 36.7% overall).
  They stay because they avoid mid-word cuts.
- **Model polish is effectively a no-op on the insertion path.** Output was
  identical for 191 of 228 items, punctuation-only for 5, and the other 32
  changed a median of 0.9% of characters. It still costs 280–1,440 ms per
  installed dictation, median about 450 ms, capped by the 0.8 s budget.
- **Personal vocabulary as recognition context.**
  - A private script (not published) takes the 64 most common Latin-script
    terms from the 4,798 Typeless dictations outside the evaluation set.
  - Passing them as Qwen context (`DictationEvalCLI --context-terms`) raised
    English-term recall from 63% to 69%. It raised character recall under 5 s
    from 88.3% to 92.2%, and 30–60 s from 81.2% to 82.7%. English-term
    precision did not drop (no invented terms), and the one repetition failure
    disappeared.
  - Cost: about +120 ms per decode window (under 5 s: 332 → 448 ms), from
    prefilling the longer prompt.
- **Installed start timings** (15 dictations with the key-press microphone):
  start to first audio 207–253 ms (was 236–331), prechecks 50–77 ms (was
  116–146), key press to start 1–23 ms.
- **Main window redesigned** (Typeless-style):
  - Layout: a warm grey canvas, a borderless sidebar (首页 / 历史记录 / 词典,
    ⌘1–3; 设置 opens the Settings window), and one raised content panel. The
    title bar is hidden.
  - Home: shortcut guidance from the configured keys (Fn: hold to talk, tap for
    hands-free, Space to pause), words dictated, time saved against 45 words per
    minute of typing, speaking speed, current and longest streak, and an
    activity map that fills the card width. `dictationActivityRecords()` and the
    pure `DictationUsageSummary` supply these; CJK characters and Latin words
    each count as one word.
  - History: a day-grouped list. Rows show time, the source app's icon and up to
    three lines of text. Play, copy and more actions appear on hover, and audio
    plays from the list. Clicking a row opens the existing detail as a separate
    page with a back button; the nested three-pane library is gone.
  - Dictionary: a chip grid with hover actions.
  - The paused features (线下录音, 电脑内录, 文件导入, 人物, 事件) moved into a
    "更多" menu, so existing records stay reachable.

Verification: 3 new summary tests, the extended source-index test, the new
zero-budget polish test, and all 97 hosted App tests pass. Light and dark
fixture screenshots were checked. The XCUITest suite was rewritten for the new
navigation, with a new dictionary-chip test; it builds with `build-for-testing`
but has not been run, because UI automation needs the user's authorization.
The Release build is installed.

Next:

1. Done after the user agreed: model polish is off the insertion path
   (`polishInsertionBudget = .zero`). The rule-cleaned transcript is inserted
   immediately, and polish runs in the background, updating history only.
   `DictationEvalCLI --polish-budget-ms` reproduces either rule.
2. Import the personal vocabulary into the dictionary, then cache the context
   prefix so the +120 ms disappears.
3. Once the user's verified 40 items exist, tune the rule-based punctuation:
   no final stop on short single sentences, and fewer hesitation commas.
   Prove each change on the set.
4. Unblock the main actor at key press; decide on forced alignment for short
   utterances; decode while recording.

Round 6 (2026-09-19): verified truth, vocabulary, and fixes.

- **Verified transcripts.** The user corrected 40 stratified items (22
  changed) in `review.html`. Character error rate against them:
  - Current (pause-aligned) path: 4.1% overall and 11.6% under 5 s.
  - With the 64-term vocabulary: 3.5% overall and 6.6% under 5 s, and English
    terms 20/26 (was 17/26).
  - Model polish: 4.7%, worse than no polish.
  - Typeless: 22.4%, because it rewrites.
  - The user changed no punctuation, so these items cannot set a punctuation
    target.
- **Vocabulary imported** through the App's own CSV import (63 terms plus the
  existing entry). This exposed a real bug: Swift treats CRLF as one
  Character, so the CSV parser never saw a row break. Every CSV the App
  exported could not be re-imported. Fixed, with a round-trip test.
- **Silent dictations.** A stray Fn press records well under a second of
  silence and ends as `dictation-asr-no-speech-detected`. These no longer
  count toward Home's "恢复 N 条未完成记录". History shows "没有听到说话。"
  and keeps them retryable.
- **Globe key.** The user tried Modifier Keys → Globe → No Action, which
  removes the key at the system level, so no app can see Fn. The correct
  setting is Keyboard → "Press 🌐 key to" → Do Nothing; it is still "Change
  Input Source".
- **Installed timings after polish left the insertion path** (6 dictations):
  end to inserted 612–1,552 ms, median about 0.88 s.

- **Vocabulary pruned.** Dropping the 23 plain English words (those in the
  system word list) left 41 proper and technical terms.
  - Truth CER 3.20%, the best so far (64 terms: 3.83%, none: 4.12%).
  - English recall 68% (64 terms: 69%).
  - Decode under 5 s is 381 ms (64 terms: 410 ms, none: 333 ms).
  - The generic words were removed with the new dictionary multi-select
    delete. A shared prompt-prefix KV cache is not possible with public
    SDK interfaces, because audio features only merge into an empty cache.
- **Windows.** Pause-aligned windows now cut only past 30 s, at the longest
  late pause. Accuracy is within noise (truth 3.54% → 3.83%, 10 items in that
  bucket) with fewer windows (386 → 330) and faster long decodes (median
  1,101 → 1,004 ms).
- **Cleanup v2** (the user's choices): remove 嗯/呃 and the comma they leave,
  and drop the closing period on single-sentence dictations. The same rules
  apply to late polish kept in history.
- **Text-only punctuation rejected.** Measured against Typeless comma
  positions (220 items ≤ 60 s):
  - Re-punctuating with the sherpa-onnx CT-Transformer zh-en int8 (61 MB,
    evaluated in scratch only): F1 52, precision 55%, 3.8 ms median.
  - Qwen's own commas: F1 62, precision 63%.
  - Keeping only commas both agree on: precision 68%, but recall falls to 45%.
  - Not integrated. The next candidate is a pause-length rule from the
    aligned word timings.

- **Speculative final decode.**
  - Pause detection runs on the capture thread: at least 250 ms of speech
    (RMS ≥ 0.02), then 350 ms quiet (RMS < 0.0115). On a pause the capture
    flushes its partial chunk and reports how far audio has been published.
  - The runtime converts committed chunks to 16 kHz as they arrive
    (`CommittedInferenceAudio`). It then decodes and aligns them once the
    flushed audio is committed (`QwenASRRuntime.speculate`).
  - Final ASR reuses that text and those word timings only when the final
    window starts with exactly those samples, continues with nothing louder
    than RMS 0.02 per 50 ms, and uses the same dictionary terms. Anything
    else decodes normally. When speech resumes, the speculation is cancelled.
  - A journal test shows the live conversion equals the final materialization
    sample for sample, including uneven flush-sized chunks.
  - Limits: the first dictation after launch (the recognizer isn't loaded
    yet), dictations with a manual pause, and recordings over 30 s never
    speculate.
  - Logs: `qwen-speculate`, `qwen-speculative-hit`.

- **Model polish off by default** (user decision). On verified transcripts
  it was worse (4.7% vs 4.1%). Existing installs migrate once, and Settings
  can turn it back on. The 1.7B text model is now verified at launch but
  loaded only on first use.
- **Memory.** An MLX idle-buffer cap of 256 MB costs nothing (90-item decode
  median 425 vs 428 ms). MLX itself holds 3.6 GB active (ASR + aligner
  weights), with a 4.6 GB peak.
  - Right after launch the App's footprint is 9.3 GB: 3.8 GB GPU plus
    5.4 GB malloc, of which 2.5 GB is reclaimable. Speech models for live
    subtitles, fallback languages and speakers are all loaded at start.
  - Next: load fallback and speaker models on demand.
- **Diagnostics.** Content-free notices `speculation pause detected`,
  `speculation started`, `speculation skipped reason=…`,
  `speculation cancelled reason=speech-resumed`, and `speculation not
  reused`.

Verification: 489 package tests and 100 hosted App tests pass.

Round 7 (2026-09-19): recognizer bake-off and a feature bug.

- **Heavy work moved off the Mac.** Concurrent training, a bake-off and an
  uncapped eval run exhausted memory on the development Mac. Training and
  bulk transcription now run on a separate GPU server. On the Mac, one heavy
  job runs at a time, with `--cache-limit-mb` and `script/eval/memory_guard.sh`.
- **Recognizer bake-off** on the 240-item personal set (private scoring
  scripts, not published; aggregates only). Verified CER / under-5 s CER / English-term recall
  against Typeless:

  | Recognizer | CER | under 5 s | English terms |
  |---|---|---|---|
  | App Qwen3-ASR 8-bit, before the fix | 3.20% | 6.63% | 68% |
  | Reference Qwen3-ASR bf16 (PyTorch) | 2.57% | 4.42% | 77% |
  | Fun-ASR-Nano, no hotwords | 3.05% | 2.76% | 62% |
  | Fun-ASR-Nano, 41 hotwords | 5.43% | 12.71% | 71% |
  | SenseVoice | 4.55% | – | 54% |

  FireRedASR2-AED scored 1.87% on a 75-item subset where the app's Qwen scored
  4.48%. Its English is weak, so it was not pursued.
- **Qwen3-ASR feature bug fixed.** mlx-audio-swift's `preprocessAudio` builds
  HTK-scale mel filters, uses a symmetric Hann window and keeps the last
  frame. Qwen3-ASR was trained with Whisper features: Slaney scale, a
  periodic window, and the last frame dropped. The mismatch is about half a
  standard deviation per feature. `QwenWhisperFeatures` reproduces
  transformers' `WhisperFeatureExtractor` to within 2e-3, and a unit test
  checks this against reference values. Results on the same build, same
  flags, 240 items:
  - Old features reproduce the old numbers exactly: 3.20%, 6.63%, 68%.
  - New features: **2.71%** CER, **4.42%** under 5 s, **76%** English terms.
  - Decode median is unchanged: 939 vs 935 ms.

  The 8-bit weights are now within 0.14 points of bf16, so the weights stay.
  The forced aligner still uses the SDK features, which affects phrase
  timestamps only.
- **Cleanup model (in progress).** Qwen3 LoRA, trained on (ASR raw → Typeless
  final) pairs from the user's history.
  - The first pilot moved text toward Typeless (distance 36.3 → 28.0) but
    rewrote words: verified precision fell from 97.4% to 94.8%.
  - Training only on pairs where Typeless mostly deletes (≥ 95% of its
    characters come from the raw text) keeps most of the gain: distance
    29.1, precision 96.9%, 0.7% introduced characters.
  - A faithfulness guard returns the rule-cleaned text whenever the model
    adds more than 2% characters. With it, precision is 97.6%, above the raw
    text.

- **Personal cleanup model, integrated.** Qwen3-1.7B LoRA merged and converted
  to MLX 4-bit (934 MB), installed at
  `~/Library/Application Support/bestASR/personal-models/cleanup/current`. It
  is never bundled, downloaded or uploaded, and has no registry entry: the
  directory is the whole contract. `PersonalDictationCleanupAdapter` replaces
  the polish port when the model is present and Settings allows it.
  - `DictationCleanupGuard` rejects any output that introduces more than 1%
    new characters (digits exempt) or drops more than half the dictation.
  - Cleanup starts at each speech pause, so the text is usually ready at
    release; insertion waits at most 250 ms, and dictations under 25
    characters never wait. The model loads once per dictation start (0.9 s).
  - Measured on the 240-item set with the App's own recognizer output:
    distance to the user's final text 34.68 → 32.28 guarded, verified
    precision 98.01% (raw 97.87%), 183 of 240 model outputs accepted,
    generation 210–240 ms warm in Swift.

Verification: 507 package tests and 108 hosted App tests pass.

Current installed revision is `85346392987a2de211c8b3b643ff45d0ab23eb8e`.
The same retained two-voice system recording now completes manual re-recognition
with two speakers and two person associations through its persisted speaker job.
The 32 source chunks / 740,352 frames and all eight original session states and
revisions are unchanged. Installed playback advances, pause works, the 0:15
source/player durations agree, and navigating away clears the previous record's
feedback. Four exact owned recordings and their source audio were removed using
the production staged journal/database deletion APIs; four test-exclusive
identities were retired, with zero active orphaned embeddings from this run.
The original source choice and Home were restored, and the single signed App
was relaunched normally after denied-network testing. Details are in
`artifacts/evidence/installed-app/native-final-reprocessing-20260830.json`.
This closes this repair batch, not the remaining semantic/model-quality work
or the complete continuous PRD 24.6 acceptance journey.

Installed revision `7853026bde47` passes the real read-first rename/title and
compact A/B presentation checks. The same denied-network App completes a
two-voice dictation, room recording and QuickTime-only system recording through
the native Qwen final route; room and selected-App pause/resume hold the durable
journal unchanged while paused. The system recording currently yields only one
speaker cluster for two synthetic voices, so that speaker case remains open.
Another project's foreground test interrupted one room automation; the exact
owned recording was paused, then continued using scoped controls rather than
interacting with the other project. These are bounded product checks, not a
complete acceptance claim.

Revision `db2fdce55285` is now installed under the same development signing
identity, with networking denied during the bounded checks. Retained room and
selected-App sources display 0:22 and 0:15; room playback advances from 0:00 to
0:03, transcript navigation seeks to its source interval, and pause feedback
is correct. Installation rejected the initial ad-hoc package without replacing
the old App; the corrected package passed signature/revision validation.

The installed checks exposed missing duration metadata: production journals
retain playable source blocks but never populate the `audio_chunks` table used
by Library duration, filters and home totals. The current P0 repair connects
source-only metadata indexing at seal/recovery, backfills retained legacy
journals without changing source bytes or session revisions, and shares interval
union duration across the affected queries. Unknown duration must not satisfy
the short-recording filter. Stale detail feedback after playback also remains
in this repair batch. Its source-duration and playback repairs are now installed.

The same repair batch corrects a pinned Fluid clustering-unit mismatch. Its
documented Euclidean threshold 0.6 was interpreted by AHC as cosine similarity,
widening the distance to about 0.8944. Passing the equivalent cosine 0.82 keeps
the original synthetic file at two speakers and restores two speakers in the
captured source, without a forced speaker count. A separate 79,840-feature
CPU/GPU comparison shows negligible FBank differences and does not justify
changing that preprocessing policy. A 17.49-minute public AMI tuning pair also
improves from four/two speakers to four/four without supplying a speaker count.
The old evaluation's 1...4 bound forced an SDK four-cluster fallback, so the
evaluator now matches the App's unbounded final route. Its fixed-identity-
threshold release-corpus regression passes existing gates: speaker confusion
2.2136%, zero wrong identities and zero false merges, with DER 25.1138% and JER
34.0834% reported without concealment. This is reuse of the historical holdout,
not a new unseen selection. Ten affected package tests and one hosted App test
pass across the original run and failed-case-only reruns; the Debug test build,
static checks and privacy scan pass. Installed reprocessing exposed a further
missing link: manual re-recognition publishes only a new transcript and never
queues the speaker stage, leaving the old one-speaker result unchanged.
The candidate versions new speaker jobs without changing identity embeddings
or silently reprocessing existing user records.

Current P0 acceptance contract: a user-requested re-recognition must atomically
publish the new transcript and its resumable automatic speaker follow-up for
all four input modes. It must retain source bytes and old text, preserve
user-confirmed identity decisions rather than silently replacing them, and
report completed/pending/person-preserved outcomes honestly. Changing Library
records must clear the previous record's action feedback, and an asynchronous
completion must not write feedback onto a different selected record. This repair
is implemented and passes nine affected SQLite regressions and two hosted App
tests, plus static/privacy checks. The cases include all four modes, reopen,
idempotent publication, transaction rollback, concurrent newer text, explicit
source deletion, and person confirmation during inference. Its installed check
and owned-data cleanup now pass as recorded above. The full product gate is not
claimed.

The installed Library revision fixes the observed anonymous UUID label and
always-open title form. Library and Event people now use one paired ID/name
projection, preserving names containing commas and distinct people with the
same name; unnamed titles use the identity's creation time consistently across
surfaces. The derived search index is rebuilt without UUID keywords, without a
portable schema or source-data change. Transcript controls use short A/B/C
labels with explicit uncertainty. Rename is opt-in, reports progress, retains a
failed draft, and closes only after successful persistence for the same record.
Four affected SQLite tests, seven hosted App tests, the Debug test build, static
checks, and privacy checks pass. The new native title/layout assertions compile
but have not executed; the existing UI-runner authorization limitation is not
claimed as a pass. The bounded installed rename/reading checks are recorded above;
the complete continuous product journey remains open.

Native Qwen3 ForcedAligner now has bounded offline tuning measurements: 16 AMI
clips / 349 words plus a known one-second translation of six public Mandarin,
six public English and two synthetic mixed-language clips. AMI transcripts are
manual, but their word timings are automatically forced-aligned; the observed
30 ms median / 590 ms P95 boundary difference is not independent phonetic
accuracy. Its 22 zero-duration quantized words must not become playable rows.
The cross-language translation check compares 306 words: median / P95 deviation
is 40 ms, maximum 440 ms, with ten zero-duration predictions and one raw end
7.4375 ms beyond the mixed-language audio duration. These defects are reported,
not clamped into an evaluation pass. The first translation attempt omitted
22.05 kHz synthetic inputs and failed the corpus count; the corrected attempt
uses the same native conversion as ASR before inserting exactly one second of
silence. Original audio, prior results and release holdouts were not changed.
Content-free measurements are retained in `SPIKE-ASR-002/qwen3-forced-alignment-*`.
These results supported the bounded integration candidate described below,
not App or release completion.

The candidate now implements the native Qwen final-ASR/alignment route shared
by all four capture modes, actor-owned cancellable decoding, complete natural
phrases and source timestamps, exact-pinned component installation, and the
existing final route retained as a failure fallback. The prior signed `059e807f0c59`
was installed as the same single identity before `7853026bde47`. Under denied networking its
6.72-second public quiet-English import completes on native Qwen, retains
playable source audio, replays after natural completion, holds its paused
position, copies current text in 0.18 seconds without losing the prior clipboard,
and saves/searches a manually renamed title through actual keyboard input. This
is partial installed acceptance, not PRD 24.6 completion. An invalid shortcut
automation continued after its target activation failed and started recording
after fixture playback; that exact test was paused, removed with its source
audio through the production journal/store transaction without reading its
contents, and excluded from evidence. All nine other record states/revisions
(eight original records and the valid import) were preserved.
A real native cancel-and-reuse test passes with all networking denied,
and 48 affected hosted App tests pass. XCTest initially could not find the Metal
resource; its corrected test-only resource link follows Cmlx's actual bundle
lookup instead of weakening the production resource check.

The first 64-clip production-runtime run exposed an integration regression:
the inherited absolute RMS/peak activity gate discarded 15 quiet real English
clips before recognition. It now skips only all-zero digital silence and gives
nonzero audio to the model without changing amplitude or splitting context.
All 15 affected speech clips recover in a targeted rerun; both non-speech
controls remain empty. Combined with the 47 unchanged successful outputs, the
62 speech clips have 92 playable phrases and no empty/out-of-source intervals.
English sentence spacing now follows one shared rule in recognition,
evaluation and persisted segment corrections. The three phrase-boundary and
three quiet/silent-input/timed-edit regressions pass. Composite quality matches
the earlier public-human model comparison (English 19/458 word errors;
Mandarin 69/883 supplementary content-character errors). This is not a repeated
full timing run or a release gate pass: the initial failed run is retained,
the targeted run lacks full tag coverage, and existing date-surface/combined
WER/RSS limits remain explicit in `qwen3-native-final-integration.json`.

The native Qwen3-ASR 1.7B 8bit challenger now has a real 64-sample offline
comparison on the same pinned corpus. On the 24 public English samples its WER
is 4.15%, versus Parakeet 7.64% and Whisper 8.30%. On the 24 public Mandarin
samples, raw CER is 16.16% (Paraformer 10.73%), but the identically normalized
content CER is 7.81% (Paraformer 10.42%) and mixed-unit error rate is 4.90%
(Paraformer 7.65%); punctuation/numeral rendering makes these distinct measures,
not interchangeable gate results. Both synthetic mixed-language samples preserve
all content after the same normalization, and both non-speech inputs stay empty.
The one strict dangerous-token flag is an unchanged date written as “two thousand
and twenty-six”, which the frozen surface-form fixture omits; this explicit
review does not rewrite the original failed gate. The combined WER/RSS gates
also remain failed. Warm per-file P95 is 1.154 seconds, RTF 0.0816, peak RSS
5.125 GB on this 48 GB host; no minimum-memory eligibility is claimed.

At that comparison stage Qwen was not selected for the App. The native candidate
above now addresses production alignment, cancellation, source-range provenance
and shared job integration; installed acceptance remains a prerequisite. The
exact MIT native SDK preserves the existing MLX/Transformers pins and macOS 14.2
minimum. Its tokenizer is built in memory so verified model
files remain immutable. The launcher `script/run_qwen_asr_tuning_evaluation.sh`
reuses the external native build's MLX Metal resource bundle; missing resources
now fail with a safe diagnostic instead of aborting. The real pilot and full
run use a parent deny-all-network sandbox. Content-free results are in
`artifacts/evidence/SPIKE-ASR-002/qwen3-asr-1.7b-*`; raw diagnostics and all model
files stay external. The installed App and the user's original records are
unchanged by this comparison.

The developer-only high-quality Whisper comparison is now measured rather than
inferred from the old tiny-model smoke. Pinned WhisperKit 1.0.0 with the 626 MB
large-v3-turbo model ran the same 64 public/synthetic samples with all networking
denied. Its full run still failed: four prompted speech samples returned empty,
both non-speech samples hallucinated text, and 17 dangerous-token checks failed.
A four-case no-prompt ablation restored speech but did not clear all fact checks;
disabling the SDK's first-token early-exit heuristic did not repair prompting and
was reverted. On the same 24 public English samples, Whisper WER was 8.30%
versus the current Parakeet's 7.64%. Mandarin raw/content/MER scores differ with
punctuation and number rendering; the preserved comparison reports all counts
and does not silently substitute a more favorable normalization. Whisper is not
selected for the App. The existing installed model route, source audio, and user
data are unchanged. Content-free results and the corrected FP32/GPU Paraformer
baseline are retained under `artifacts/evidence/SPIKE-ASR-002/`; raw diagnostics
and model files remain on the external volume. These are tuning results, not
release-holdout or full-product acceptance.

## Current delivery state

The current signed Release candidate is installed at
`~/Applications/bestASR.app` as the single `com.bestasr.app`
identity, with its exact Git revision embedded in the bundle and the preceding
signed bundle retained as a non-registerable rollback on the external build
volume. The currently installed revision is `059e807f0c59`; its Release package
contains 61 registered files, passes strict nested-signature validation, and is
signed with the stable Apple Development identity. The preceding installed
revision `d18ce553b7f8` cold-started both pinned final-ASR runtimes in parallel
after the capture path was ready: English was prepared in 3.685 seconds and
Mandarin in 3.718 seconds without blocking launch. A real focus-independent
global-shortcut Mandarin dictation then completed 3.544 seconds after End,
replaced the external App selection exactly once, opened its retained 42-second
source in Library, advanced playback from 0:00 to 0:16, and held the paused
position.

Installed revision `092f0b6da366` then completed a production room-recording
journey with two synthetic microphone voices: live speaker A/B evidence was
visible, pause excluded speech produced inside the paused interval, resume
continued the same durable recording, and End produced a playable 2:15 retained
source. That run exposed an ordering defect in which a higher-numbered live
draft could hide an older-numbered completed final revision. The installed
fix displays all four final timestamped segments instead of the last live
sentence, preserves inline segment editing, advances playback, freezes on
pause, and starts playback from the selected `0:47` evidence segment. Fresh
final processing now allocates after every persisted live input revision while
recovery preserves the original final revision. History, export, local
organization, reprocessing, and transcript edits all select the newest terminal
revision rather than a numerically higher live draft. Both synthetic acceptance
records and their audio were deleted through the production confirmation flow,
and the original database returned to 8 sessions with `quick_check=ok` and no
foreign-key violations. These results close the observed minute-scale first-End
stall, retained-audio playback regression, and live-draft/final selection defect
for these installed paths; they do not by themselves close all of PRD 24.6.

Installed import acceptance exposed a separate real-model failure on a
12.5-second two-voice synthetic Mandarin file. Preserving language tags in
`8b1f28adabe4` and retaining full context in `9d7f367acbf2` did not close it:
the installed result was still wrong, and the specialized Mandarin runtime also
returned empty or unstable text. Further isolation proved that file loading and
resampling produce identical samples. The pinned CPU-only Core ML preprocessor
changes thousands of already-observed feature values when just 20 ms is appended
to the same source; the FP32 CPU/GPU configuration preserves the common prefix.
The current candidate therefore fixes the shared SenseVoice/Paraformer local
model-loading policy, keeps quantized inference on ANE, and restores phrase
boundaries instead of hiding the defect with whole-recording context or
fixture-specific language heuristics. Existing language tags and independent
manual re-recognition remain. The real-model language, phrase-boundary,
preprocessing-prefix, strided-CTC, and Mandarin CER regressions now pass.
Installed revision `efd9cad75b0d` re-recognized the retained synthetic import as
two Mandarin segments in 1.036 seconds through the production UI. Continuous
playback, correction, copy, and source export were subsequently exercised on the
installed candidates below; the previous CPU-preprocessing tuning results
cannot validate the changed path.
An affected 32-sample Mandarin rerun with all networking denied now passes the
unchanged corpus gate at 9.17% CER, zero dangerous-token errors, and 434 ms P95
(previous CPU path: 14.96% CER). SenseVoice's combined rerun still fails overall
quality and remains live/mixed evidence, not the universal final model. The
synthetic import itself has ordinary lexical errors (14.29% unpunctuated CER),
which are recorded rather than represented as a perfect transcript. CTC decoding
also reads native Float16/Float32 rows with their actual strides, avoiding the
per-token object-allocation bottleneck seen in the live process sample.

That installed journey exposed three additional product defects: Copy could
resurrect an old snapshot's polish after re-recognition invalidated the derived
revision; the automatic title and open title field stayed stale; and Play after
natural completion reused an exhausted audio node. The candidate now binds
polish to the current source revision, updates automatic titles without replacing
manual names or unsaved drafts, and resets the node at natural completion.
Source audio and old transcript/polish evidence remain unchanged. All five
affected persistence/player/title regressions pass. Installed `fd9d8aebfb4f`
copies the current Mandarin result, updates the open automatic title after
re-recognition, replays from the start after natural completion, jumps to the
second segment, and saves two inline corrections as immutable child revisions.
Its TXT/SRT/VTT/Markdown/JSON exports contain the corrected current text and its
source-audio export is byte-for-byte identical to the imported WAV.
Export inspection exposed two remaining defects: midpoint-based attribution
lost speaker A when a sentence midpoint fell in a pause, and Markdown labeled
user corrections as original recognition. The candidate now shares speech-
coverage attribution and confidence-aware names between UI and export, leaves
ambiguous multi-speaker segments unassigned, and traces edits through their
parent chain for the original-ASR disclosure/restoration and Markdown section.
Version restoration also now creates a new immutable child carrying the selected
version's exact segments, timestamps, language, and audio ranges, instead of
silently converting it to untimed whole-text editing. A stale current-revision
guard prevents an intervening correction from being overwritten.
The extended persistence regression and all four hosted attribution/provenance/
export regressions pass. The added native UI assertion did not execute: XCTest
timed out waiting for macOS Touch ID authorization to enable UI automation. The
test-owned authorization prompt was cancelled; this run is not recorded as a
passing UI gate. Installed `9162590c5451` subsequently restored the original
ASR and then the corrected version through the visible Library controls. Each
restoration created a new revision with both source segments and all 25 audio
ranges intact. Its affected Markdown/SRT/VTT exports preserve both speaker
attributions, and Markdown separates the corrected current text from original
recognition. The synthetic WAV source remains byte-for-byte unchanged.

That same installed identity, with all process networking denied, imported a
second synthetic M4A through Finder Open With, completed local recognition, and
played its retained source to natural completion. Its two speakers matched the
two synthetic-only people as reviewable candidates and were confirmed beside
their audio evidence. A manually created event linked exactly the two test
records, generated a local Qwen summary, and returned from its chronological
timeline to the correct source record. These are two generated acceptance
records in addition to the original 8 user records; their cleanup remains part
of the unfinished continuous journey.

This run exposed real remaining interaction and provenance defects: Finder Open
With opened a duplicate main window; the standalone file chooser could appear
on a different display; an old automatic title was included as if it were
spoken event evidence; event discovery could read a higher-numbered live draft;
and event document identity omitted the underlying transcript versions. The
current source candidate reuses the existing workspace, attaches file selection
as a sheet, separates source metadata from spoken text, excludes automatic
titles from model evidence, and selects current terminal transcripts. Event
documents now include source versions and speaker context in their identity,
reject stale in-flight results, and retain older results unchanged. Whole-text
correction invalidates event summaries, and correction/restoration refreshes
automatic titles without changing manual titles. Five affected package tests,
three hosted App tests, static analysis, and the privacy scan pass. The new
native window/sheet assertions have not executed because of the macOS UI-test
authorization boundary described above. Installed verification of this source
candidate, People/Event merge-split-undo, and test-data cleanup were then
continued as described below.

Installed `e6258fc3e4138`, still under a deny-all-network process sandbox,
regenerated the two-record event summary from the current corrected sources
without treating the old automatic title as speech. A source link returned to
the correct 12-second original and its timestamp. A further inline correction
made both earlier event documents stale; regeneration created a distinct current
document referencing source revision 13, while earlier results remained intact.
The automatic Library title also reflected that correction. The two synthetic
people merged into 10 appearances and undo restored the original 4/6 split;
splitting one selected occurrence created a third person with one appearance,
and undo retired that test identity and restored the source association. The
two-record event was split, merged, undone, and one record was moved between the
two test events through visible controls. Remaining move/remove undo and cleanup
are unfinished, not implied by the earlier successful operations.

The installed review also exposed oversized review queues, duplicated generated
text, ordinary list refresh hiding completion feedback, and unrelated short
records being suggested for an event on weak embedding/title evidence. The
current uninstalled source candidate collapses and bounds both review queues,
makes document cards read-first with explicit editing, removes only exact body/
structured-item repetition, and keeps action completion feedback. Event
discovery now requires corroborating topic terms in source content rather than
accepting a similar event title or generic acknowledgment. The affected
persistence test and 11 hosted App tests now pass: these include real temporary
SQLite create/rename/merge/undo feedback and seven event-organizer cases. The
changed native UI assertions and installed interaction rerun are still open.

Installed `01b0c200b8221` completed the remaining event move/remove undo and
restored the original two-source event; all 10 recordings remained retained.
Completion feedback now persists after each operation. The conservative source
policy produced no pending suggestions for the previously noisy test event.
File selection attached correctly when the workspace had keyboard focus, but
an inactive-workspace call still fell back to a standalone panel. The next
source candidate resolves the visible non-panel workspace when key/main is nil;
its two focused window-policy regressions now pass; installed background-trigger
verification remains pending. The owned chooser was cancelled, not left open.

The subsequent complete check passed bootstrap, static checks, foundation
fixtures, 416 package tests (3 skipped, 0 failures), package integration probes,
and Debug/Release builds. Its 81 hosted App tests exposed one obsolete test that
expected an immediate second explicit dictation toggle to be ignored. That
expectation contradicts DICT-002 and the preparation-command contract: the
second toggle must end the same session after preparation. The affected test
now passes with one end marker, one retained record, and the exact completion
handoff (0.063 seconds). The other 80 hosted App tests and both workspace smoke
tests passed in the full run and were not repeated. Privacy and all remaining
artifact/check stages pass. The separate native UI run did not execute a test:
its runner timed out enabling macOS automation mode. This is an unexecuted UI
gate, not a passing full check or a substitute for installed-App acceptance.

The check initially stopped at the external-volume 25 GiB reserve. Cleanup
removed 65 already-trashed generated App bundles, one unused nested SwiftPM
scratch tree, two byte-identical download copies of retained installed models,
and the regenerable Xcode module cache. Available external space rose from
about 11 GiB to 27 GiB before the resumed build. Source/Git, local installed
models, all user audio/history, current installed App, and recent signed
rollback bundles were preserved; other projects and test evidence were not
deleted.

Installed `2d6f7e4f5e76` passes the background Finder chooser/sheet and single-
window Open With checks. It also generates an offline summary from current
revision 13, presents it without an editor, exposes editing explicitly, saves
an edited note as a new document while preserving the previous version, and
finds that note through Library search. Its real Library screenshot exposed
another usability defect: the large repeated heading and separate filter rows
left only 175 points for the reading pane. The next view candidate compacts
that header, gives more width to the reader, and collapses contextual filters
after applying them. The changed view and expanded native layout regression
compile in `build-for-testing`, and targeted formatting checks pass. Native
automation remains unavailable, so the installed layout rerun is still pending;
all source data and the fixed playback controls are unchanged.

Installed `c06063e535b4` increases the real Library transcript and notes reading
height from 175 to 323.5 points while keeping the source player visible. A
separate owned room recording was forcibly terminated only after its journal
contained committed audio. Restart replayed all 340 chunks / 170 seconds with
zero recovery issues and made that retained source playable. This exposed an
interaction defect: the interrupted record still said processing and was
excluded from the recoverable filter. The new candidate distinguishes waiting
recovery from current-process work, exposes recovery directly in the detail
header, blocks deletion during recovery, and reloads the open detail on success.
All three affected hosted regressions pass. Installed `f04471d16a87` displays
the interrupted source as recoverable, includes it in that filter, and exposes
the direct action. The follow-up keeps the selected result visible when it
leaves a recovery-only filter after completion. Installed `8c2cbc232bb8` then
recovered that same retained recording through the visible action with all
networking denied. Its final revision references all 340 source ranges, the
snapshot is marked recovered, and the selected detail remains visible after
leaving the recoverable filter. Its synthetic speech segment played from 0:33
to 0:35 and held its position after Pause. All three owned acceptance recordings
and their retained audio were subsequently deleted through the production
journal/store deletion transaction. Four active test-only people (including
two anonymous identities created by recovery) and one test-only event were
retired; none had links to user records. The original eight record IDs and
states are unchanged, SQLite and foreign keys are valid, and the normally
launched production App has one workspace window and no additional bestASR
process. Synthetic import inputs and exports remain on the external volume;
the test room recording itself was removed, not retained as a hidden copy.

The same installed `8c2cbc232bb8`, again denied all networking, subsequently
imported MP3, ADTS AAC, FLAC, MP4, and MOV versions of the owned synthetic speech.
Both movie fixtures contain real H.264 video and AAC audio tracks. Each format
produced two final timestamped segments, loaded its retained 12-second source,
played from the second segment, and paused successfully. MOV original export
was byte-for-byte identical, retaining both tracks. On this single 49-character
synthetic reference the final ASR made 6–8 character errors across encodings;
format/interaction success is not represented as perfect recognition or model
release acceptance. All five temporary App records and their audio were then
removed through the production deletion transaction; the one newly created,
test-only person was retired and the preexisting shared person was untouched.
The original eight record IDs/states and all preexisting person retirement
states are unchanged. The normal installed App is reopened; these synthetic
format inputs and the MOV export remain outside the repository on BestASRBuild.

The candidate replaces the engineering-shaped shell with a task-oriented Today /
Library / People / Events product, a shared capture workspace, staged first
launch, browse-first memory surfaces, fixed Library playback, explicit
destructive confirmation, progressive Settings, and standard Command-1 through
Command-5 workspace navigation. Library search Return opens the first matching
record instead of leaving keyboard users stranded in the search field. When a
record with retained audio is being browsed, Space toggles playback and
Command-Left / Command-Right move by 15 seconds; search, title, transcript,
speaker, and derived-text editors keep those keys for normal text editing.
Search results show the matching transcript context instead of the start of the
record. Clicking a transcript segment locates its retained audio without
inventing playback, while clicking its timestamp plays from that evidence; a
waveform, slider, or keyboard seek scrolls the transcript back to the current
segment. People appearances are grouped by source recording, and People and
Events entries return to the same source-audio/transcript evidence instead of
ending at a disconnected metadata card.
An active dictation, room recording, computer recording, or import stays visible
in the sidebar while the user browses Library, People, or Events, and returns to
one shared workspace without interrupting capture. Once audio capture closes,
that workspace explicitly changes from recording controls to local processing
stages and then to a persistent complete or needs-attention handoff. Completion
does not force navigation away from the current task; the handoff opens the
exact source record or can be dismissed to start the next capture, including
from the menu-bar surface. First launch now uses a single three-step permission,
offline-model, and real-dictation journey. Permission and model preparation can
each be deferred and resumed without hiding dictation, room recording, computer
recording, or import. Permission actions distinguish a first request from a
denial or revocation and retain that distinction across relaunches; the current
installed App identity is shown when macOS lists multiple copies. Microphone
setup includes device selection and a live local-only level check. Missing
models remain recoverable after the first retained recording, unavailable
runtime does not expose an impossible practice editor, and internal insertion
evidence cannot complete practice unless the visible editor actually changed.
Timestamped transcript segments can be corrected inline as immutable child
revisions while retaining their audio ranges, speaker evidence, and source text,
and the editor remains open with its draft intact unless persistence succeeds.
Speaker corrections are available beside the affected segment: candidates can
be confirmed or rejected with contextual feedback and immediate undo. Rejected
candidates retain provenance evidence but no longer pollute active person
labels, appearances, or person-name History search.
Global memory search also treats person UUIDs strictly as provenance rather
than user-visible keywords, so ordinary numeric queries no longer surface
unrelated anonymous identities. Empty anonymous profiles are excluded from
memory results, People, filters, and matching menus without deleting retained
provenance; retained unnamed voice identities use a local date/time label
and show their voiceprint count so several unknown people remain distinguishable
before the user names them.
People now exposes one global pending-review queue instead of making the user
discover uncertain matches recording by recording. Each candidate opens the
exact retained source and automatically plays its representative evidence
segment before confirmation or rejection. Decisions refresh both the source
and global queue, and immediate undo restores the candidate and its evidence.
Event discovery no longer creates one noisy “new event” suggestion for every
unassigned recording. A new event is proposed only for a semantic cluster of
at least two recordings with corroborating time, person, or source evidence;
isolated recordings remain searchable without becoming review chores. Event
candidates use a short deterministic local topic label instead of promoting a
spoken transcript sentence into the event name. The review card presents that
event label as the primary object, keeps the source excerpt as secondary
evidence, and avoids repeating the same transcript as both source and
destination. Candidates cannot be confirmed from a summary card: each one
opens the most relevant retained transcript segment and automatically plays
its exact source-audio evidence before confirmation or dismissal. Decisions are made
beside that evidence, confirmed sources appear in a chronological event
timeline, and immediate undo restores a dismissed or confirmed candidate.

An earlier candidate compiled and passed twenty-two native UI journeys across
its full interaction run and focused affected reruns. This is not a fresh pass
of the changed window/sheet assertions above. The focused audio tests exercise
rendered-time playback, pause, seek, replay, two retained PCM formats, and
primary-track selection. A native Library journey now opens a retained 32-second
local PCM source through the production player, verifies waveform loading,
play/pause, frozen paused position, both 15-second seeks, and transcript-to-audio
jump playback, then corrects a timestamped segment without losing the 32-second
source, confirms its candidate person, and undoes that correction. A focused
playback-keyboard regression and the affected native UI journey pass without
bypassing SwiftUI text focus. The App
suite covers copy, shortcuts, capture
durability, degraded runtime, model setup, History, local organization, and the
new UI behavior. The signed installed shell reads the existing local component
state and 8-record user database without migration failure, replacement, or a
new diagnostic crash report. These results close the prior fixture-level
interaction failures but do not by themselves close all of PRD 24.6.

The project must not yet be described as passing the complete repository gate.
The affected package and hosted regressions pass, but the current native UI gate
is unexecuted because macOS requires UI-test authorization. The remaining live-
conferencing, minimum-device, and Apple distribution gates below are unchanged.
Per current product priority, minimum-device optimization and distribution work
stay behind completing normal App functions and interactions.

The V1.4 event-memory baseline is implemented locally: stable events organize
records by semantic evidence, people, time, and source; conservative suggestions
remain reviewable; manual create, rename, merge, split, move, rejection, retire,
and undo operations preserve source records and provenance.

OpenSpec is not part of the delivery workflow. Product scope comes from the PRD,
current reality comes from this ledger, and implementation decisions come from
the technical design and ADRs.

## V1.5 product acceptance reset

- [x] First launch, permissions, microphone input verification, model preparation, and a real practice dictation form one understandable, skippable, resumable flow. The journey remains present until its real practice succeeds, even if a failed, recoverable, or ordinary recording has already made History non-empty; deferral retains a visible resume path instead of silently converting an incomplete setup into a normal post-onboarding screen. Signed installed revision `e252e4bcf38d` preserved the user's existing microphone and Accessibility decisions, exposed the exact focused `bestASR.onboarding.practiceEditor`, accepted a real focus-independent global shortcut, captured synthetic microphone speech through the production session pipeline, completed recognition, inserted exactly once into that editor, persisted the practice-completed marker, dismissed the journey, and returned to the normal home surface. Every other bestASR search/editor target remains fail-closed: the sole exception is the focused, nonsecure, editable practice editor after its exact Accessibility identifier is revalidated. Both acceptance recordings were then removed through the production deletion flow, restoring the database to its original 8 sessions with `quick_check=ok`, no foreign-key violations, and no test asset directories.
- [x] The menu bar and non-activating dictation surface complete focus-independent start/pause/end/cancel/insertion without freezing, stealing focus, or writing twice. Installed revision `60cb5c748e4a` passed the real session-event-tap lifecycle with Finder continuously frontmost: global start entered microphone preparation, the independent shortcut paused and resumed the same session, and Esc cancelled both immediately after the visible preparation boundary and after resume. Cancellation returned the production database to its original 8 sessions with `quick_check=ok`, created no diagnostic crash, and left the installed process healthy. The candidate also removes time-window suppression of a real second press, keeps AX stabilization outside the event-tap callback, recovers a disabled tap without a stuck key latch, queues end/pause/cancel received during preparation, and keeps final/fail-closed destination feedback copyable.
- [x] Installed revision `d18ce553b7f8` removes the first-use final-ASR cliff without delaying capture: the pinned English and Mandarin engines prewarm concurrently after ordinary component discovery, concurrent prewarm/end requests share one in-flight runtime factory, and a failure remains retryable on demand. A cold installed launch prepared both engines in under 3.8 seconds; a real synthetic Mandarin microphone sentence then completed and inserted exactly once 3.544 seconds after End. Its retained source played and paused through the production Library, and all generated data and the temporary external target were removed afterward.
- [x] Dictation, room recording, system audio, and import enter one consistent live/processing/complete workspace instead of separate form-shaped feature pages. Closing capture removes recording controls, exposes honest local processing stages, keeps completion visible in the originating workspace, and opens the exact retained source record on request. Room and system capture publish preparation synchronously so end, pause, and cancel remain actionable while permissions and devices are opening; the latest same-mode command is deferred across that startup boundary instead of being silently suppressed, and the global cancel command routes to the actually active mode.
- [x] Library detail keeps playback available, synchronizes audio and transcript in both directions, and supports inline transcript/speaker correction without exposing the revision system as the main task. Transcript edits retain their draft until a successful save, candidate people can be confirmed or rejected in context, and person edits expose immediate feedback and undo.
- [x] People and Events operate as browsable, reviewable local memory with contextual correction, undo, and source navigation rather than CRUD-first management. Pending person and event candidates both require retained-audio evidence review before a decision; source records remain unchanged, and the global queues and chronological event timeline refresh after confirmation, dismissal, and undo.
- [ ] Streaming, final ASR, alignment, diarization/identity, semantic retrieval, and local-text backends are selected per stage on one versioned realistic local corpus; existing alpha selections do not count as release defaults.
  - Final ASR now has realistic public tuning evidence and a product implementation candidate: SenseVoice failed the combined FLEURS profile, Paraformer with the corrected FP32 CPU/GPU preprocessor passed the Mandarin profile at 9.17% CER (the old CPU-only path was 14.96%), and Parakeet Unified passed the English profile at 7.80% WER, all with zero dangerous-token errors. The App automatically keeps SenseVoice for live/mixed evidence and routes clearly Mandarin/English final recomputation to the corresponding exact-pinned local model without exposing model or language choices. This does not check the parent item: the corpus is tuning rather than an independent release holdout, and alignment, streaming churn, semantic retrieval, and local-text stage decisions have not all passed the same realistic contract.
- [ ] One installed identity continuously passes PRD 24.6, leaves no test windows or records behind, and remains fully usable with network denied after model preparation.

Until every item above passes, implementation checkboxes below mean only that
backing capability is present in the candidate. They must not be quoted as
product completion or a usable-product percentage.

## P0 implementation present in the candidate

- [x] Native Chinese macOS product shell with task-oriented Today, Library, People, Events, Dictionary, permissions, recording controls, storage, and progressive Settings. The twenty-two-flow native UI suite executes on the current host and covers launch, deferrable non-blocking setup, capture lifecycle, honest processing/completion handoff, distinct menu-bar completion actions, active menu-bar pause/resume and confirmed cancellation, no-focus completion, Library copy/recovery, retained-audio playback, inline correction and evidence return, evidence-first People and Event review, guided setup, mouse and keyboard primary navigation, room and computer-output level previews, and import. Deleting the record referenced by a completed/needs-attention handoff also clears that handoff so Today immediately restores its capture entry points instead of retaining a dead “open record” action.
- [x] Focus-independent configurable global dictation and pause/resume shortcuts, unsafe-shortcut migration, menu-bar controls, start/end, pause/resume, cancel, live copy, and fail-closed target revalidation.
- [x] Durable built-in-microphone dictation with incremental audio journaling, live/settled/final transcript revisions, sentence replacement, local polish with a safe fallback, cross-session recovery, and exactly-once insertion.
- [x] Capture remains durable when ASR or polish models are absent or restarting; source audio and a recoverable History record survive for later processing.
- [x] One shared multi-speaker pipeline across dictation, room recording, system audio, and imported media, including diarization, embeddings, global person matching, unknown speakers, naming, merge/split/undo, and retained provenance.
- [x] Room recording with input-device selection, level preview, durable long capture, pause/resume, live transcript, final recomputation, playback, and speaker correction.
- [x] System-audio recording with App/helper discovery, selected-App or whole-Mac selection, optional microphone separation, Process Tap lifecycle handling, and source metadata/provenance.
- [x] Local audio/video import and decoding for the required formats, with resumable durable processing, understandable failures, and the same ASR/person pipeline as live capture. A pause pressed during inspection/preparation is retained and applied before decoding begins; decode pause/resume uses the same durable session and journal timeline, and resume commits its timeline marker before releasing the decoder gate. Once source audio is sealed, the UI removes the no-longer-valid pause/discard promise and offers an honest stop-and-retain path that leaves the recoverable record, original file copy, extracted audio, and progress in Library. Resuming an existing Library import is always non-destructive: stopping recovery retains the pre-existing record and source evidence even before a new seal boundary. Every retained interruption—including model/runtime errors that wrap cancellation—immediately registers the active snapshot as recoverable, so retry and confirmed deletion do not require an App restart. The stop action now registers this recovery state before cancelling the task and rechecks cancellation after the runtime returns, covering runtimes that finish an in-flight call without throwing `CancellationError`. The active import container no longer overwrites the identifiers of its pause and stop controls in the macOS accessibility tree.
- [x] Full local History with search/filtering, details, waveform and timeline navigation, permanent retained-source playback across 44.1 kHz Float32 mono and 48 kHz Int16 stereo tracks, raw/final comparison, speaker/person/event associations, retry/reprocess, nonblocking copy, atomic explicit deletion, export, and storage accounting.
- [x] Local event memory with stable events, event/session/person relations, conservative local candidates, create/rename/merge/split/move/reject/retire/undo operations, Events UI, search/filtering, provenance-linked organization, and archive coverage.
- [x] Local chapters, summary, decisions, and tasks retain timestamp links and source transcript provenance.
- [x] TXT, Markdown, SRT, VTT, JSON, and retained source-audio export, plus authenticated encrypted `.bestasrarchive` backup/restore using a portable user secret.
- [x] Dictionary add/edit/search/disable/delete, CSV/JSON transfer, add-from-correction, structured standard-to-spoken mappings in streaming/final/history ASR, and standard terms in local polish/fact protection. Add/edit keeps the draft visible until the asynchronous local write succeeds, retains it on failure, and exposes persistent feedback plus uniquely identified row actions for assistive technology and reliable interaction.
- [x] Atomic model installation, digest/size verification, license records, last-known-good retention, update, rollback, and clean-machine setup states.
- [x] Sleep/wake, device/source changes, permission loss, target drift, disk pressure, inference failure, and interrupted-session recovery paths preserve recording durability and fail closed where required.
- [x] SwiftPM scratch/build, Xcode DerivedData/SourcePackages, shared dependency caches, model-download cache, and runtime cache use one fail-closed root under `/Volumes/BestASRBuild/bestASR`; source, Git, installed models, user data, and active recordings remain local.

## P1 implementation present in the candidate

- [x] Push-to-talk behavior and independently configurable shortcuts.
- [x] Per-App formatting and polish policies.
- [x] Optional meeting-source metadata adapters that do not block base capture.
- [x] Additional locally decodable import formats with provenance.
- [x] Dictionary CSV/JSON import/export and add-from-correction.
- [x] Portable encrypted backup/restore flow.

## Automated validation already passed

- [x] The latest full Swift package run has 413 passing tests, 3 explicitly skipped installed-model fixture tests, and no failures (416 total); all package-owned deterministic probes pass. Those optional fixture tests do not replace the separately recorded real-model/installed-path evidence.
- [x] Full Debug `build-for-testing` with build output on the external build root.
- [x] All 81 hosted `BestASRAppTests` pass across the current full run and the corrected immediate-second-toggle rerun. Hosted coverage includes playback, permission state, hotkeys, capture durability, recovery, local organization, model setup, History, source filtering and context snippets, source location, copy responsiveness, degraded-runtime behavior, and exact post-capture handoff navigation. The two new inactive/closed import-parent window tests also pass.
- [ ] Execute the current `BestASRUITests` suite: the latest runner timed out enabling macOS automation mode before any test executed. A preceding twenty-two-journey run and affected reruns passed keyboard navigation, deferrable setup and real-practice validation, capture/processing/completion handoff, menu-bar controls, waveform playback/pause/seeking, source-linked inline correction, microphone/system level previews, person/event evidence review and undo, all six Settings categories, and retained dictionary drafts after a failed save. That historical result does not validate the newer chooser-parent, collapsed review queue, or read-first document assertions; their current native automation gate remains open alongside the separately recorded installed-App checks.
- [x] The supported main-window minimum is 1140 points, the smallest installed-App width where the nested Library sidebar/list/detail workspace keeps its leading navigation and trailing refresh/filter actions fully visible. A UI regression compares those controls with the actual window frame so a future intrinsic-size change cannot silently reintroduce edge clipping.
- [x] Workspace smoke tests for telemetry-off-by-default and the frozen platform contract.
- [x] Built permission descriptions, entitlements, App signature, and inference-XPC signature validation.
- [x] Privacy scan, permission/static lint, generated-project drift check, and shell pipeline tests.
- [x] App and UI test hosts are non-parallel so validation no longer creates a screenful of duplicate App instances.
- [x] The targeted parented-transcript explicit-deletion regression passes, and the production staging/rollback path removed all 30 confirmed automated test sessions and their 30 audio directories with SQLite integrity and foreign keys intact.
- [x] ASR and speaker inference derivatives now use shared in-process leases and are deleted after success, failure, timeout, or cancellation; a launch sweep removes only stale reproducible `inference/` scratch. Concurrent-consumer, relaunch-cleanup, and immutable-source regressions pass.
- [x] Enabled dictionary entries now preserve their standard-to-spoken mapping across live, sentence, final, and History re-recognition. Exact explicit surfaces replace every occurrence, ambiguous aliases fail closed, and the boundary remains capped at 64 entries, 32 spoken forms per entry, and 128 characters per field; the focused 38-test protocol/runtime/processing regression passes.
- [x] Final reconciliation now rejects an unambiguous batch-ASR collapse instead of inserting a short fragment over a substantially more complete live result. The selected fallback remains a final child revision with sealed-audio provenance, live segments, actual model identity, and dictionary-aware candidate selection; ordinary final corrections remain authoritative.
- [x] A startup-scan regression verifies that an orphaned active capture exposes a History recovery action after restart, while a genuinely live in-process capture never exposes a competing recovery action.
- [x] Focused regressions cover the honest three-step first-launch journey with always-visible product entry points, persistent permission decisions, real microphone-level verification, skip/resume behavior, model deferral, visible practice-insertion validation, an incomplete journey that remains resumable after History becomes non-empty, and an exact-element insertion boundary that accepts the practice editor while rejecting other same-App controls; they also cover browsing and returning during active capture, timestamp-preserving inline segment correction with stale-write rejection, rejected-candidate exclusion from active memory projections with provenance retained, candidate confirmation/undo beside the transcript, the production pending-person review query with exact source timing and retained rejected provenance, global review-to-audio navigation, undoable event-candidate dismissal, evidence-ranked event playback, chronological event membership, event confirmation/undo, and playback-key handling while text editors own focus.
- [x] The focused local event-organizer suite verifies high-confidence existing-event links, respected user rejection, long-recording semantic coverage, and exactly one new-event suggestion for a corroborated multi-recording cluster while unrelated recordings remain quiet.
- [x] The installed candidate migrated the existing v5 database to v15 with `quick_check=ok` and no foreign-key violations; its post-warm-up process remained at 0% CPU with stable resident memory across repeated samples.
- [x] Only `~/Applications/bestASR.app` remains as a runnable `.app` identity. After installation or explicit test cleanup, external Debug/Release bundles are unregistered and renamed to non-registerable `.build-product` directories; generated installation backups use `.rollback`. LaunchServices may retain stale cache rows for the now-missing old paths until its own database cleanup, but there is no second bundle at those paths to launch or authorize.
- [x] The normal installed UI reports the embedded build identity and ready local speech recognition; generated acceptance sessions and retained test audio are removed through the production deletion path after each installed-App run.
- [x] Old local bestASR DerivedData and duplicate FluidAudio/GRDB SwiftPM mirrors were removed only after the external caches passed build and test; no repository-local `.build` or DerivedData remains.
- [x] The one stable installed App identity now has Microphone, Accessibility, and System Audio Recording permission. A real global-shortcut dictation completed with bestASR and its input target unfocused, inserted exactly once into TextEdit, and left no inference scratch or App crash.
- [x] Real installed-App dictation completed and inserted into normal Chrome and VS Code processes. Chrome used its production clipboard fallback and VS Code used the same fallback after temporarily enabling its documented screen-reader mode; the VS Code mode, generated files, windows, browser profile, and local test server were restored or removed after the run.
- [x] Installed revision `d13d98c32571` completed global-shortcut dictation into a controlled blank Codex ProseMirror composer and a new blank unsaved Microsoft Word document while bestASR was unfocused. Both targets received the persisted final text exactly once through the production clipboard fallback, the original clipboard was restored, and the controlled targets were cleared or closed without saving. All nine synthetic debugging/final sessions were then removed through the production UI, returning History from 22 to the original 13 records with `quick_check=ok`; the deletion path for capture-start failures with no journal directory was fixed in installed revision `b99a2d762cfc`. Privacy-safe evidence is `artifacts/evidence/installed-app/cross-app-insertion-20260824.json`.
- [x] Production selected-App Process Tap capture passed two digital-watermark boundaries through the normal installed UI. The synthetic selected-App run detected the target in 18/18 one-second windows and rejected the nonselected App in 18/18 with 84.1 dB median separation. The normal Chrome source, including its helper audio process, detected Chrome in 12/12 windows and rejected another App in 12/12 with 85.2 dB median separation. Both journals finalized with zero gaps or recovery issues and retained the selected bundle provenance.
- [x] The unlocked-device `SPIKE-CAP-001` Process Tap release matrix now passes all 8 scenarios. A real HDMI default-output transition produced two listener notifications, detected the selected 15.3 kHz watermark both before and after the switch across 303,616 captured frames with zero dropped frames, restored the original output, used the separately confirmed real TCC-denial evidence, and ended with zero tap or aggregate-device delta. Device names, UIDs, object IDs, and captured audio are not persisted.
- [x] Installed revision `75d22ffd5617` completed a real selected-App endurance capture on a 48 GB M4 Pro through the normal UI. A Finder-frontmost `Control-Space` pause held the journal at 99 commits and the same shortcut resumed the same session. The run retained 7,244.085 seconds of 48 kHz audio as 14,490 contiguous commits and 14,490 files; all byte counts and SHA-256 digests matched, `manifest.json` stayed at 304 bytes during live recognition, database integrity remained clean, peak physical footprint was 2.3 GiB, and no App error/fault or thermal warning occurred. The unsubmitted synthetic session and its 1.39 GB of audio were then canceled through the production UI, leaving the original 13 History records unchanged. The evidence record contains device and signing details and is kept out of the public repository.
- [x] Installed revision `b6f139459f23` exposes one stable Tencent Meeting source instead of a duplicate host/helper pair and captured Tencent Meeting's local speaker-test audio through the selected-App boundary. A simultaneous 19.1 kHz watermark from a nonselected process stayed below the fail-closed threshold, pause held the durable journal at 83 chunks, resume continued the same session, and the sealed 83.051-second journal retained exact Tencent bundle provenance. The non-speech fixture correctly ended with no speech detected, so this closes Tencent source grouping, capture, exclusion, and pause/resume only—not live-meeting speech, diarization, identity, lifecycle, or microphone co-capture. The failed-recognition test record and audio were deleted through the production UI, returning History to the original 13 records with `quick_check=ok`. The evidence record contains device and signing details and is kept out of the public repository.
- [x] Installed revision `a2bf3af6c794` reprocessed a controlled Tencent Meeting synthetic-speech run with selected-App audio and the optional microphone as two production tracks. The sealed 156-chunk journal produced a six-segment final transcript, two session speakers, four source-track occurrences, correct local-microphone identity routing, anonymous remote routing with zero self-misattribution, and four Qwen local-text documents with 48 valid source references. The run exposed and closed interleaved-track materialization, overlapping transcript persistence, outer failure persistence, and strict fenced-JSON parsing regressions. Both synthetic sessions and retained audio were deleted through the production UI, returning History from 15 to the original 13 rows with `quick_check=ok`. This closes controlled Tencent speech, microphone co-capture, final ASR, speaker/identity, and local organization—not a live meeting or lifecycle/restart. The evidence record contains device and signing details and is kept out of the public repository.
- [x] FluidAudio 0.15.5 plus the exact verified `fluid-speaker-diarization-coreml` artifact is frozen as the production speaker candidate after an enrollment-only tuning run and an independently sealed public AMI real-human holdout. The holdout used the unchanged `0.5489600933809491` threshold, passed with 2.07% speaker confusion, zero known-person misidentifications, zero false merges, 15/16 correct known queries, 16/16 unknown rejections, 0.0056 RTF, and 711,704,576-byte peak RSS on the 48 GB development host. DER 24.93% and JER 31.78% remain recorded as limitations. Model/corpus attribution notices are registered; raw audio, diagnostics, and the frozen biometric profile remain external and local-only. This freezes the candidate but does not satisfy the 16 GB or installed product-path speaker release gates.
- [x] Speaker job claiming now quarantines legacy or corrupt queued records that lack an aligned persisted input/session link as `permanentFailed/corruptInput`, preserves them for audit and explicit reprocessing, and continues to the next valid job. A GRDB regression covers the legacy alpha row that previously rolled back every claim and starved all newer speaker work.
- [x] One speaker drain now attempts each durable job at most once, excludes already-attempted IDs until the next explicit wake, and continues to other sessions after a failure instead of exiting the queue. Fresh queued work is selected before retries; FluidAudio's deterministic no-speech result is classified as non-retryable corrupt input rather than a transient runtime outage.
- [x] The installed candidate loads permanent journal source tracks for real History playback: play advances the rendered timeline, pause holds it, resume continues it, and relaunch preserves the record. The focused audio-player regressions cover 44.1 kHz Float32 mono and 48 kHz Int16 stereo input.
- [x] Installed-App navigation reaches Home, History, People, Events, Dictionary, and every segmented Settings category. Event suggestions can be confirmed, traced to exact source evidence, selected, inspected, dismissed, and undone without changing source history; the current twenty-two-flow UI suite covers the primary workspace, including standard keyboard navigation, the menu-bar completion handoff, and active menu-bar pause/resume/cancel controls.
- [x] Opening Settings no longer silently starts shortcut capture. The current binding remains visible until the user explicitly clicks or presses the recorder, while the system-wide shortcut starts and ends recording with Codex or Chrome focused and bestASR unfocused.
- [x] History-list, history-detail, and live-transcript copy operations publish an immediate progress state, keep AppKit pasteboard access on the main actor, ignore stale completions, and return to a final status without freezing the UI. The raw-recognition disclosure is an explicit operable control rather than an unreliable implicit disclosure state.
- [x] Installed revisions `a3bbd398b185`, `e4c3bb0da6de`, and `fee30f0cbc46` were checked through the real installed bundle rather than a fixture App. Room-level preview starts and stops with an actionable idle state; People no longer opens below a large empty area; event suggestions are compact and first-event creation uses the full content width; the media-import drop zone is visible and exposed to Accessibility; and only one final installed process remains.
- [x] The final system-audio source picker exposes the whole-Mac choice plus six real local applications on this Mac. Stale recent `systemstats` and `SimAudioProcessorService` entries, Control Center, Control Strip, loginwindow, PowerChime, and both installed/debug bestASR identities are excluded. The installed check did not select a source or start capture.
- [x] After removing the 14 confirmed agent-generated interaction records through the production deletion path, the production database remains at 8 sessions with `quick_check=ok` and no foreign-key violations. The later real/user-spoken session and all non-test user records remain intact, and no new bestASR diagnostic crash report was created.

## Remaining acceptance work

- [x] Complete the installed-App P0 compatibility set and the broader insertion release matrix without treating fixtures as product acceptance. TextEdit, normal Chrome, normal VS Code, a blank Codex composer, and a blank Microsoft Word document pass. Terminal 2.15 now also passes 20 standard and 5 forced-fallback trials against an isolated synthetic `AXTextArea`: all 25 use the no-Return clipboard path, restore the clipboard, clear the synthetic input, and record zero wrong-target writes or side effects. Terminal acceptance permits bounded viewport whitespace only for the exact nonsecure `com.apple.Terminal` text area, rejects active Secure Event Input, and fails closed on prompts or any other content.
- [ ] Complete the remaining live selected-App Process Tap conferencing matrix. The generic process boundary, normal Chrome/helper boundary, and Tencent Meeting source grouping/capture/exclusion boundary pass through the installed App. Controlled Tencent synthetic speech now also passes optional-microphone co-capture, final ASR, diarization/identity routing, and local organization. Tencent still needs a controlled live-meeting lifecycle/restart and participant-context run; Zoom is not installed and its live path remains untested.
- [ ] Complete two-hour capture, thermal, memory, disk-pressure, sleep/wake, input-device/sample-rate change, ASR, XPC, and speaker evidence on the supported 16 GB minimum Apple Silicon device. The 48 GB installed-App selected-source capture/journal path passes for more than two hours with bounded manifest work and verified source blocks, and the generic Process Tap path passes a real default-output transition; neither substitutes for the 16 GB speech-ASR, XPC, input-device, or production-speaker gates.
- [x] Freeze the production speaker/identity candidate only after the versioned public AMI tuning/release-holdout split, exact model packaging, local-only runtime, and attribution/license gates pass. Release eligibility remains false until the separate 16 GB and installed product-path matrices pass.
- [ ] Produce a Developer ID signed, notarized, stapled, Gatekeeper-valid drag-installable DMG when the required Apple release identity and notarization credentials are available.

## Completion rule

Continue directly through the remaining acceptance work. Do not report V1,
formal dictation MVP, or release completion while a required gate is failed or
conditional. When a gate needs unavailable hardware, Apple credentials, or a
security-sensitive system change, record that exact external dependency rather
than weakening the requirement or substituting scaffolding evidence.
