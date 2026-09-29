### dev-week-v1 · skills · qwen3.6-35b-a3b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.860 |
| B-cubed R | 0.707 |
| B-cubed F1 | 0.776 |
| Link P (item→event, 1:1 mapped) | 0.833 |
| Link R | 0.684 |
| Link F1 | 0.751 |
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
| Predicted events | 12 |
| Gold events | 9 |
| Questions asked | 10 |
| Same-event questions | 6 |
| Same-event questions per 100 items | 7.320 |
| Max same-event questions per day | 2 |
| Useful asks (provisional placement was wrong) | 0.000 |
| Questions whose true answer is yes | 0.400 |
| Asks suppressed by budget | 5 |
| Status-line fact recall | 0.423 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.050 |
| Home rank ran (checkpoints) | 4/4 |
| Home NDCG@5 | 0.784 |
| Home NDCG@5, recency-only order | 0.658 |
| Home top-3 precision (grade ≥ 2) | 0.917 |
| Home grade-3 recall@3 | 0.604 |
| Home gross inversions (grade gap ≥ 2) ↓ | 5 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.692 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 12.000 |
| Status line width p90 (added) | 14.000 |
| Status line width max (added) | 18.500 |
| Facts repeating their own date in the text ↓ (added) | 1 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.306 |
| Person linking (cross-source people) | 0.306 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.902 | 0.857 | 9/9 | 1/11 (0.091) | 0 | 0/0 | 0.824 |
| cp-d3 | 38 | 0.852 | 0.810 | 10/9 | 4/10 (0.400) | 0 | 0/3 | 0.894 |
| cp-d5 | 64 | 0.783 | 0.746 | 11/9 | 7/15 (0.467) | 0 | 0/7 | 0.974 |
| cp-final | 82 | 0.776 | 0.751 | 12/9 | 10/16 (0.625) | 0 | 1/10 | 0.442 |
