# bestASR dictation alpha readiness

- Dictation alpha: **pass**
- Formal MVP: **conditional**
- V1: **conditional**

Dictation alpha is calculated only from built-in-microphone dictation gates. Formal MVP and V1 additionally include the visible whole-product gaps below.

## Dictation alpha gates

| Gate | Status | Observed | Expected |
|---|---:|---|---|
| `deterministic-vertical-slice` | pass | `pass` | `pass` |
| `repository-check` | pass | `pass` | `pass` |
| `alpha-permissions` | pass | `pass` | `pass` |
| `local-asr-alpha-default` | pass | `alpha-default-selected-from-local-corpus` | `alpha-default-selected-from-local-corpus` |
| `built-in-microphone-live-smoke` | pass | `pass` | `pass` |
| `installed-model-offline-loop` | pass | `pass` | `pass` |
| `local-polish-real-model-gate` | pass | `pass` | `pass` |
| `alpha-target-compatibility` | pass | `pass` | `pass` |

## Whole-product gaps

| Gap | Scope | Status |
|---|---|---:|
| `process-tap-system-audio` | both | pass |
| `second-output-device` | both | pass |
| `multi-speaker-global-person` | both | conditional |
