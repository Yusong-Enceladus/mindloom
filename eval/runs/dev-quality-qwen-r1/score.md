### dev-week-v1 · skills · qwen3.6-35b-a3b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.976 |
| B-cubed R | 0.690 |
| B-cubed F1 | 0.809 |
| Link P (item→event, 1:1 mapped) | 0.923 |
| Link R | 0.758 |
| Link F1 | 0.832 |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 2/2 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 13 |
| Gold events | 9 |
| Questions asked | 5 |
| Same-event questions | 3 |
| Same-event questions per 100 items | 3.660 |
| Max same-event questions per day | 1 |
| Useful asks (provisional placement was wrong) | 0.667 |
| Questions whose true answer is yes | 0.800 |
| Asks suppressed by budget | 1 |
| Status-line fact recall | 0.673 |
| Planned facts written as done ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.100 |
| Home rank ran (checkpoints) | 4/4 |
| Home NDCG@5 | 0.814 |
| Home NDCG@5, recency-only order | 0.632 |
| Home top-3 precision (grade ≥ 2) | 0.833 |
| Home grade-3 recall@3 | 0.208 |
| Home gross inversions (grade gap ≥ 2) ↓ | 1 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Person linking accuracy | 0.083 |
| Person linking (cross-source people) | 0.083 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.916 | 0.929 | 9/9 | 5/11 (0.455) | 0 | 0/0 | 1.081 |
| cp-d3 | 38 | 0.887 | 0.886 | 10/9 | 7/10 (0.700) | 0 | 0/3 | 0.839 |
| cp-d5 | 64 | 0.869 | 0.881 | 10/9 | 11/15 (0.733) | 0 | 0/7 | 0.745 |
| cp-final | 82 | 0.809 | 0.832 | 13/9 | 12/16 (0.750) | 0 | 2/10 | 0.590 |
