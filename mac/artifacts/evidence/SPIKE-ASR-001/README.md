# SPIKE-ASR-001 evidence

`adapter-contract-smoke.json` is the reproducible contract portion of task 6.4. It runs
the FluidAudio/SenseVoice, Argmax OSS/WhisperKit, and sherpa-onnx adapter boundaries
through the same ten content-free synthetic cases for `ASR-001..010`.

The three `*-recommended-memory-smoke.json` files are content-free aggregate outputs
from the pinned real runtimes and verified model trees on one Apple M4 Pro / 48 GB
development host. Inference ran with network access denied against three local-only
synthetic audio samples. Audio, reference text, hypotheses, model files, cache paths,
and absolute filesystem paths are deliberately absent from Git.

`recommended-memory-smoke-summary.json` cross-references the exact runtime revisions,
model tree digests, corpus manifest, aggregate benchmark files, observed providers,
licenses, and unresolved release criteria. Fluid/SenseVoice recorded zero dangerous
token errors in this tiny smoke; WhisperKit recorded six and sherpa-onnx recorded two.
These values are diagnostic only and are not a model-selection result.

Run `script/run_candidate_adapter_probe.sh` to regenerate the report. Task 6.5 must
extend the real-model work to the full versioned corpus, release holdout, thermal and
long-session gates on both a 16 GB minimum device and a recommended-memory device
before any default ASR candidate can be selected. Every candidate therefore remains
`releaseEligible: false` and the release-level `summary.json` intentionally remains
absent.
