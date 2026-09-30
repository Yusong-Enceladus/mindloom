### holdout-week-v2 · skills · glm47-flash (holdout, 46 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.919 |
| B-cubed R | 0.641 |
| B-cubed F1 | 0.755 |
| Link P (item→event, 1:1 mapped) | 0.745 |
| Link R | 0.593 |
| Link F1 | 0.660 |
| Segment Link P (added; items with segment truth) | n/a |
| Segment Link R (added) | n/a |
| Segment Link F1 (added) | n/a |
| Items filed by segments (pred) | n/a |
| Items with 2+ gold segments | n/a |
| Hard-decoy leakage ↓ | 0.417 |
| Easy-decoy leakage ↓ | n/a |
| Noise abstention (= noise unfiled rate) | 0.750 |
| Noise as its own one-item event | 0.250 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 1/2 |
| Matters absorbed into another event ↓ | ev_peggy_quote |
| Predicted events | 11 |
| Gold events | 7 |
| Questions asked | 4 |
| Same-event questions | 4 |
| Same-event questions per 100 items | 8.700 |
| Max same-event questions per day | 2 |
| Useful asks (provisional placement was wrong) | 0.667 |
| Questions whose true answer is yes | 0.667 |
| Asks suppressed by budget | 1 |
| Status-line fact recall | 0.184 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 1 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.150 |
| Home rank ran (checkpoints) | 6/6 |
| Home NDCG@5 | 0.742 |
| Home NDCG@5, recency-only order | 0.681 |
| Home top-3 precision (grade ≥ 2) | 0.833 |
| Home grade-3 recall@3 | 0.444 |
| Home gross inversions (grade gap ≥ 2) ↓ | 0 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.414 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 13.500 |
| Status line width p90 (added) | 17.000 |
| Status line width max (added) | 19.000 |
| Facts repeating their own date in the text ↓ (added) | 7 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 6 |
| Person linking accuracy | 0.291 |
| Person linking (cross-source people) | 0.291 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp1_mon_night | 8 | 0.804 | 0.750 | 6/6 | 3/11 (0.273) | 0 | 0/0 | 0.898 |
| cp2_tue_night | 17 | 0.698 | 0.615 | 8/7 | 2/13 (0.154) | 0 | 1/2 | 0.899 |
| cp3_wed_night | 26 | 0.713 | 0.582 | 10/7 | 3/13 (0.231) | 0 | 1/4 | 0.916 |
| cp4_thu_night | 34 | 0.757 | 0.648 | 10/7 | 2/16 (0.125) | 0 | 2/7 | 0.580 |
| cp5_fri_evening | 40 | 0.750 | 0.667 | 10/7 | 2/17 (0.118) | 0 | 1/13 | 0.492 |
| cp6_sun_night | 46 | 0.755 | 0.660 | 11/7 | 4/17 (0.235) | 0 | 1/14 | 0.668 |
