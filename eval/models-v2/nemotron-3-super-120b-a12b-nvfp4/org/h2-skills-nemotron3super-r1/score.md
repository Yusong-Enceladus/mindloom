### holdout-week-v2 · skills · nemotron-3-super-120b-a12b-nvfp4 (holdout, 46 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.659 |
| B-cubed R | 0.813 |
| B-cubed F1 | 0.728 |
| Link P (item→event, 1:1 mapped) | 0.702 |
| Link R | 0.559 |
| Link F1 | 0.623 |
| Segment Link P (added; items with segment truth) | n/a |
| Segment Link R (added) | n/a |
| Segment Link F1 (added) | n/a |
| Items filed by segments (pred) | n/a |
| Items with 2+ gold segments | n/a |
| Hard-decoy leakage ↓ | 0.778 |
| Easy-decoy leakage ↓ | n/a |
| Noise abstention (= noise unfiled rate) | 0.250 |
| Noise as its own one-item event | 0.750 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 0/2 |
| Matters absorbed into another event ↓ | ev_peggy_quote,ev_q3_rebate,ev_wuqing_samples |
| Predicted events | 7 |
| Gold events | 7 |
| Questions asked | 0 |
| Same-event questions | 0 |
| Same-event questions per 100 items | 0.000 |
| Max same-event questions per day | 0 |
| Useful asks (provisional placement was wrong) | n/a |
| Questions whose true answer is yes | n/a |
| Asks suppressed by budget | 0 |
| Status-line fact recall | 0.126 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.034 |
| Home rank ran (checkpoints) | 6/6 |
| Home NDCG@5 | 0.762 |
| Home NDCG@5, recency-only order | 0.718 |
| Home top-3 precision (grade ≥ 2) | 0.944 |
| Home grade-3 recall@3 | 0.528 |
| Home gross inversions (grade gap ≥ 2) ↓ | 1 |
| Noise cards in home top 5 ↓ | 5 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.322 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 17.000 |
| Status line width p90 (added) | 20.000 |
| Status line width max (added) | 20.000 |
| Facts repeating their own date in the text ↓ (added) | 13 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.233 |
| Person linking (cross-source people) | 0.233 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp1_mon_night | 8 | 0.636 | 0.500 | 2/6 | 0/11 (0.000) | 0 | 0/0 | 0.657 |
| cp2_tue_night | 17 | 0.751 | 0.579 | 4/7 | 1/13 (0.077) | 0 | 0/2 | 0.694 |
| cp3_wed_night | 26 | 0.678 | 0.582 | 6/7 | 0/13 (0.000) | 0 | 1/4 | 0.807 |
| cp4_thu_night | 34 | 0.700 | 0.611 | 7/7 | 2/16 (0.125) | 0 | 0/5 | 0.906 |
| cp5_fri_evening | 40 | 0.710 | 0.614 | 7/7 | 4/17 (0.235) | 0 | 0/9 | 0.664 |
| cp6_sun_night | 46 | 0.728 | 0.623 | 7/7 | 4/17 (0.235) | 0 | 0/9 | 0.843 |
