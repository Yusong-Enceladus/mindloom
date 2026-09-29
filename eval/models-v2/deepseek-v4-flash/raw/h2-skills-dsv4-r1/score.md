### holdout-week-v2 · skills · deepseek-v4-flash (holdout, 46 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.828 |
| B-cubed R | 0.662 |
| B-cubed F1 | 0.735 |
| Link P (item→event, 1:1 mapped) | 0.792 |
| Link R | 0.644 |
| Link F1 | 0.710 |
| Segment Link P (added; items with segment truth) | n/a |
| Segment Link R (added) | n/a |
| Segment Link F1 (added) | n/a |
| Items filed by segments (pred) | n/a |
| Items with 2+ gold segments | n/a |
| Hard-decoy leakage ↓ | 0.417 |
| Easy-decoy leakage ↓ | n/a |
| Noise abstention (= noise unfiled rate) | 0.500 |
| Noise as its own one-item event | 0.500 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 1/2 |
| Matters absorbed into another event ↓ | ev_peggy_quote |
| Predicted events | 9 |
| Gold events | 7 |
| Questions asked | 2 |
| Same-event questions | 2 |
| Same-event questions per 100 items | 4.350 |
| Max same-event questions per day | 1 |
| Useful asks (provisional placement was wrong) | 1.000 |
| Questions whose true answer is yes | 0.500 |
| Asks suppressed by budget | 0 |
| Status-line fact recall | 0.287 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 1 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.000 |
| Home rank ran (checkpoints) | 6/6 |
| Home NDCG@5 | 0.960 |
| Home NDCG@5, recency-only order | 0.833 |
| Home top-3 precision (grade ≥ 2) | 1.000 |
| Home grade-3 recall@3 | 0.556 |
| Home gross inversions (grade gap ≥ 2) ↓ | 0 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.609 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 13.000 |
| Status line width p90 (added) | 17.000 |
| Status line width max (added) | 20.500 |
| Facts repeating their own date in the text ↓ (added) | 13 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.291 |
| Person linking (cross-source people) | 0.291 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp1_mon_night | 8 | 0.838 | 0.750 | 5/6 | 2/11 (0.182) | 0 | 0/0 | 1.043 |
| cp2_tue_night | 17 | 0.751 | 0.718 | 6/7 | 3/13 (0.231) | 0 | 0/2 | 0.885 |
| cp3_wed_night | 26 | 0.747 | 0.691 | 7/7 | 3/13 (0.231) | 0 | 0/4 | 0.840 |
| cp4_thu_night | 34 | 0.724 | 0.694 | 9/7 | 5/16 (0.312) | 0 | 0/7 | 1.167 |
| cp5_fri_evening | 40 | 0.712 | 0.705 | 9/7 | 6/17 (0.353) | 0 | 0/13 | 0.982 |
| cp6_sun_night | 46 | 0.735 | 0.710 | 9/7 | 6/17 (0.353) | 0 | 0/14 | 0.844 |
