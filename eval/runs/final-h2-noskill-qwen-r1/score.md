### holdout-week-v2 · without-skills · qwen3.6-35b-a3b-nvfp4 (holdout, 46 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.964 |
| B-cubed R | 0.410 |
| B-cubed F1 | 0.575 |
| Link P (item→event, 1:1 mapped) | 0.690 |
| Link R | 0.492 |
| Link F1 | 0.574 |
| Hard-decoy leakage ↓ | 0.083 |
| Easy-decoy leakage ↓ | n/a |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 1/2 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 15 |
| Gold events | 7 |
| Questions asked | 6 |
| Same-event questions | 5 |
| Same-event questions per 100 items | 10.870 |
| Max same-event questions per day | 1 |
| Useful asks (provisional placement was wrong) | 0.800 |
| Questions whose true answer is yes | 0.667 |
| Asks suppressed by budget | 4 |
| Status-line fact recall | 0.126 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.156 |
| Home rank ran (checkpoints) | 6/6 |
| Home NDCG@5 | 0.814 |
| Home NDCG@5, recency-only order | 0.708 |
| Home top-3 precision (grade ≥ 2) | 0.778 |
| Home grade-3 recall@3 | 0.472 |
| Home gross inversions (grade gap ≥ 2) ↓ | 1 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.402 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 14.000 |
| Status line width p90 (added) | 20.500 |
| Status line width max (added) | 22.000 |
| Facts repeating their own date in the text ↓ (added) | 1 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.279 |
| Person linking (cross-source people) | 0.279 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp1_mon_night | 8 | 0.838 | 0.750 | 5/6 | 4/11 (0.364) | 0 | 0/0 | 1.073 |
| cp2_tue_night | 17 | 0.633 | 0.649 | 8/7 | 1/13 (0.077) | 0 | 0/2 | 0.883 |
| cp3_wed_night | 26 | 0.653 | 0.642 | 11/7 | 3/13 (0.231) | 0 | 0/4 | 0.964 |
| cp4_thu_night | 34 | 0.678 | 0.667 | 11/7 | 2/16 (0.125) | 0 | 2/8 | 0.723 |
| cp5_fri_evening | 40 | 0.615 | 0.612 | 14/7 | 1/17 (0.059) | 0 | 2/14 | 0.545 |
| cp6_sun_night | 46 | 0.575 | 0.574 | 15/7 | 0/17 (0.000) | 0 | 3/17 | 0.694 |
