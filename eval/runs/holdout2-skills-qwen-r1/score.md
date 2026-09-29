### holdout-week-v2 · skills · qwen3.6-35b-a3b-nvfp4 (holdout, 46 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.907 |
| B-cubed R | 0.565 |
| B-cubed F1 | 0.696 |
| Link P (item→event, 1:1 mapped) | 0.907 |
| Link R | 0.661 |
| Link F1 | 0.765 |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | n/a |
| Noise abstention (= noise unfiled rate) | 0.750 |
| Noise as its own one-item event | 0.250 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 2/2 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 8 |
| Gold events | 7 |
| Questions asked | 4 |
| Same-event questions | 4 |
| Same-event questions per 100 items | 8.700 |
| Max same-event questions per day | 2 |
| Useful asks (provisional placement was wrong) | 0.250 |
| Questions whose true answer is yes | 0.000 |
| Asks suppressed by budget | 0 |
| Status-line fact recall | 0.425 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.067 |
| Home rank ran (checkpoints) | 6/6 |
| Home NDCG@5 | 1.003 |
| Home NDCG@5, recency-only order | 0.983 |
| Home top-3 precision (grade ≥ 2) | 1.000 |
| Home grade-3 recall@3 | 0.778 |
| Home gross inversions (grade gap ≥ 2) ↓ | 0 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Person linking accuracy | 0.186 |
| Person linking (cross-source people) | 0.186 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp1_mon_night | 8 | 0.821 | 0.875 | 6/6 | 5/11 (0.455) | 0 | 0/0 | 1.089 |
| cp2_tue_night | 17 | 0.695 | 0.789 | 8/7 | 4/13 (0.308) | 0 | 0/2 | 0.885 |
| cp3_wed_night | 26 | 0.742 | 0.778 | 8/7 | 5/13 (0.385) | 0 | 0/4 | 1.112 |
| cp4_thu_night | 34 | 0.754 | 0.800 | 8/7 | 7/16 (0.438) | 0 | 0/8 | 0.971 |
| cp5_fri_evening | 40 | 0.717 | 0.767 | 8/7 | 8/17 (0.471) | 0 | 1/14 | 1.078 |
| cp6_sun_night | 46 | 0.696 | 0.765 | 8/7 | 8/17 (0.471) | 0 | 2/17 | 0.885 |
