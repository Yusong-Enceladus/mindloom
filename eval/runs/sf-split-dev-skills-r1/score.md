### split-dev · skills · qwen3.6-35b-a3b-nvfp4 (dev, 51 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.951 |
| B-cubed R | 0.537 |
| B-cubed F1 | 0.686 |
| Link P (item→event, 1:1 mapped) | 0.832 |
| Link R | 0.674 |
| Link F1 | 0.745 |
| Segment Link P (added; items with segment truth) | 0.752 |
| Segment Link R (added) | 0.667 |
| Segment Link F1 (added) | 0.707 |
| Items filed by segments (pred) | 35 |
| Items with 2+ gold segments | 39 |
| Hard-decoy leakage ↓ | 0.262 |
| Easy-decoy leakage ↓ | n/a |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 4 |
| Unfiled precision (share that is noise) | 0.500 |
| Decoy seed kept apart | 0/1 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 21 |
| Gold events | 11 |
| Questions asked | 7 |
| Same-event questions | 7 |
| Same-event questions per 100 items | 13.730 |
| Max same-event questions per day | 2 |
| Useful asks (provisional placement was wrong) | 0.000 |
| Questions whose true answer is yes | 0.000 |
| Asks suppressed by budget | 2 |
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
| Status line width p50 (added) | 13.000 |
| Status line width p90 (added) | 15.000 |
| Status line width max (added) | 16.000 |
| Facts repeating their own date in the text ↓ (added) | 5 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.870 |
| Person linking (cross-source people) | 0.886 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-w1 | 26 | 0.807 | 0.803 | 15/10 | 0/0 (n/a) | 0 | 0/0 | n/a |
| cp-w2 | 47 | 0.774 | 0.788 | 21/11 | 0/0 (n/a) | 0 | 0/0 | n/a |
