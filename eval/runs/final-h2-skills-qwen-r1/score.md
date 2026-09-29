### holdout-week-v2 · skills · qwen3.6-35b-a3b-nvfp4 (holdout, 46 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.815 |
| B-cubed R | 0.753 |
| B-cubed F1 | 0.782 |
| Link P (item→event, 1:1 mapped) | 0.814 |
| Link R | 0.593 |
| Link F1 | 0.686 |
| Hard-decoy leakage ↓ | 0.250 |
| Easy-decoy leakage ↓ | n/a |
| Noise abstention (= noise unfiled rate) | 0.750 |
| Noise as its own one-item event | 0.250 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 1/2 |
| Matters absorbed into another event ↓ | ev_q3_rebate |
| Predicted events | 6 |
| Gold events | 7 |
| Questions asked | 3 |
| Same-event questions | 3 |
| Same-event questions per 100 items | 6.520 |
| Max same-event questions per day | 1 |
| Useful asks (provisional placement was wrong) | 0.333 |
| Questions whose true answer is yes | 0.333 |
| Asks suppressed by budget | 0 |
| Status-line fact recall | 0.184 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 1 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.000 |
| Home rank ran (checkpoints) | 6/6 |
| Home NDCG@5 | 0.932 |
| Home NDCG@5, recency-only order | 0.886 |
| Home top-3 precision (grade ≥ 2) | 1.000 |
| Home grade-3 recall@3 | 0.694 |
| Home gross inversions (grade gap ≥ 2) ↓ | 0 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.517 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 13.500 |
| Status line width p90 (added) | 20.000 |
| Status line width max (added) | 20.000 |
| Facts repeating their own date in the text ↓ (added) | 8 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.291 |
| Person linking (cross-source people) | 0.291 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp1_mon_night | 8 | 0.838 | 0.750 | 5/6 | 0/11 (0.000) | 0 | 0/0 | 1.089 |
| cp2_tue_night | 17 | 0.763 | 0.684 | 6/7 | 2/13 (0.154) | 0 | 0/2 | 1.000 |
| cp3_wed_night | 26 | 0.810 | 0.704 | 6/7 | 2/13 (0.154) | 0 | 0/4 | 0.852 |
| cp4_thu_night | 34 | 0.815 | 0.714 | 6/7 | 2/16 (0.125) | 0 | 0/5 | 0.870 |
| cp5_fri_evening | 40 | 0.799 | 0.698 | 6/7 | 5/17 (0.294) | 0 | 0/9 | 1.000 |
| cp6_sun_night | 46 | 0.782 | 0.686 | 6/7 | 5/17 (0.294) | 0 | 0/10 | 0.784 |
