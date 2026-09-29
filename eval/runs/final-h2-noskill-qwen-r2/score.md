### holdout-week-v2 · without-skills · qwen3.6-35b-a3b-nvfp4 (holdout, 46 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.940 |
| B-cubed R | 0.495 |
| B-cubed F1 | 0.649 |
| Link P (item→event, 1:1 mapped) | 0.833 |
| Link R | 0.593 |
| Link F1 | 0.693 |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | n/a |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 2/2 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 9 |
| Gold events | 7 |
| Questions asked | 4 |
| Same-event questions | 4 |
| Same-event questions per 100 items | 8.700 |
| Max same-event questions per day | 2 |
| Useful asks (provisional placement was wrong) | 0.000 |
| Questions whose true answer is yes | 0.250 |
| Asks suppressed by budget | 2 |
| Status-line fact recall | 0.092 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.067 |
| Home rank ran (checkpoints) | 6/6 |
| Home NDCG@5 | 0.797 |
| Home NDCG@5, recency-only order | 0.815 |
| Home top-3 precision (grade ≥ 2) | 0.889 |
| Home grade-3 recall@3 | 0.472 |
| Home gross inversions (grade gap ≥ 2) ↓ | 2 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.460 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 15.000 |
| Status line width p90 (added) | 18.000 |
| Status line width max (added) | 21.000 |
| Facts repeating their own date in the text ↓ (added) | 5 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.291 |
| Person linking (cross-source people) | 0.291 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp1_mon_night | 8 | 0.742 | 0.667 | 4/6 | 2/11 (0.182) | 0 | 0/0 | 0.887 |
| cp2_tue_night | 17 | 0.567 | 0.629 | 6/7 | 1/13 (0.077) | 0 | 0/2 | 0.598 |
| cp3_wed_night | 26 | 0.713 | 0.717 | 9/7 | 0/13 (0.000) | 0 | 0/4 | 1.014 |
| cp4_thu_night | 34 | 0.723 | 0.754 | 9/7 | 2/16 (0.125) | 0 | 1/8 | 0.757 |
| cp5_fri_evening | 40 | 0.670 | 0.706 | 9/7 | 2/17 (0.118) | 0 | 1/14 | 1.000 |
| cp6_sun_night | 46 | 0.649 | 0.693 | 9/7 | 1/17 (0.059) | 0 | 1/17 | 0.528 |
