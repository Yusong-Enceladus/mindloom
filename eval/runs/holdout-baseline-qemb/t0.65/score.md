### holdout-week-v1 · baseline τ=0.65 · no LLM (holdout, 32 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.489 |
| B-cubed R | 0.474 |
| B-cubed F1 | 0.481 |
| Link P (item→event, 1:1 mapped) | 0.344 |
| Link R | 0.333 |
| Link F1 | 0.338 |
| Hard-decoy leakage ↓ | 0.500 |
| Easy-decoy leakage ↓ | 0.133 |
| Noise abstention | 0.000 |
| Predicted events | 12 |
| Gold events | 5 |
| Questions asked | 0 |
| Status-line fact recall | 0.000 |
| Stale-fact rate ↓ | n/a |
| Person linking accuracy | 0.136 |
| Person linking (cross-source people) | 0.188 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Stale rate |
|---|---|---|---|---|---|---|
| cp-h3 | 18 | 0.517 | 0.343 | 6/4 | 0/7 (0.000) | 0/0 |
| cp-final | 32 | 0.481 | 0.338 | 12/5 | 0/9 (0.000) | 0/0 |
