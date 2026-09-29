# bestASR engineering readiness

- Conclusion: **conditional**
- Delivery status: **incomplete**
- Gates: 15 pass / 6 conditional / 0 fail
- Tasks: 67 completed / 6 pending

## Gate results

| Gate | Status | Observed | Expected |
|---|---:|---|---|
| `full-repository-check` | pass | `pass` | `pass` |
| `live-process-tap-boundary` | pass | `pass` | `pass` |
| `audio-journal-decision` | conditional | `conditional` | `pass` |
| `two-hour-recording` | pass | `pass` | `pass` |
| `audio-decision-cross-check` | pass | `pass` | `pass` |
| `ax-insertion-live-probe` | pass | `pass` | `pass` |
| `ax-insertion-compatibility` | pass | `pass` | `pass` |
| `xpc-real-model-boundary` | conditional | `conditional` | `pass` |
| `asr-release-device-matrix` | conditional | `null` | `pass` |
| `speaker-release-device-matrix` | conditional | `null` | `pass` |
| `candidate-default-selection` | conditional | `alpha-default-selected-from-local-corpus` | `release-default-selected-from-device-matrix` |
| `inference-evidence-integrity` | pass | `pass` | `pass` |
| `llm-factual-hard-gate` | pass | `pass` | `pass` |
| `resource-priority-policy` | pass | `pass` | `pass` |
| `permission-minimization` | pass | `pass` | `pass` |
| `signed-notarized-release` | conditional | `false` | `true` |
| `release-package-supply-chain` | pass | `pass` | `pass` |
| `update-signature-and-rollback` | pass | `pass` | `pass` |
| `privacy-scan` | pass | `pass` | `pass` |
| `traceability-integrity` | pass | `pass` | `pass` |
| `product-consistency` | pass | `pass` | `pass` |

## Pending tasks

- Streaming, final ASR, alignment, diarization/identity, semantic retrieval, and local-text backends are selected per stage on one versioned realistic local corpus; existing alpha selections do not count as release defaults.
- One installed identity continuously passes PRD 24.6, leaves no test windows or records behind, and remains fully usable with network denied after model preparation.
- Execute the current `BestASRUITests` suite: the latest runner timed out enabling macOS automation mode before any test executed. A preceding twenty-two-journey run and affected reruns passed keyboard navigation, deferrable setup and real-practice validation, capture/processing/completion handoff, menu-bar controls, waveform playback/pause/seeking, source-linked inline correction, microphone/system level previews, person/event evidence review and undo, all six Settings categories, and retained dictionary drafts after a failed save. That historical result does not validate the newer chooser-parent, collapsed review queue, or read-first document assertions; their current native automation gate remains open alongside the separately recorded installed-App checks.
- Complete the remaining live selected-App Process Tap conferencing matrix. The generic process boundary, normal Chrome/helper boundary, and Tencent Meeting source grouping/capture/exclusion boundary pass through the installed App. Controlled Tencent synthetic speech now also passes optional-microphone co-capture, final ASR, diarization/identity routing, and local organization. Tencent still needs a controlled live-meeting lifecycle/restart and participant-context run; Zoom is not installed and its live path remains untested.
- Complete two-hour capture, thermal, memory, disk-pressure, sleep/wake, input-device/sample-rate change, ASR, XPC, and speaker evidence on the supported 16 GB minimum Apple Silicon device. The 48 GB installed-App selected-source capture/journal path passes for more than two hours with bounded manifest work and verified source blocks, and the generic Process Tap path passes a real default-output transition; neither substitutes for the 16 GB speech-ASR, XPC, input-device, or production-speaker gates.
- Produce a Developer ID signed, notarized, stapled, Gatekeeper-valid drag-installable DMG when the required Apple release identity and notarization credentials are available.

A non-pass report keeps the product ineligible for release.
