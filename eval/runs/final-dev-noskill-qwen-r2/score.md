### dev-week-v1 · without-skills · qwen3.6-35b-a3b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.979 |
| B-cubed R | 0.486 |
| B-cubed F1 | 0.650 |
| Link P (item→event, 1:1 mapped) | 0.770 |
| Link R | 0.600 |
| Link F1 | 0.675 |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 4 |
| Unfiled precision (share that is noise) | 0.500 |
| Decoy seed kept apart | 2/2 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 17 |
| Gold events | 9 |
| Questions asked | 7 |
| Same-event questions | 4 |
| Same-event questions per 100 items | 4.880 |
| Max same-event questions per day | 1 |
| Useful asks (provisional placement was wrong) | 0.750 |
| Questions whose true answer is yes | 0.714 |
| Asks suppressed by budget | 2 |
| Status-line fact recall | 0.288 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.100 |
| Home rank ran (checkpoints) | 4/4 |
| Home NDCG@5 | 0.698 |
| Home NDCG@5, recency-only order | 0.487 |
| Home top-3 precision (grade ≥ 2) | 0.667 |
| Home grade-3 recall@3 | 0.521 |
| Home gross inversions (grade gap ≥ 2) ↓ | 6 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.558 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 16.000 |
| Status line width p90 (added) | 21.000 |
| Status line width max (added) | 22.500 |
| Facts repeating their own date in the text ↓ (added) | 5 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.306 |
| Person linking (cross-source people) | 0.306 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.827 | 0.815 | 9/9 | 1/11 (0.091) | 0 | 0/0 | 0.693 |
| cp-d3 | 38 | 0.771 | 0.727 | 10/9 | 1/10 (0.100) | 0 | 0/3 | 0.756 |
| cp-d5 | 64 | 0.722 | 0.733 | 13/9 | 7/15 (0.467) | 0 | 0/7 | 0.588 |
| cp-final | 82 | 0.650 | 0.675 | 17/9 | 6/16 (0.375) | 0 | 2/10 | 0.756 |
