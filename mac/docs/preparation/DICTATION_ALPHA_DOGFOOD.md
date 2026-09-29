# Dictation Alpha dogfood

> This document preserves the alpha baseline. The current guided model setup,
> live transcript, and daily-use acceptance flow are documented in
> `TYPELESS_DICTATION_DOGFOOD.md`.

This build is the first local, built-in-Mac dictation slice. It can replace the
core Typeless loop of recording speech, rewriting it locally, and inserting one
final value into the original text target. It does not yet display streaming
draft text while the user is speaking.

## Supported dogfood scope

- Apple Silicon Mac running macOS 14.2 or later with at least 16 GB unified
  memory.
- The Mac built-in microphone selected as the system default input.
- TextEdit, Chrome text fields, and VS Code text editors are the validated alpha
  target set.
- No Python, Homebrew, command-line runtime, virtual audio driver, external
  device, system-audio capture, or cross-device service is required.

## Install and prepare

1. For current repository dogfood, run `script/build_release.sh` and
   `script/install_local_app.sh`. The daily-use build is signed with the stable
   Apple Development identity available on the development Mac and installed at
   `~/Applications/bestASR.app`; it is still not a Developer ID notarized public
   release. Previous bundles are recoverable from
   `/Volumes/BestASRBuild/bestASR/installation-backups` rather than
   appearing beside the current app in Applications.
2. In macOS System Settings, grant bestASR **Microphone** and
   **Accessibility** access. The app links directly to both recovery panes from
   its Settings window.
3. Open bestASR Settings. Review and accept the included model licenses, then
   choose these exact repository-local folders:
   - `Models/downloads/fluid-sensevoice-small-int8-0e0bf30b`
   - `Models/downloads/qwen3-1.7b-mlx-4bit-21457c6f`
4. Wait until Settings reports that SenseVoice and Qwen are ready. A fresh
   process can spend about 102 seconds preparing SenseVoice; bestASR registers
   controls and preserves capture before that preparation finishes, but the
   first final transcript must wait for the model.

The folder pickers copy the exact model files into bestASR's Application Support
directory and verify every registered size and SHA-256 digest. They do not call
a model download API. The repository-local source folders and installed model
copies are not part of the DMG.

## Dictate

1. Focus a non-secure editable target in TextEdit, Chrome, or VS Code.
2. Press **Option-Space** to start. The non-activating recording panel should
   appear without moving focus.
3. Press **Option-Shift-Space** to pause or resume the same session. Press
   **Escape** to cancel an uncommitted dictation.
4. Press the start/end shortcut again to finish. bestASR seals the retained
   source audio, runs SenseVoice, applies Qwen protected polish or the safe
   punctuation fallback, revalidates the original target, and inserts at most
   once.
5. Open Settings to replace either shortcut with another supplied native chord.
   A registration conflict fails closed and leaves the previous configuration
   active.

If the target or selection changed, the field is secure, or automatic insertion
is unsafe, bestASR keeps the result in Local History for explicit copy instead
of writing to the wrong place. Raw and polished text remain separate, and source
audio is never removed by cache cleanup, model updates, or reprocessing.

## Current boundaries

- Final text appears after ending the dictation; streaming draft UI and its
  first-text latency evidence remain unfinished.
- The measured Release path for one 9-second bilingual sample is 2.488 seconds
  after model preparation. This is a feasibility point, not the required P95 or
  16 GB hardware matrix.
- Permission denied/revoked recovery has deterministic coverage, but the full
  real-device TCC transition matrix remains unfinished.
- Terminal is not in the first alpha target set. System audio, external-device
  matrices, multi-person identity validation, and cross-device sync are outside
  this slice.
- The DMG passes architecture, minimum-OS, hardened-runtime, bundle, and local
  signature smoke checks. Public distribution remains blocked until a Developer
  ID Application identity and notary keychain profile are supplied.

After the explicit local model installation, normal capture, recognition,
polish, dictionary, history, and insertion have a deny-network end-to-end gate.
Telemetry and remote crash reporting are off, and evidence artifacts exclude
audio, transcript text, dictionary contents, clipboard data, window titles, and
person metadata.
