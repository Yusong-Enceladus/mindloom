### holdout-week-v2 · skills · mistral-small4 (holdout, 46 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.802 |
| B-cubed R | 0.343 |
| B-cubed F1 | 0.480 |
| Link P (item→event, 1:1 mapped) | 0.511 |
| Link R | 0.407 |
| Link F1 | 0.453 |
| Segment Link P (added; items with segment truth) | n/a |
| Segment Link R (added) | n/a |
| Segment Link F1 (added) | n/a |
| Items filed by segments (pred) | n/a |
| Items with 2+ gold segments | n/a |
| Hard-decoy leakage ↓ | 0.215 |
| Easy-decoy leakage ↓ | n/a |
| Noise abstention (= noise unfiled rate) | 0.250 |
| Noise as its own one-item event | 0.500 |
| Noise inside a real event ↓ | 0.250 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 0/2 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 19 |
| Gold events | 7 |
| Questions asked | 4 |
| Same-event questions | 4 |
| Same-event questions per 100 items | 8.700 |
| Max same-event questions per day | 2 |
| Useful asks (provisional placement was wrong) | 0.500 |
| Questions whose true answer is yes | 0.500 |
| Asks suppressed by budget | 11 |
| Status-line fact recall | 0.218 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 1 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.163 |
| Home rank ran (checkpoints) | 6/6 |
| Home NDCG@5 | 0.723 |
| Home NDCG@5, recency-only order | 0.701 |
| Home top-3 precision (grade ≥ 2) | 0.722 |
| Home grade-3 recall@3 | 0.444 |
| Home gross inversions (grade gap ≥ 2) ↓ | 5 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.310 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 18.000 |
| Status line width p90 (added) | 20.500 |
| Status line width max (added) | 23.000 |
| Facts repeating their own date in the text ↓ (added) | 5 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.291 |
| Person linking (cross-source people) | 0.291 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp1_mon_night | 8 | 0.725 | 0.706 | 6/6 | 1/11 (0.091) | 0 | 0/0 | 0.954 |
| cp2_tue_night | 17 | 0.651 | 0.615 | 8/7 | 5/13 (0.385) | 0 | 0/2 | 1.000 |
| cp3_wed_night | 26 | 0.630 | 0.526 | 13/7 | 2/13 (0.154) | 0 | 1/4 | 0.553 |
| cp4_thu_night | 34 | 0.564 | 0.514 | 16/7 | 3/16 (0.188) | 0 | 2/8 | 0.629 |
| cp5_fri_evening | 40 | 0.541 | 0.511 | 17/7 | 6/17 (0.353) | 0 | 2/13 | 0.683 |
| cp6_sun_night | 46 | 0.480 | 0.453 | 19/7 | 2/17 (0.118) | 0 | 2/16 | 0.520 |
