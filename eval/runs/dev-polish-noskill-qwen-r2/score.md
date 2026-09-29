### dev-week-v1 · without-skills · qwen3.6-35b-a3b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.918 |
| B-cubed R | 0.494 |
| B-cubed F1 | 0.643 |
| Link P (item→event, 1:1 mapped) | 0.795 |
| Link R | 0.611 |
| Link F1 | 0.690 |
| Hard-decoy leakage ↓ | 0.143 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 5 |
| Unfiled precision (share that is noise) | 0.444 |
| Decoy seed kept apart | 2/2 |
| Matters absorbed into another event ↓ | ev_grinder |
| Predicted events | 15 |
| Gold events | 9 |
| Questions asked | 7 |
| Same-event questions | 4 |
| Same-event questions per 100 items | 4.880 |
| Max same-event questions per day | 1 |
| Useful asks (provisional placement was wrong) | 0.000 |
| Questions whose true answer is yes | 0.714 |
| Asks suppressed by budget | 7 |
| Status-line fact recall | 0.250 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.000 |
| Home rank ran (checkpoints) | 4/4 |
| Home NDCG@5 | 0.696 |
| Home NDCG@5, recency-only order | 0.651 |
| Home top-3 precision (grade ≥ 2) | 0.750 |
| Home grade-3 recall@3 | 0.583 |
| Home gross inversions (grade gap ≥ 2) ↓ | 5 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.615 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 15.500 |
| Status line width p90 (added) | 20.500 |
| Status line width max (added) | 21.500 |
| Facts repeating their own date in the text ↓ (added) | 1 |
| Person linking accuracy | 0.306 |
| Person linking (cross-source people) | 0.306 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.827 | 0.815 | 9/9 | 2/11 (0.182) | 0 | 0/0 | 0.714 |
| cp-d3 | 38 | 0.803 | 0.779 | 10/9 | 0/10 (0.000) | 0 | 0/3 | 0.693 |
| cp-d5 | 64 | 0.704 | 0.733 | 12/9 | 4/15 (0.267) | 0 | 0/7 | 0.801 |
| cp-final | 82 | 0.643 | 0.690 | 15/9 | 7/16 (0.438) | 0 | 0/10 | 0.574 |
