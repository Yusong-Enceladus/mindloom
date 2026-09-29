### holdout-week-v2 · skills · qwen3.6-35b-a3b-nvfp4 (holdout, 46 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.819 |
| B-cubed R | 0.716 |
| B-cubed F1 | 0.764 |
| Link P (item→event, 1:1 mapped) | 0.791 |
| Link R | 0.576 |
| Link F1 | 0.667 |
| Hard-decoy leakage ↓ | 0.250 |
| Easy-decoy leakage ↓ | n/a |
| Noise abstention (= noise unfiled rate) | 0.750 |
| Noise as its own one-item event | 0.250 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 1/2 |
| Matters absorbed into another event ↓ | ev_q3_rebate |
| Predicted events | 7 |
| Gold events | 7 |
| Questions asked | 4 |
| Same-event questions | 4 |
| Same-event questions per 100 items | 8.700 |
| Max same-event questions per day | 1 |
| Useful asks (provisional placement was wrong) | 0.500 |
| Questions whose true answer is yes | 0.500 |
| Asks suppressed by budget | 0 |
| Status-line fact recall | 0.310 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.062 |
| Home rank ran (checkpoints) | 6/6 |
| Home NDCG@5 | 0.908 |
| Home NDCG@5, recency-only order | 0.876 |
| Home top-3 precision (grade ≥ 2) | 1.000 |
| Home grade-3 recall@3 | 0.639 |
| Home gross inversions (grade gap ≥ 2) ↓ | 0 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Person linking accuracy | 0.186 |
| Person linking (cross-source people) | 0.186 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp1_mon_night | 8 | 0.838 | 0.750 | 5/6 | 4/11 (0.364) | 0 | 0/0 | 1.043 |
| cp2_tue_night | 17 | 0.763 | 0.684 | 6/7 | 3/13 (0.231) | 0 | 0/2 | 0.885 |
| cp3_wed_night | 26 | 0.810 | 0.704 | 6/7 | 3/13 (0.231) | 0 | 0/4 | 1.000 |
| cp4_thu_night | 34 | 0.815 | 0.714 | 6/7 | 5/16 (0.312) | 0 | 0/5 | 0.818 |
| cp5_fri_evening | 40 | 0.799 | 0.698 | 6/7 | 6/17 (0.353) | 0 | 0/9 | 0.948 |
| cp6_sun_night | 46 | 0.764 | 0.667 | 7/7 | 6/17 (0.353) | 0 | 2/12 | 0.754 |
