### holdout-week-v1 · skills · qwen3.6-35b-a3b-nvfp4 (holdout, 32 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.851 |
| B-cubed R | 0.795 |
| B-cubed F1 | 0.822 |
| Link P (item→event, 1:1 mapped) | 0.900 |
| Link R | 0.818 |
| Link F1 | 0.857 |
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
| Predicted events | 5 |
| Gold events | 5 |
| Questions asked | 2 |
| Same-event questions | 1 |
| Same-event questions per 100 items | 3.120 |
| Max same-event questions per day | 1 |
| Useful asks (provisional placement was wrong) | 0.000 |
| Questions whose true answer is yes | 0.500 |
| Asks suppressed by budget | 0 |
| Status-line fact recall | 0.688 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.000 |
| Home rank ran (checkpoints) | 2/2 |
| Home NDCG@5 | 1.110 |
| Home NDCG@5, recency-only order | 0.974 |
| Home top-3 precision (grade ≥ 2) | 0.833 |
| Home grade-3 recall@3 | 1.000 |
| Home gross inversions (grade gap ≥ 2) ↓ | 0 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.875 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 11.500 |
| Status line width p90 (added) | 17.500 |
| Status line width max (added) | 17.500 |
| Facts repeating their own date in the text ↓ (added) | 0 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.545 |
| Person linking (cross-source people) | 0.562 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-h3 | 18 | 0.852 | 0.882 | 4/4 | 5/7 (0.714) | 0 | 0/3 | 1.220 |
| cp-final | 32 | 0.822 | 0.857 | 5/5 | 6/9 (0.667) | 0 | 0/6 | 1.000 |
