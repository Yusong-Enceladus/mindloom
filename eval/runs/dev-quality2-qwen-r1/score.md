### dev-week-v1 · skills · qwen3.6-35b-a3b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.959 |
| B-cubed R | 0.607 |
| B-cubed F1 | 0.743 |
| Link P (item→event, 1:1 mapped) | 0.833 |
| Link R | 0.684 |
| Link F1 | 0.751 |
| Hard-decoy leakage ↓ | 0.071 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 2/2 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 16 |
| Gold events | 9 |
| Questions asked | 6 |
| Same-event questions | 4 |
| Same-event questions per 100 items | 4.880 |
| Max same-event questions per day | 1 |
| Useful asks (provisional placement was wrong) | 0.500 |
| Questions whose true answer is yes | 0.500 |
| Asks suppressed by budget | 3 |
| Status-line fact recall | 0.596 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 1 |
| Unsupported completion claims in cards ↓ | 1 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.000 |
| Home rank ran (checkpoints) | 4/4 |
| Home NDCG@5 | 0.760 |
| Home NDCG@5, recency-only order | 0.617 |
| Home top-3 precision (grade ≥ 2) | 0.750 |
| Home grade-3 recall@3 | 0.354 |
| Home gross inversions (grade gap ≥ 2) ↓ | 2 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Person linking accuracy | 0.083 |
| Person linking (cross-source people) | 0.083 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.846 | 0.786 | 10/9 | 4/11 (0.364) | 0 | 0/0 | 0.959 |
| cp-d3 | 38 | 0.820 | 0.785 | 12/9 | 3/10 (0.300) | 0 | 0/3 | 1.043 |
| cp-d5 | 64 | 0.745 | 0.746 | 14/9 | 11/15 (0.733) | 0 | 0/7 | 0.498 |
| cp-final | 82 | 0.743 | 0.751 | 16/9 | 13/16 (0.812) | 0 | 0/10 | 0.540 |
