### holdout-week-v2 · skills · muse-glimmer-org (holdout, 46 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.955 |
| B-cubed R | 0.737 |
| B-cubed F1 | 0.832 |
| Link P (item→event, 1:1 mapped) | 0.920 |
| Link R | 0.780 |
| Link F1 | 0.844 |
| Segment Link P (added; items with segment truth) | n/a |
| Segment Link R (added) | n/a |
| Segment Link F1 (added) | n/a |
| Items filed by segments (pred) | n/a |
| Items with 2+ gold segments | n/a |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | n/a |
| Noise abstention (= noise unfiled rate) | 0.500 |
| Noise as its own one-item event | 0.500 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 2/2 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 10 |
| Gold events | 7 |
| Questions asked | 3 |
| Same-event questions | 3 |
| Same-event questions per 100 items | 6.520 |
| Max same-event questions per day | 1 |
| Useful asks (provisional placement was wrong) | 0.667 |
| Questions whose true answer is yes | 0.667 |
| Asks suppressed by budget | 0 |
| Status-line fact recall | 0.299 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 1 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.067 |
| Home rank ran (checkpoints) | 6/6 |
| Home NDCG@5 | 0.911 |
| Home NDCG@5, recency-only order | 0.755 |
| Home top-3 precision (grade ≥ 2) | 1.000 |
| Home grade-3 recall@3 | 0.833 |
| Home gross inversions (grade gap ≥ 2) ↓ | 1 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.644 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 13.000 |
| Status line width p90 (added) | 16.000 |
| Status line width max (added) | 18.000 |
| Facts repeating their own date in the text ↓ (added) | 26 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.291 |
| Person linking (cross-source people) | 0.291 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp1_mon_night | 8 | 0.920 | 0.875 | 5/6 | 3/11 (0.273) | 0 | 0/0 | 1.000 |
| cp2_tue_night | 17 | 0.871 | 0.850 | 7/7 | 4/13 (0.308) | 0 | 0/2 | 1.000 |
| cp3_wed_night | 26 | 0.891 | 0.893 | 8/7 | 4/13 (0.308) | 0 | 0/4 | 0.982 |
| cp4_thu_night | 34 | 0.837 | 0.849 | 10/7 | 5/16 (0.312) | 0 | 0/8 | 0.742 |
| cp5_fri_evening | 40 | 0.804 | 0.809 | 10/7 | 5/17 (0.294) | 0 | 1/14 | 0.966 |
| cp6_sun_night | 46 | 0.832 | 0.844 | 10/7 | 5/17 (0.294) | 0 | 2/17 | 0.777 |
