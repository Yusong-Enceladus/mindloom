### holdout-week-v2 · skills · qwen3.6-35b-a3b-nvfp4 (holdout, 46 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.814 |
| B-cubed R | 0.823 |
| B-cubed F1 | 0.818 |
| Link P (item→event, 1:1 mapped) | 0.830 |
| Link R | 0.661 |
| Link F1 | 0.736 |
| Segment Link P (added; items with segment truth) | n/a |
| Segment Link R (added) | n/a |
| Segment Link F1 (added) | n/a |
| Items filed by segments (pred) | n/a |
| Items with 2+ gold segments | n/a |
| Hard-decoy leakage ↓ | 0.333 |
| Easy-decoy leakage ↓ | n/a |
| Noise abstention (= noise unfiled rate) | 0.750 |
| Noise as its own one-item event | 0.250 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 1/2 |
| Matters absorbed into another event ↓ | ev_peggy_quote,ev_q3_rebate |
| Predicted events | 6 |
| Gold events | 7 |
| Questions asked | 4 |
| Same-event questions | 4 |
| Same-event questions per 100 items | 8.700 |
| Max same-event questions per day | 2 |
| Useful asks (provisional placement was wrong) | 0.333 |
| Questions whose true answer is yes | 0.333 |
| Asks suppressed by budget | 0 |
| Status-line fact recall | 0.161 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.000 |
| Home rank ran (checkpoints) | 6/6 |
| Home NDCG@5 | 0.960 |
| Home NDCG@5, recency-only order | 0.896 |
| Home top-3 precision (grade ≥ 2) | 1.000 |
| Home grade-3 recall@3 | 0.611 |
| Home gross inversions (grade gap ≥ 2) ↓ | 0 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.356 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 13.000 |
| Status line width p90 (added) | 15.000 |
| Status line width max (added) | 18.000 |
| Facts repeating their own date in the text ↓ (added) | 2 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.279 |
| Person linking (cross-source people) | 0.279 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp1_mon_night | 8 | 0.838 | 0.750 | 5/6 | 0/11 (0.000) | 0 | 0/0 | 1.089 |
| cp2_tue_night | 17 | 0.789 | 0.718 | 6/7 | 0/13 (0.000) | 0 | 0/2 | 1.000 |
| cp3_wed_night | 26 | 0.824 | 0.727 | 6/7 | 2/13 (0.154) | 0 | 0/4 | 0.936 |
| cp4_thu_night | 34 | 0.826 | 0.732 | 6/7 | 2/16 (0.125) | 0 | 0/5 | 0.953 |
| cp5_fri_evening | 40 | 0.806 | 0.713 | 6/7 | 5/17 (0.294) | 0 | 0/9 | 1.000 |
| cp6_sun_night | 46 | 0.818 | 0.736 | 6/7 | 5/17 (0.294) | 0 | 0/10 | 0.784 |
