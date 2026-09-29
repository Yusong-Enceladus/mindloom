### dev-week-v1 · without-skills · qwen3.6-35b-a3b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.978 |
| B-cubed R | 0.587 |
| B-cubed F1 | 0.733 |
| Link P (item→event, 1:1 mapped) | 0.863 |
| Link R | 0.663 |
| Link F1 | 0.750 |
| Hard-decoy leakage ↓ | 0.000 |
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
| Useful asks (provisional placement was wrong) | 0.500 |
| Questions whose true answer is yes | 0.667 |
| Asks suppressed by budget | 3 |
| Status-line fact recall | 0.442 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.050 |
| Home rank ran (checkpoints) | 4/4 |
| Home NDCG@5 | 0.705 |
| Home NDCG@5, recency-only order | 0.512 |
| Home top-3 precision (grade ≥ 2) | 0.667 |
| Home grade-3 recall@3 | 0.604 |
| Home gross inversions (grade gap ≥ 2) ↓ | 4 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Person linking accuracy | 0.083 |
| Person linking (cross-source people) | 0.083 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.887 | 0.889 | 8/9 | 2/11 (0.182) | 0 | 0/0 | 0.946 |
| cp-d3 | 38 | 0.840 | 0.831 | 9/9 | 4/10 (0.400) | 0 | 0/3 | 0.909 |
| cp-d5 | 64 | 0.756 | 0.779 | 12/9 | 8/15 (0.533) | 0 | 0/7 | 0.541 |
| cp-final | 82 | 0.733 | 0.750 | 13/9 | 9/16 (0.562) | 0 | 1/10 | 0.424 |
