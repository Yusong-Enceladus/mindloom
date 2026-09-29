### holdout-week-v2 · without-skills · qwen3.6-35b-a3b-nvfp4 (holdout, 46 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.912 |
| B-cubed R | 0.505 |
| B-cubed F1 | 0.650 |
| Link P (item→event, 1:1 mapped) | 0.725 |
| Link R | 0.492 |
| Link F1 | 0.586 |
| Hard-decoy leakage ↓ | 0.417 |
| Easy-decoy leakage ↓ | n/a |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 2 |
| Unfiled precision (share that is noise) | 0.667 |
| Decoy seed kept apart | 1/2 |
| Matters absorbed into another event ↓ | ev_peggy_quote |
| Predicted events | 10 |
| Gold events | 7 |
| Questions asked | 6 |
| Same-event questions | 5 |
| Same-event questions per 100 items | 10.870 |
| Max same-event questions per day | 1 |
| Useful asks (provisional placement was wrong) | 0.200 |
| Questions whose true answer is yes | 0.333 |
| Asks suppressed by budget | 3 |
| Status-line fact recall | 0.069 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.077 |
| Home rank ran (checkpoints) | 6/6 |
| Home NDCG@5 | 0.635 |
| Home NDCG@5, recency-only order | 0.603 |
| Home top-3 precision (grade ≥ 2) | 0.778 |
| Home grade-3 recall@3 | 0.278 |
| Home gross inversions (grade gap ≥ 2) ↓ | 0 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Person linking accuracy | 0.174 |
| Person linking (cross-source people) | 0.174 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp1_mon_night | 8 | 0.824 | 0.667 | 3/6 | 1/11 (0.091) | 0 | 0/0 | 0.713 |
| cp2_tue_night | 17 | 0.617 | 0.571 | 5/7 | 0/13 (0.000) | 0 | 0/2 | 0.588 |
| cp3_wed_night | 26 | 0.547 | 0.458 | 7/7 | 1/13 (0.077) | 0 | 0/3 | 0.567 |
| cp4_thu_night | 34 | 0.674 | 0.606 | 8/7 | 0/16 (0.000) | 0 | 1/7 | 0.767 |
| cp5_fri_evening | 40 | 0.647 | 0.602 | 10/7 | 1/17 (0.059) | 0 | 1/13 | 0.507 |
| cp6_sun_night | 46 | 0.650 | 0.586 | 10/7 | 3/17 (0.176) | 0 | 1/14 | 0.668 |
