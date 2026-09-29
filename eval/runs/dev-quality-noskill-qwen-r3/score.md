### dev-week-v1 · without-skills · qwen3.6-35b-a3b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.915 |
| B-cubed R | 0.520 |
| B-cubed F1 | 0.663 |
| Link P (item→event, 1:1 mapped) | 0.822 |
| Link R | 0.632 |
| Link F1 | 0.714 |
| Hard-decoy leakage ↓ | 0.071 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 5 |
| Unfiled precision (share that is noise) | 0.444 |
| Decoy seed kept apart | 2/2 |
| Matters absorbed into another event ↓ | ev_grinder |
| Predicted events | 13 |
| Gold events | 9 |
| Questions asked | 6 |
| Same-event questions | 4 |
| Same-event questions per 100 items | 4.880 |
| Max same-event questions per day | 2 |
| Useful asks (provisional placement was wrong) | 0.000 |
| Questions whose true answer is yes | 1.000 |
| Asks suppressed by budget | 4 |
| Status-line fact recall | 0.404 |
| Planned facts written as done ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.100 |
| Home rank ran (checkpoints) | 4/4 |
| Home NDCG@5 | 0.705 |
| Home NDCG@5, recency-only order | 0.693 |
| Home top-3 precision (grade ≥ 2) | 0.750 |
| Home grade-3 recall@3 | 0.583 |
| Home gross inversions (grade gap ≥ 2) ↓ | 3 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Person linking accuracy | 0.083 |
| Person linking (cross-source people) | 0.083 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.791 | 0.778 | 10/9 | 3/11 (0.273) | 0 | 0/0 | 0.692 |
| cp-d3 | 38 | 0.715 | 0.675 | 11/9 | 1/10 (0.100) | 0 | 1/3 | 0.586 |
| cp-d5 | 64 | 0.674 | 0.702 | 12/9 | 7/15 (0.467) | 0 | 1/7 | 0.689 |
| cp-final | 82 | 0.663 | 0.714 | 13/9 | 10/16 (0.625) | 0 | 0/10 | 0.852 |
