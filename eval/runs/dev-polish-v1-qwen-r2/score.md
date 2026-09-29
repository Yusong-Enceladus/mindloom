### dev-week-v1 · skills · qwen3.6-35b-a3b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.929 |
| B-cubed R | 0.611 |
| B-cubed F1 | 0.737 |
| Link P (item→event, 1:1 mapped) | 0.846 |
| Link R | 0.695 |
| Link F1 | 0.763 |
| Hard-decoy leakage ↓ | 0.083 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 1/2 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 15 |
| Gold events | 9 |
| Questions asked | 7 |
| Same-event questions | 4 |
| Same-event questions per 100 items | 4.880 |
| Max same-event questions per day | 2 |
| Useful asks (provisional placement was wrong) | 0.750 |
| Questions whose true answer is yes | 0.571 |
| Asks suppressed by budget | 4 |
| Status-line fact recall | 0.423 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 1 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.000 |
| Home rank ran (checkpoints) | 4/4 |
| Home NDCG@5 | 0.768 |
| Home NDCG@5, recency-only order | 0.518 |
| Home top-3 precision (grade ≥ 2) | 0.833 |
| Home grade-3 recall@3 | 0.438 |
| Home gross inversions (grade gap ≥ 2) ↓ | 5 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.731 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 11.500 |
| Status line width p90 (added) | 14.500 |
| Status line width max (added) | 18.500 |
| Facts repeating their own date in the text ↓ (added) | 2 |
| Person linking accuracy | 0.306 |
| Person linking (cross-source people) | 0.306 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.826 | 0.786 | 9/9 | 2/11 (0.182) | 0 | 0/0 | 0.824 |
| cp-d3 | 38 | 0.810 | 0.759 | 11/9 | 3/10 (0.300) | 0 | 0/3 | 0.933 |
| cp-d5 | 64 | 0.785 | 0.806 | 11/9 | 7/15 (0.467) | 0 | 0/7 | 0.724 |
| cp-final | 82 | 0.737 | 0.763 | 15/9 | 10/16 (0.625) | 0 | 0/10 | 0.590 |
