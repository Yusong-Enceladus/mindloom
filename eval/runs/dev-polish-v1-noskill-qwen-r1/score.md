### dev-week-v1 · without-skills · qwen3.6-35b-a3b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.928 |
| B-cubed R | 0.513 |
| B-cubed F1 | 0.661 |
| Link P (item→event, 1:1 mapped) | 0.781 |
| Link R | 0.600 |
| Link F1 | 0.679 |
| Hard-decoy leakage ↓ | 0.250 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 5 |
| Unfiled precision (share that is noise) | 0.444 |
| Decoy seed kept apart | 1/2 |
| Matters absorbed into another event ↓ | ev_grinder |
| Predicted events | 15 |
| Gold events | 9 |
| Questions asked | 7 |
| Same-event questions | 4 |
| Same-event questions per 100 items | 4.880 |
| Max same-event questions per day | 2 |
| Useful asks (provisional placement was wrong) | 0.500 |
| Questions whose true answer is yes | 0.571 |
| Asks suppressed by budget | 5 |
| Status-line fact recall | 0.288 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.000 |
| Home rank ran (checkpoints) | 4/4 |
| Home NDCG@5 | 0.820 |
| Home NDCG@5, recency-only order | 0.578 |
| Home top-3 precision (grade ≥ 2) | 0.833 |
| Home grade-3 recall@3 | 0.521 |
| Home gross inversions (grade gap ≥ 2) ↓ | 0 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.538 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 15.000 |
| Status line width p90 (added) | 19.000 |
| Status line width max (added) | 23.000 |
| Facts repeating their own date in the text ↓ (added) | 6 |
| Person linking accuracy | 0.306 |
| Person linking (cross-source people) | 0.306 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.791 | 0.815 | 8/9 | 1/11 (0.091) | 0 | 0/0 | 1.000 |
| cp-d3 | 38 | 0.783 | 0.779 | 9/9 | 3/10 (0.300) | 0 | 0/3 | 0.974 |
| cp-d5 | 64 | 0.715 | 0.718 | 12/9 | 6/15 (0.400) | 0 | 0/7 | 0.740 |
| cp-final | 82 | 0.661 | 0.679 | 15/9 | 5/16 (0.312) | 0 | 0/10 | 0.564 |
