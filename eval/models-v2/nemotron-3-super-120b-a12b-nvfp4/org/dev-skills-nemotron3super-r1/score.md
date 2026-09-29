### dev-week-v1 · skills · nemotron-3-super-120b-a12b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.913 |
| B-cubed R | 0.656 |
| B-cubed F1 | 0.764 |
| Link P (item→event, 1:1 mapped) | 0.910 |
| Link R | 0.747 |
| Link F1 | 0.821 |
| Segment Link P (added; items with segment truth) | n/a |
| Segment Link R (added) | n/a |
| Segment Link F1 (added) | n/a |
| Items filed by segments (pred) | n/a |
| Items with 2+ gold segments | n/a |
| Hard-decoy leakage ↓ | 0.071 |
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
| Questions asked | 5 |
| Same-event questions | 3 |
| Same-event questions per 100 items | 3.660 |
| Max same-event questions per day | 2 |
| Useful asks (provisional placement was wrong) | 0.667 |
| Questions whose true answer is yes | 0.600 |
| Asks suppressed by budget | 0 |
| Status-line fact recall | 0.423 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 1 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 1 |
| Stale-fact rate ↓ | 0.050 |
| Home rank ran (checkpoints) | 4/4 |
| Home NDCG@5 | 0.692 |
| Home NDCG@5, recency-only order | 0.626 |
| Home top-3 precision (grade ≥ 2) | 0.750 |
| Home grade-3 recall@3 | 0.458 |
| Home gross inversions (grade gap ≥ 2) ↓ | 2 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.788 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 15.500 |
| Status line width p90 (added) | 20.500 |
| Status line width max (added) | 23.000 |
| Facts repeating their own date in the text ↓ (added) | 0 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.306 |
| Person linking (cross-source people) | 0.306 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.845 | 0.857 | 10/9 | 2/11 (0.182) | 0 | 0/0 | 0.895 |
| cp-d3 | 38 | 0.845 | 0.861 | 10/9 | 3/10 (0.300) | 0 | 0/3 | 0.667 |
| cp-d5 | 64 | 0.786 | 0.836 | 11/9 | 8/15 (0.533) | 0 | 0/7 | 0.902 |
| cp-final | 82 | 0.764 | 0.821 | 12/9 | 9/16 (0.562) | 0 | 1/10 | 0.305 |
