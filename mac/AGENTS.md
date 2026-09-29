# bestASR repository instructions

## Source of truth

- Read `PRODUCT_REQUIREMENTS.md`, `IMPLEMENTATION_STATUS.md`, and `docs/architecture/TECHNICAL_DESIGN.md` before making a non-trivial change.
- Product scope and acceptance behavior live in the PRD, current delivery state lives in `IMPLEMENTATION_STATUS.md`, and implementation decisions live in the technical design and ADRs. If they conflict, update them together before implementation.
- Preserve requirement IDs. Do not silently reinterpret, renumber, or drop a P0/P1 requirement.

## Product invariants

- The macOS V1 must run locally after model installation. Audio, voiceprints/speaker embeddings, and dictionaries never leave the Mac. Transcripts, user-provided items (text, screenshots, documents), and their source metadata may leave the Mac only to the user's own DGX Spark, only over an explicitly enabled, revocable SSH-encrypted link, and only for organizing. There is no cloud path. Capture, recognition, insertion, and search never depend on that link. During development only synthetic data may be sent anywhere; never send the user's real library (`~/Library/Application Support/bestASR`). See PRD §0.3.
- Product telemetry and remote crash reporting are off by default. Never log audio, full transcripts, dictionary contents, speaker embeddings, or participant metadata.
- V1 is a native Apple Silicon macOS app targeting macOS 14.2 or later with at least 16 GB unified memory. It must not require Python, Homebrew, a virtual audio driver, or a command-line runtime on the user's machine.
- Multi-speaker processing and one global person-identity pipeline are required for dictation, room-microphone recordings, system-audio recordings, and imported media. A single speaker is one cluster in that same pipeline. Label-free dictation insertion is presentation only; it must not discard internal speaker occurrences, evidence, or searchability.
- The MVP is dictation-first, but it must use the V1 protocols, domain entities, persistence, durable jobs, model boundaries, and person-identity semantics. Do not introduce MVP-only identity types or throwaway core architecture.
- V1 does not ship cloud sync or multi-user collaboration; the only cross-device path is the user's own organizing device (the DGX Spark link above), which receives organizing input and returns derived results but is not a sync or a source of truth. Use stable UUIDs, explicit revisions/tombstones, portable asset references, and storage interfaces so a future iPhone/Mac sync or migration layer does not require rewriting domain data.
- Preserve raw audio for every mode by default until the user explicitly deletes it. Never treat cache cleanup, model updates, reprocessing, or disk-pressure handling as authorization to delete source audio.
- Keep three export paths distinct: source-audio export preserves the retained/original format where possible; full offline migration uses an authenticated encrypted `.bestasrarchive` with a portable user secret; future cloud sync uses `SyncAdapter` rather than uploading archive blobs.
- Preserve source audio and transcript provenance. A polished transcript, summary, or speaker match must never overwrite its source evidence.
- Recording durability outranks inference. Capture and journal audio even when an inference backend is slow, unavailable, or restarting.

## Engineering rules

- Keep UI, capture, inference, persistence, text insertion, and future sync behind explicit Swift protocols. Domain types must not import a concrete model SDK.
- Make background jobs idempotent and resumable. Persist job input revision, model version, prompt/config hash, state, retry count, and error category.
- Treat model files as signed/versioned artifacts: download atomically, verify size and digest, retain the last known-good version, and record licenses.
- Use monotonic timestamps for capture and alignment. Record pauses, device/source changes, gaps, and discontinuities as timeline events.
- Use Swift structured concurrency with explicit actor ownership. Do not use detached tasks for durable work without cancellation and persistence semantics.
- Do not add a dependency until its runtime behavior, minimum OS, license, distribution impact, and privacy behavior are recorded.
- Prefer deterministic fixtures and command-line reproducible probes. Every bug fix needs a regression test or a saved reproduction fixture.

## Quality gates

- A feature is not complete until its PRD acceptance scenarios, unit/integration tests, privacy checks, failure/recovery behavior, and relevant performance evidence pass.
- Never select ASR, diarization, speaker embedding, or local-LLM models from vendor claims alone. Use the repository's versioned local evaluation corpus and benchmark harness.
- Run the narrowest relevant checks while iterating and the full `script/check.sh` gate before declaring an implementation change complete once that script exists.
- Use the Codex Security threat-model/diff-scan workflow for changes to permissions, capture boundaries, persistence/encryption, model or App updates, signing, and future sync; keep private corpora and user content outside scan artifacts.
- Keep generated build output, downloaded models, local corpora, benchmark results containing user audio, secrets, and signing material out of Git.
