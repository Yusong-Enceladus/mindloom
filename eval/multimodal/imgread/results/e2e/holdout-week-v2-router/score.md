### holdout-week-v2 · skills · qwen3.6-35b-a3b-nvfp4 (holdout, 46 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.859 |
| B-cubed R | 0.760 |
| B-cubed F1 | 0.807 |
| Link P (item→event, 1:1 mapped) | 0.894 |
| Link R | 0.712 |
| Link F1 | 0.792 |
| Segment Link P (added; items with segment truth) | n/a |
| Segment Link R (added) | n/a |
| Segment Link F1 (added) | n/a |
| Items filed by segments (pred) | n/a |
| Items with 2+ gold segments | n/a |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | n/a |
| Noise abstention (= noise unfiled rate) | 0.750 |
| Noise as its own one-item event | 0.250 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 2/2 |
| Matters absorbed into another event ↓ | ev_q3_rebate |
| Predicted events | 7 |
| Gold events | 7 |
| Questions asked | 2 |
| Same-event questions | 2 |
| Same-event questions per 100 items | 4.350 |
| Max same-event questions per day | 1 |
| Useful asks (provisional placement was wrong) | 0.000 |
| Questions whose true answer is yes | 0.000 |
| Asks suppressed by budget | 0 |
| Status-line fact recall | 0.195 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 3 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.057 |
| Home rank ran (checkpoints) | 6/6 |
| Home NDCG@5 | 1.017 |
| Home NDCG@5, recency-only order | 0.865 |
| Home top-3 precision (grade ≥ 2) | 1.000 |
| Home grade-3 recall@3 | 0.722 |
| Home gross inversions (grade gap ≥ 2) ↓ | 0 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.575 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 13.000 |
| Status line width p90 (added) | 15.000 |
| Status line width max (added) | 17.000 |
| Facts repeating their own date in the text ↓ (added) | 10 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.407 |
| Person linking (cross-source people) | 0.407 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp1_mon_night | 8 | 0.838 | 0.750 | 5/6 | 1/11 (0.091) | 0 | 0/0 | 1.043 |
| cp2_tue_night | 17 | 0.746 | 0.737 | 7/7 | 1/13 (0.077) | 0 | 0/2 | 1.000 |
| cp3_wed_night | 26 | 0.819 | 0.778 | 7/7 | 2/13 (0.154) | 0 | 0/4 | 1.067 |
| cp4_thu_night | 34 | 0.798 | 0.761 | 8/7 | 2/16 (0.125) | 0 | 1/6 | 0.870 |
| cp5_fri_evening | 40 | 0.785 | 0.744 | 7/7 | 5/17 (0.294) | 0 | 0/10 | 1.000 |
| cp6_sun_night | 46 | 0.807 | 0.792 | 7/7 | 6/17 (0.353) | 0 | 1/13 | 1.120 |
