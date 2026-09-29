# SPIKE-SPK-001 evidence

This directory contains privacy-safe aggregate evidence from real, locally
executed speaker diarization and embedding runtimes. Audio, RTTM labels,
identity manifests, model files, raw embeddings, candidate stdout, and
absolute paths remain outside Git.

`recommended-memory-synthetic-smoke-summary.json` preserves the earlier
three-candidate synthetic comparison. Automatic speaker-count results are the
primary smoke observations; oracle speaker-count results remain diagnostic
only.

The four `fluid-ami-*` files are the subsequent real-human, public AMI corpus
evaluation of the exact production Fluid artifact. `ES2004a` is the tuning
partition. Its enrollment-only threshold was frozen before `ES2004c` (known
people) and `ES2005a` (unknown people) were read as the independent release
holdout. The calibration process was denied release-holdout file data, the
holdout process was denied tuning file data, and both processes were denied all
network access by the parent macOS sandbox.

The holdout passed the predeclared model-selection gates with 2.07% speaker
confusion, zero known-person misidentifications, zero false merges, 15/16
correct known-person queries, 16/16 unknown-person rejections, 0.0056 realtime
factor, and 711,704,576-byte peak RSS on the 48 GB development host. DER was
24.93% and JER was 31.78%; these remain visible rather than being collapsed into
the passing identity decision.

This freezes Fluid as the production speaker candidate, not as a release-ready
App. The intentionally absent `summary.json` keeps full release eligibility
blocked until the 16 GB minimum-hardware and remaining installed product-path
speaker matrices pass. The frozen profile and raw diagnostics are biometric
local-only files on external storage and are never committed.
