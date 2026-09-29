### holdout-week-v1 · skills · qwen3.6-35b-a3b-nvfp4 (holdout, 32 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.891 |
| B-cubed R | 0.823 |
| B-cubed F1 | 0.856 |
| Link P (item→event, 1:1 mapped) | 0.933 |
| Link R | 0.848 |
| Link F1 | 0.889 |
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
| Questions asked | 3 |
| Same-event questions | 3 |
| Same-event questions per 100 items | 9.380 |
| Max same-event questions per day | 1 |
| Useful asks (provisional placement was wrong) | 0.333 |
| Questions whose true answer is yes | 0.333 |
| Asks suppressed by budget | 0 |
| Status-line fact recall | 0.812 |
| Planned facts written as done ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.111 |
| Home rank ran (checkpoints) | 2/2 |
| Home NDCG@5 | 0.922 |
| Home NDCG@5, recency-only order | 0.729 |
| Home top-3 precision (grade ≥ 2) | 0.833 |
| Home grade-3 recall@3 | 1.000 |
| Home gross inversions (grade gap ≥ 2) ↓ | 0 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Person linking accuracy | 0.182 |
| Person linking (cross-source people) | 0.250 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-h3 | 18 | 0.896 | 0.882 | 3/4 | 6/7 (0.857) | 0 | 0/3 | 0.844 |
| cp-final | 32 | 0.856 | 0.889 | 5/5 | 7/9 (0.778) | 0 | 1/6 | 1.000 |
