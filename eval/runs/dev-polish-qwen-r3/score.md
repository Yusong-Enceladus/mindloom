### dev-week-v1 · skills · qwen3.6-35b-a3b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.979 |
| B-cubed R | 0.622 |
| B-cubed F1 | 0.761 |
| Link P (item→event, 1:1 mapped) | 0.846 |
| Link R | 0.695 |
| Link F1 | 0.763 |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 2/2 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 17 |
| Gold events | 9 |
| Questions asked | 7 |
| Same-event questions | 4 |
| Same-event questions per 100 items | 4.880 |
| Max same-event questions per day | 1 |
| Useful asks (provisional placement was wrong) | 0.500 |
| Questions whose true answer is yes | 0.571 |
| Asks suppressed by budget | 3 |
| Status-line fact recall | 0.423 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.050 |
| Home rank ran (checkpoints) | 4/4 |
| Home NDCG@5 | 0.658 |
| Home NDCG@5, recency-only order | 0.511 |
| Home top-3 precision (grade ≥ 2) | 0.750 |
| Home grade-3 recall@3 | 0.542 |
| Home gross inversions (grade gap ≥ 2) ↓ | 7 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.750 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 12.500 |
| Status line width p90 (added) | 14.500 |
| Status line width max (added) | 17.500 |
| Facts repeating their own date in the text ↓ (added) | 4 |
| Person linking accuracy | 0.306 |
| Person linking (cross-source people) | 0.306 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.878 | 0.857 | 10/9 | 2/11 (0.182) | 0 | 0/0 | 0.827 |
| cp-d3 | 38 | 0.841 | 0.810 | 11/9 | 3/10 (0.300) | 0 | 0/3 | 0.917 |
| cp-d5 | 64 | 0.782 | 0.791 | 13/9 | 7/15 (0.467) | 0 | 0/7 | 0.629 |
| cp-final | 82 | 0.761 | 0.763 | 17/9 | 10/16 (0.625) | 0 | 1/10 | 0.257 |
