### holdout-week-v2 · skills · nano-omni-org (holdout, 46 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.777 |
| B-cubed R | 0.265 |
| B-cubed F1 | 0.395 |
| Link P (item→event, 1:1 mapped) | 0.370 |
| Link R | 0.339 |
| Link F1 | 0.354 |
| Segment Link P (added; items with segment truth) | n/a |
| Segment Link R (added) | n/a |
| Segment Link F1 (added) | n/a |
| Items filed by segments (pred) | n/a |
| Items with 2+ gold segments | n/a |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | n/a |
| Noise abstention (= noise unfiled rate) | 0.250 |
| Noise as its own one-item event | 0.500 |
| Noise inside a real event ↓ | 0.250 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 2/2 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 34 |
| Gold events | 7 |
| Questions asked | 6 |
| Same-event questions | 6 |
| Same-event questions per 100 items | 13.040 |
| Max same-event questions per day | 2 |
| Useful asks (provisional placement was wrong) | 0.250 |
| Questions whose true answer is yes | 0.250 |
| Asks suppressed by budget | 25 |
| Status-line fact recall | 0.080 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.070 |
| Home rank ran (checkpoints) | 6/6 |
| Home NDCG@5 | 0.537 |
| Home NDCG@5, recency-only order | 0.486 |
| Home top-3 precision (grade ≥ 2) | 0.444 |
| Home grade-3 recall@3 | 0.194 |
| Home gross inversions (grade gap ≥ 2) ↓ | 36 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.207 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 15.500 |
| Status line width p90 (added) | 22.000 |
| Status line width max (added) | 24.000 |
| Facts repeating their own date in the text ↓ (added) | 2 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 15 |
| Person linking accuracy | 0.279 |
| Person linking (cross-source people) | 0.279 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp1_mon_night | 8 | 0.771 | 0.625 | 4/6 | 2/11 (0.182) | 0 | 0/0 | 0.917 |
| cp2_tue_night | 17 | 0.528 | 0.500 | 10/7 | 1/13 (0.077) | 0 | 0/2 | 0.873 |
| cp3_wed_night | 26 | 0.541 | 0.441 | 16/7 | 1/13 (0.077) | 0 | 0/4 | 0.404 |
| cp4_thu_night | 34 | 0.456 | 0.410 | 24/7 | 0/16 (0.000) | 0 | 1/8 | 0.955 |
| cp5_fri_evening | 40 | 0.409 | 0.362 | 28/7 | 1/17 (0.059) | 0 | 1/12 | 0.076 |
| cp6_sun_night | 46 | 0.395 | 0.354 | 34/7 | 2/17 (0.118) | 0 | 1/17 | 0.000 |
