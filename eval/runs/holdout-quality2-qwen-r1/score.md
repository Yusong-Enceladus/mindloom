### holdout-week-v1 · skills · qwen3.6-35b-a3b-nvfp4 (holdout, 32 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.816 |
| B-cubed R | 0.659 |
| B-cubed F1 | 0.729 |
| Link P (item→event, 1:1 mapped) | 0.767 |
| Link R | 0.697 |
| Link F1 | 0.730 |
| Hard-decoy leakage ↓ | 0.167 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 1/2 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 8 |
| Gold events | 5 |
| Questions asked | 3 |
| Same-event questions | 3 |
| Same-event questions per 100 items | 9.380 |
| Max same-event questions per day | 2 |
| Useful asks (provisional placement was wrong) | 0.667 |
| Questions whose true answer is yes | 0.333 |
| Asks suppressed by budget | 1 |
| Status-line fact recall | 0.750 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.111 |
| Home rank ran (checkpoints) | 2/2 |
| Home NDCG@5 | 0.613 |
| Home NDCG@5, recency-only order | 0.471 |
| Home top-3 precision (grade ≥ 2) | 0.333 |
| Home grade-3 recall@3 | 0.500 |
| Home gross inversions (grade gap ≥ 2) ↓ | 1 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Person linking accuracy | 0.182 |
| Person linking (cross-source people) | 0.250 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-h3 | 18 | 0.896 | 0.882 | 3/4 | 5/7 (0.714) | 0 | 0/3 | 0.868 |
| cp-final | 32 | 0.729 | 0.730 | 8/5 | 7/9 (0.778) | 0 | 1/6 | 0.357 |
