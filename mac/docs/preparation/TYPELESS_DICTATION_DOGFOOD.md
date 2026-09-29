# Typeless-grade dictation dogfood

This probe is for the `deliver-typeless-grade-dictation` change. Keep all raw
recordings, transcripts, model staging, and local measurements under ignored
Application Support or `RuntimeData/`; never copy them into Git.

## Automated acceptance

Run:

```sh
script/run_typeless_dictation_acceptance.sh
```

It covers the pinned download catalog, interruption/resume, integrity failure,
last-known-good activation boundary, committed-audio live snapshots, deterministic
sentence silence, capture-first journaling, final-only insertion safeguards,
target classification, accessibility identifiers, the privacy scan, and generated
project drift.

## Local first-run and daily-use probe

1. Move aside only the development model pointers/download receipts for a clean
   setup probe; do not delete recordings or history. Launch with
   `script/build_and_run.sh`.
2. Confirm the main window explains the two product-selected models, their
   combined size, licenses, local destination, and network purpose before any
   transfer. Accept both licenses and choose **Download and Prepare**.
3. Interrupt the network once, relaunch, and confirm setup resumes without
   redownloading a file already marked verified. Confirm an offline relaunch
   reports both installed components ready.
4. Focus a non-secure editable field, start with Option-Space, speak mixed Chinese
   and English, pause, resume, and finish. Confirm the panel shows revisable live
   text, a pause closes the current sentence, and only the final/polished text is
   inserted once.
5. Repeat with Codex, TextEdit, Chrome, VS Code, one rich-text document, and one
   chat composer. Include accessibility denial, a secure field, focus drift, and
   clipboard fallback. Fail closed: the transcript must remain copyable and must
   not be automatically replayed after an ambiguous insertion.
6. Force the local inference process unavailable during recording. Confirm the
   UI says audio is retained, capture continues, history exposes recovery, and a
   later local retry succeeds.

Record only bounded values: app/model versions, setup duration, time to first
live text, finish-to-final duration, peak memory, maximum live queue depth,
insertion outcome category, and recovery outcome. Do not record full transcript
text, audio, dictionary content, window title, clipboard content, or element IDs.

Physical 16 GB release evidence, Developer ID signing/notarization, and the full
room/system/import/global-person V1 remain separate gates.

## Storage migration and rollback

This change is additive. Existing `history.sqlite` databases, retained audio,
transcript revisions, insertion-ledger rows, and manually activated model
pointers keep their existing schemas and paths. Automatic transfers add only
artifact/version-scoped receipts under Application Support `model-downloads/`;
no database rewrite or destructive migration is required.

The primary setup and the Advanced folder installer use the same checked-in
artifact identity, file sizes, SHA-256 digests, health checks, and atomic active
pointer. If automatic transfer fails, retry resumes valid staged files; Advanced
manual installation remains the offline rollback path. Activation never changes
the active pointer until health checking succeeds, and the prior verified
last-known-good pointer remains recoverable.

SenseVoice uses the bundled FunASR Model License 1.1 inventory and Qwen3 uses
the bundled Apache License 2.0 inventory. Runtime model files, transfer receipts,
derived inference audio, databases, dogfood recordings, and measurements remain
under Application Support or the Git-ignored `Models/` and `RuntimeData/` paths.
Rolling back to recovery commit `1fc145c` does not delete or rewrite those assets.
