### dev-week-v1 · skills · nano-omni-org (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.837 |
| B-cubed R | 0.234 |
| B-cubed F1 | 0.365 |
| Link P (item→event, 1:1 mapped) | 0.410 |
| Link R | 0.358 |
| Link F1 | 0.382 |
| Segment Link P (added; items with segment truth) | n/a |
| Segment Link R (added) | n/a |
| Segment Link F1 (added) | n/a |
| Items filed by segments (pred) | n/a |
| Items with 2+ gold segments | n/a |
| Hard-decoy leakage ↓ | 0.095 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention (= noise unfiled rate) | 0.000 |
| Noise as its own one-item event | 0.500 |
| Noise inside a real event ↓ | 0.500 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | n/a |
| Decoy seed kept apart | 2/2 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 47 |
| Gold events | 9 |
| Questions asked | 10 |
| Same-event questions | 6 |
| Same-event questions per 100 items | 7.320 |
| Max same-event questions per day | 2 |
| Useful asks (provisional placement was wrong) | 0.500 |
| Questions whose true answer is yes | 0.500 |
| Asks suppressed by budget | 38 |
| Status-line fact recall | 0.192 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 2 |
| Stale-fact rate ↓ | 0.000 |
| Home rank ran (checkpoints) | 4/4 |
| Home NDCG@5 | 0.309 |
| Home NDCG@5, recency-only order | 0.217 |
| Home top-3 precision (grade ≥ 2) | 0.417 |
| Home grade-3 recall@3 | 0.188 |
| Home gross inversions (grade gap ≥ 2) ↓ | 34 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.423 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 12.500 |
| Status line width p90 (added) | 16.500 |
| Status line width max (added) | 21.500 |
| Facts repeating their own date in the text ↓ (added) | 0 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.306 |
| Person linking (cross-source people) | 0.306 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.590 | 0.561 | 16/9 | 1/11 (0.091) | 0 | 0/0 | 0.635 |
| cp-d3 | 38 | 0.512 | 0.469 | 23/9 | 3/10 (0.300) | 0 | 0/3 | 0.167 |
| cp-d5 | 64 | 0.419 | 0.420 | 37/9 | 2/15 (0.133) | 0 | 0/7 | 0.147 |
| cp-final | 82 | 0.365 | 0.382 | 47/9 | 4/16 (0.250) | 0 | 0/9 | 0.287 |
