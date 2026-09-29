### holdout-week-v2 · without-skills · qwen3.6-35b-a3b-nvfp4 (holdout, 46 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.976 |
| B-cubed R | 0.495 |
| B-cubed F1 | 0.657 |
| Link P (item→event, 1:1 mapped) | 0.810 |
| Link R | 0.576 |
| Link F1 | 0.673 |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | n/a |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 2/2 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 11 |
| Gold events | 7 |
| Questions asked | 5 |
| Same-event questions | 5 |
| Same-event questions per 100 items | 10.870 |
| Max same-event questions per day | 1 |
| Useful asks (provisional placement was wrong) | 0.200 |
| Questions whose true answer is yes | 0.200 |
| Asks suppressed by budget | 3 |
| Status-line fact recall | 0.149 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.289 |
| Home rank ran (checkpoints) | 6/6 |
| Home NDCG@5 | 0.735 |
| Home NDCG@5, recency-only order | 0.730 |
| Home top-3 precision (grade ≥ 2) | 0.778 |
| Home grade-3 recall@3 | 0.222 |
| Home gross inversions (grade gap ≥ 2) ↓ | 2 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Person linking accuracy | 0.186 |
| Person linking (cross-source people) | 0.186 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp1_mon_night | 8 | 0.742 | 0.667 | 4/6 | 2/11 (0.182) | 0 | 0/0 | 0.887 |
| cp2_tue_night | 17 | 0.567 | 0.629 | 6/7 | 1/13 (0.077) | 0 | 1/2 | 0.598 |
| cp3_wed_night | 26 | 0.694 | 0.679 | 10/7 | 4/13 (0.308) | 0 | 0/4 | 0.843 |
| cp4_thu_night | 34 | 0.709 | 0.725 | 10/7 | 1/16 (0.062) | 0 | 3/8 | 0.757 |
| cp5_fri_evening | 40 | 0.659 | 0.682 | 11/7 | 3/17 (0.176) | 0 | 3/14 | 0.713 |
| cp6_sun_night | 46 | 0.657 | 0.673 | 11/7 | 2/17 (0.118) | 0 | 6/17 | 0.610 |
