### dev-week-v1 · skills · qwen3.6-35b-a3b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.892 |
| B-cubed R | 0.673 |
| B-cubed F1 | 0.767 |
| Link P (item→event, 1:1 mapped) | 0.818 |
| Link R | 0.663 |
| Link F1 | 0.733 |
| Segment Link P (added; items with segment truth) | n/a |
| Segment Link R (added) | n/a |
| Segment Link F1 (added) | n/a |
| Items filed by segments (pred) | n/a |
| Items with 2+ gold segments | n/a |
| Hard-decoy leakage ↓ | 0.179 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 1 |
| Unfiled precision (share that is noise) | 0.800 |
| Decoy seed kept apart | 1/2 |
| Matters absorbed into another event ↓ | ev_menu |
| Predicted events | 10 |
| Gold events | 9 |
| Questions asked | 6 |
| Same-event questions | 4 |
| Same-event questions per 100 items | 4.880 |
| Max same-event questions per day | 2 |
| Useful asks (provisional placement was wrong) | 0.750 |
| Questions whose true answer is yes | 0.667 |
| Asks suppressed by budget | 6 |
| Status-line fact recall | 0.423 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 1 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.111 |
| Home rank ran (checkpoints) | 4/4 |
| Home NDCG@5 | 0.768 |
| Home NDCG@5, recency-only order | 0.621 |
| Home top-3 precision (grade ≥ 2) | 0.917 |
| Home grade-3 recall@3 | 0.604 |
| Home gross inversions (grade gap ≥ 2) ↓ | 5 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.673 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 12.500 |
| Status line width p90 (added) | 16.000 |
| Status line width max (added) | 17.500 |
| Facts repeating their own date in the text ↓ (added) | 4 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.556 |
| Person linking (cross-source people) | 0.556 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.863 | 0.868 | 8/9 | 2/11 (0.182) | 0 | 0/0 | 0.844 |
| cp-d3 | 38 | 0.869 | 0.861 | 10/9 | 3/10 (0.300) | 0 | 1/3 | 0.780 |
| cp-d5 | 64 | 0.758 | 0.731 | 10/9 | 7/15 (0.467) | 0 | 1/6 | 0.697 |
| cp-final | 82 | 0.767 | 0.733 | 10/9 | 10/16 (0.625) | 0 | 0/9 | 0.750 |
