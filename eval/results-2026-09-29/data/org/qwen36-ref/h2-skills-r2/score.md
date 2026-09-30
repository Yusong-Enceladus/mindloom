### holdout-week-v2 · skills · qwen3.6-35b-a3b-nvfp4 (holdout, 46 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.886 |
| B-cubed R | 0.587 |
| B-cubed F1 | 0.706 |
| Link P (item→event, 1:1 mapped) | 0.796 |
| Link R | 0.661 |
| Link F1 | 0.722 |
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
| Predicted events | 13 |
| Gold events | 7 |
| Questions asked | 4 |
| Same-event questions | 4 |
| Same-event questions per 100 items | 8.700 |
| Max same-event questions per day | 2 |
| Useful asks (provisional placement was wrong) | 0.500 |
| Questions whose true answer is yes | 0.500 |
| Asks suppressed by budget | 1 |
| Status-line fact recall | 0.218 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.022 |
| Home rank ran (checkpoints) | 6/6 |
| Home NDCG@5 | 0.859 |
| Home NDCG@5, recency-only order | 0.802 |
| Home top-3 precision (grade ≥ 2) | 0.833 |
| Home grade-3 recall@3 | 0.778 |
| Home gross inversions (grade gap ≥ 2) ↓ | 2 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.598 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 13.000 |
| Status line width p90 (added) | 18.500 |
| Status line width max (added) | 22.000 |
| Facts repeating their own date in the text ↓ (added) | 21 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.291 |
| Person linking (cross-source people) | 0.291 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp1_mon_night | 8 | 0.821 | 0.875 | 6/6 | 2/11 (0.182) | 0 | 0/0 | 1.099 |
| cp2_tue_night | 17 | 0.675 | 0.769 | 9/7 | 2/13 (0.154) | 0 | 0/2 | 0.795 |
| cp3_wed_night | 26 | 0.731 | 0.764 | 9/7 | 2/13 (0.154) | 0 | 0/4 | 0.924 |
| cp4_thu_night | 34 | 0.736 | 0.778 | 10/7 | 5/16 (0.312) | 0 | 0/8 | 0.795 |
| cp5_fri_evening | 40 | 0.695 | 0.727 | 11/7 | 5/17 (0.294) | 0 | 0/14 | 0.775 |
| cp6_sun_night | 46 | 0.706 | 0.722 | 13/7 | 3/17 (0.176) | 0 | 1/17 | 0.762 |
