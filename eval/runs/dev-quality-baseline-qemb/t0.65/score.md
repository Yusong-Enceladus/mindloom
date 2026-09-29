### dev-week-v1 · baseline τ=0.65 · no LLM (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.880 |
| B-cubed R | 0.230 |
| B-cubed F1 | 0.365 |
| Link P (item→event, 1:1 mapped) | 0.366 |
| Link R | 0.316 |
| Link F1 | 0.339 |
| Hard-decoy leakage ↓ | 0.024 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention (= noise unfiled rate) | 0.000 |
| Noise as its own one-item event | 1.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | n/a |
| Decoy seed kept apart | 2/2 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 47 |
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
| Home NDCG@5, recency-only order | 0.190 |
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
| cp-d2 | 27 | 0.631 | 0.596 | 17/9 | 0/11 (0.000) | 0 | 0/0 | n/a |
| cp-d3 | 38 | 0.522 | 0.469 | 23/9 | 0/10 (0.000) | 0 | 0/0 | n/a |
| cp-d5 | 64 | 0.399 | 0.365 | 37/9 | 0/15 (0.000) | 0 | 0/0 | n/a |
| cp-final | 82 | 0.365 | 0.339 | 47/9 | 0/16 (0.000) | 0 | 0/0 | n/a |
