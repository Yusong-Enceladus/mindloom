### holdout-week-v1 · skills · qwen3.6-35b-a3b-nvfp4 (holdout, 32 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.850 |
| B-cubed R | 0.734 |
| B-cubed F1 | 0.787 |
| Link P (item→event, 1:1 mapped) | 0.833 |
| Link R | 0.758 |
| Link F1 | 0.794 |
| Segment Link P (added; items with segment truth) | n/a |
| Segment Link R (added) | n/a |
| Segment Link F1 (added) | n/a |
| Items filed by segments (pred) | n/a |
| Items with 2+ gold segments | n/a |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 2/2 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 7 |
| Gold events | 5 |
| Questions asked | 2 |
| Same-event questions | 1 |
| Same-event questions per 100 items | 3.120 |
| Max same-event questions per day | 1 |
| Useful asks (provisional placement was wrong) | 1.000 |
| Questions whose true answer is yes | 0.500 |
| Asks suppressed by budget | 0 |
| Status-line fact recall | 0.625 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.000 |
| Home rank ran (checkpoints) | 2/2 |
| Home NDCG@5 | 0.730 |
| Home NDCG@5, recency-only order | 0.620 |
| Home top-3 precision (grade ≥ 2) | 0.667 |
| Home grade-3 recall@3 | 1.000 |
| Home gross inversions (grade gap ≥ 2) ↓ | 1 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.750 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 11.000 |
| Status line width p90 (added) | 14.000 |
| Status line width max (added) | 14.000 |
| Facts repeating their own date in the text ↓ (added) | 0 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.545 |
| Person linking (cross-source people) | 0.562 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-h3 | 18 | 0.896 | 0.882 | 3/4 | 4/7 (0.571) | 0 | 0/3 | 0.844 |
| cp-final | 32 | 0.787 | 0.794 | 7/5 | 6/9 (0.667) | 0 | 0/6 | 0.617 |
