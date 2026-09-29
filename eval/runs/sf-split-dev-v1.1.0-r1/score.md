### split-dev · skills · qwen3.6-35b-a3b-nvfp4 (dev, 51 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.947 |
| B-cubed R | 0.499 |
| B-cubed F1 | 0.654 |
| Link P (item→event, 1:1 mapped) | 0.739 |
| Link R | 0.621 |
| Link F1 | 0.675 |
| Segment Link P (added; items with segment truth) | 0.675 |
| Segment Link R (added) | 0.614 |
| Segment Link F1 (added) | 0.643 |
| Items filed by segments (pred) | 35 |
| Items with 2+ gold segments | 39 |
| Hard-decoy leakage ↓ | 0.167 |
| Easy-decoy leakage ↓ | n/a |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 4 |
| Unfiled precision (share that is noise) | 0.500 |
| Decoy seed kept apart | 0/1 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 28 |
| Gold events | 11 |
| Questions asked | 6 |
| Same-event questions | 6 |
| Same-event questions per 100 items | 11.760 |
| Max same-event questions per day | 1 |
| Useful asks (provisional placement was wrong) | 0.000 |
| Questions whose true answer is yes | 0.000 |
| Asks suppressed by budget | 7 |
| Status-line fact recall | n/a |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 1 |
| Stale-fact rate ↓ | n/a |
| Home rank ran (checkpoints) | n/a |
| Home NDCG@5 | n/a |
| Home NDCG@5, recency-only order | n/a |
| Home top-3 precision (grade ≥ 2) | n/a |
| Home grade-3 recall@3 | n/a |
| Home gross inversions (grade gap ≥ 2) ↓ | n/a |
| Noise cards in home top 5 ↓ | n/a |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | n/a |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 12.000 |
| Status line width p90 (added) | 15.000 |
| Status line width max (added) | 18.500 |
| Facts repeating their own date in the text ↓ (added) | 1 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.870 |
| Person linking (cross-source people) | 0.886 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-w1 | 26 | 0.813 | 0.807 | 16/10 | 0/0 (n/a) | 0 | 0/0 | n/a |
| cp-w2 | 47 | 0.739 | 0.713 | 28/11 | 0/0 (n/a) | 0 | 0/0 | n/a |
