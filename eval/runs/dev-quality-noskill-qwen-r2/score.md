### dev-week-v1 · without-skills · qwen3.6-35b-a3b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.979 |
| B-cubed R | 0.504 |
| B-cubed F1 | 0.666 |
| Link P (item→event, 1:1 mapped) | 0.797 |
| Link R | 0.621 |
| Link F1 | 0.698 |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 4 |
| Unfiled precision (share that is noise) | 0.500 |
| Decoy seed kept apart | 2/2 |
| Matters absorbed into another event ↓ | ev_grinder |
| Predicted events | 18 |
| Gold events | 9 |
| Questions asked | 6 |
| Same-event questions | 4 |
| Same-event questions per 100 items | 4.880 |
| Max same-event questions per day | 2 |
| Useful asks (provisional placement was wrong) | 0.250 |
| Questions whose true answer is yes | 0.833 |
| Asks suppressed by budget | 7 |
| Status-line fact recall | 0.462 |
| Planned facts written as done ↓ | 0 |
| Unsupported completion claims in cards ↓ | 1 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | 0.050 |
| Home rank ran (checkpoints) | 4/4 |
| Home NDCG@5 | 0.687 |
| Home NDCG@5, recency-only order | 0.489 |
| Home top-3 precision (grade ≥ 2) | 0.583 |
| Home grade-3 recall@3 | 0.333 |
| Home gross inversions (grade gap ≥ 2) ↓ | 4 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Person linking accuracy | 0.083 |
| Person linking (cross-source people) | 0.083 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.827 | 0.815 | 9/9 | 2/11 (0.182) | 0 | 0/0 | 0.728 |
| cp-d3 | 38 | 0.786 | 0.753 | 10/9 | 2/10 (0.200) | 0 | 0/3 | 0.573 |
| cp-d5 | 64 | 0.727 | 0.760 | 12/9 | 9/15 (0.600) | 0 | 0/7 | 0.608 |
| cp-final | 82 | 0.666 | 0.698 | 18/9 | 11/16 (0.688) | 0 | 1/10 | 0.840 |
