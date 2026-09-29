### dev-week-v1 · baseline τ=0.41 · no LLM (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.379 |
| B-cubed R | 0.713 |
| B-cubed F1 | 0.495 |
| Link P (item→event, 1:1 mapped) | 0.305 |
| Link R | 0.263 |
| Link F1 | 0.282 |
| Hard-decoy leakage ↓ | 0.750 |
| Easy-decoy leakage ↓ | 0.250 |
| Noise abstention (= noise unfiled rate) | 0.000 |
| Noise as its own one-item event | 0.250 |
| Noise inside a real event ↓ | 0.750 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | n/a |
| Decoy seed kept apart | 1/2 |
| Matters absorbed into another event ↓ | ev_beans,ev_momflat |
| Predicted events | 14 |
| Gold events | 9 |
| Questions asked | 0 |
| Same-event questions | 0 |
| Same-event questions per 100 items | 0.000 |
| Max same-event questions per day | 0 |
| Useful asks (provisional placement was wrong) | n/a |
| Questions whose true answer is yes | n/a |
| Asks suppressed by budget | 0 |
| Status-line fact recall | 0.000 |
| Planned facts written as done ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 0 |
| Stale-fact rate ↓ | n/a |
| Home rank ran (checkpoints) | 0/4 |
| Home NDCG@5 | n/a |
| Home NDCG@5, recency-only order | 0.259 |
| Home top-3 precision (grade ≥ 2) | n/a |
| Home grade-3 recall@3 | n/a |
| Home gross inversions (grade gap ≥ 2) ↓ | n/a |
| Noise cards in home top 5 ↓ | n/a |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Person linking accuracy | 0.069 |
| Person linking (cross-source people) | 0.069 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.571 | 0.386 | 8/9 | 0/11 (0.000) | 0 | 0/0 | n/a |
| cp-d3 | 38 | 0.557 | 0.370 | 8/9 | 0/10 (0.000) | 0 | 0/0 | n/a |
| cp-d5 | 64 | 0.519 | 0.307 | 13/9 | 0/15 (0.000) | 0 | 0/0 | n/a |
| cp-final | 82 | 0.495 | 0.282 | 14/9 | 0/16 (0.000) | 0 | 0/0 | n/a |
