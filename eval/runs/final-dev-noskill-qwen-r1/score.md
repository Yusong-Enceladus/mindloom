### dev-week-v1 · without-skills · qwen3.6-35b-a3b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.965 |
| B-cubed R | 0.546 |
| B-cubed F1 | 0.697 |
| Link P (item→event, 1:1 mapped) | 0.813 |
| Link R | 0.642 |
| Link F1 | 0.718 |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 3 |
| Unfiled precision (share that is noise) | 0.571 |
| Decoy seed kept apart | 2/2 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 15 |
| Gold events | 9 |
| Questions asked | 7 |
| Same-event questions | 4 |
| Same-event questions per 100 items | 4.880 |
| Max same-event questions per day | 2 |
| Useful asks (provisional placement was wrong) | 0.500 |
| Questions whose true answer is yes | 0.857 |
| Asks suppressed by budget | 4 |
| Status-line fact recall | 0.327 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.050 |
| Home rank ran (checkpoints) | 4/4 |
| Home NDCG@5 | 0.633 |
| Home NDCG@5, recency-only order | 0.550 |
| Home top-3 precision (grade ≥ 2) | 0.417 |
| Home grade-3 recall@3 | 0.458 |
| Home gross inversions (grade gap ≥ 2) ↓ | 5 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.731 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 14.000 |
| Status line width p90 (added) | 16.500 |
| Status line width max (added) | 22.000 |
| Facts repeating their own date in the text ↓ (added) | 0 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.306 |
| Person linking (cross-source people) | 0.306 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.827 | 0.815 | 9/9 | 2/11 (0.182) | 0 | 0/0 | 0.728 |
| cp-d3 | 38 | 0.803 | 0.779 | 10/9 | 4/10 (0.400) | 0 | 0/3 | 0.573 |
| cp-d5 | 64 | 0.729 | 0.748 | 12/9 | 5/15 (0.333) | 0 | 0/7 | 0.775 |
| cp-final | 82 | 0.697 | 0.718 | 15/9 | 6/16 (0.375) | 0 | 1/10 | 0.455 |
