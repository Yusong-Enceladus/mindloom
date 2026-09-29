### dev-week-v1 · skills · qwen3.6-35b-a3b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.981 |
| B-cubed R | 0.731 |
| B-cubed F1 | 0.838 |
| Link P (item→event, 1:1 mapped) | 0.974 |
| Link R | 0.789 |
| Link F1 | 0.872 |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 1 |
| Unfiled precision (share that is noise) | 0.800 |
| Decoy seed kept apart | 2/2 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 10 |
| Gold events | 9 |
| Questions asked | 10 |
| Same-event questions | 8 |
| Same-event questions per 100 items | 9.760 |
| Max same-event questions per day | 2 |
| Useful asks (provisional placement was wrong) | 0.625 |
| Questions whose true answer is yes | 0.800 |
| Asks suppressed by budget | 1 |
| Status-line fact recall | 0.750 |
| Planned facts written as done ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.050 |
| Home rank ran (checkpoints) | 4/4 |
| Home NDCG@5 | 0.826 |
| Home NDCG@5, recency-only order | 0.630 |
| Home top-3 precision (grade ≥ 2) | 0.917 |
| Home grade-3 recall@3 | 0.729 |
| Home gross inversions (grade gap ≥ 2) ↓ | 4 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Person linking accuracy | 0.083 |
| Person linking (cross-source people) | 0.083 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.933 | 0.929 | 9/9 | 5/11 (0.455) | 0 | 0/0 | 0.869 |
| cp-d3 | 38 | 0.909 | 0.911 | 9/9 | 7/10 (0.700) | 0 | 1/3 | 0.840 |
| cp-d5 | 64 | 0.866 | 0.896 | 9/9 | 12/15 (0.800) | 0 | 0/7 | 0.818 |
| cp-final | 82 | 0.838 | 0.872 | 10/9 | 15/16 (0.938) | 0 | 0/10 | 0.775 |
