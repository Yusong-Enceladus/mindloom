### holdout-week-v2 · baseline τ=0.6 · no LLM (holdout, 46 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.891 |
| B-cubed R | 0.207 |
| B-cubed F1 | 0.336 |
| Link P (item→event, 1:1 mapped) | 0.435 |
| Link R | 0.339 |
| Link F1 | 0.381 |
| Hard-decoy leakage ↓ | 0.028 |
| Easy-decoy leakage ↓ | n/a |
| Noise abstention (= noise unfiled rate) | 0.000 |
| Noise as its own one-item event | 1.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | n/a |
| Decoy seed kept apart | 2/2 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 30 |
| Gold events | 7 |
| Questions asked | 0 |
| Same-event questions | 0 |
| Same-event questions per 100 items | 0.000 |
| Max same-event questions per day | 0 |
| Useful asks (provisional placement was wrong) | n/a |
| Questions whose true answer is yes | n/a |
| Asks suppressed by budget | 0 |
| Status-line fact recall | 0.000 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | n/a |
| Home rank ran (checkpoints) | 0/6 |
| Home NDCG@5 | n/a |
| Home NDCG@5, recency-only order | 0.408 |
| Home top-3 precision (grade ≥ 2) | n/a |
| Home grade-3 recall@3 | n/a |
| Home gross inversions (grade gap ≥ 2) ↓ | n/a |
| Noise cards in home top 5 ↓ | n/a |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Person linking accuracy | 0.128 |
| Person linking (cross-source people) | 0.128 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp1_mon_night | 8 | 0.704 | 0.706 | 8/6 | 0/11 (0.000) | 0 | 0/0 | n/a |
| cp2_tue_night | 17 | 0.532 | 0.564 | 13/7 | 0/13 (0.000) | 0 | 0/0 | n/a |
| cp3_wed_night | 26 | 0.436 | 0.429 | 21/7 | 0/13 (0.000) | 0 | 0/0 | n/a |
| cp4_thu_night | 34 | 0.396 | 0.438 | 25/7 | 0/16 (0.000) | 0 | 0/0 | n/a |
| cp5_fri_evening | 40 | 0.368 | 0.427 | 27/7 | 0/17 (0.000) | 0 | 0/0 | n/a |
| cp6_sun_night | 46 | 0.336 | 0.381 | 30/7 | 0/17 (0.000) | 0 | 0/0 | n/a |
