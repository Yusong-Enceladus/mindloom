# claude/scale-quality eval runs (2026-09-29)

Synthetic data only. Scored with `eval/score.py`; model Qwen3.6-35B-A3B on the shared GB10 endpoint.

| run | scenario | code |
|---|---|---|
| `sq-dev-base` | dev-week-v1, pair A (shared endpoint) | `claude/files` (before) |
| `sq-dev-new` | dev-week-v1, pair A | scale-quality at `9192650` |
| `sq-dev-base2` | dev-week-v1, pair B (endpoint otherwise idle) | `claude/files` (before) |
| `sq-dev-new2` | dev-week-v1, pair B | scale-quality at `d56d29e` |
| `sq-holdout-new` | holdout-week-v2 (frozen test, run once) | scale-quality at `9192650` |
| `sq-split/split-{base,new}.json` | split-dev (item-split benchmark) | before / after |

holdout-week-v2 against the multimodal "before" run: B3 F1 0.797 -> 0.818, but link F1 0.815 -> 0.736,
decoy leakage 0 -> 0.333, card fact recall 0.655 -> 0.356 and status fact recall 0.276 -> 0.161. The
earlier state of the branch (`92293fc`: similarity-first candidates, event-assign 2.2.0, event-merge
consolidation, persons changes, brief window) was worse than "before" on every one of those metrics
(B3 F1 0.740, leakage 0.50, card recall 0.333); the brief-repair commit improved on it.

So main takes only: the brief repair without retry (`9192650`, `d56d29e`), item-split 1.2.0 (split-dev
part F1 0.927 -> 0.944, count exact 0.784 -> 0.824, no over-split single-matter items) and the
ORGANIZER_CLOCK=replay guidance with its `clock_warning`. The candidate re-weighting, event-assign 2.2.0,
event-merge / consolidation pass, persons changes and the 20-item brief window stay on
`claude/scale-quality`, unmerged.
