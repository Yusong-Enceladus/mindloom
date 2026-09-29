### dev-week-v1 · baseline τ=0.65 · no LLM (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.406 |
| B-cubed R | 0.660 |
| B-cubed F1 | 0.503 |
| Link P (item→event, 1:1 mapped) | 0.366 |
| Link R | 0.316 |
| Link F1 | 0.339 |
| Hard-decoy leakage ↓ | 0.548 |
| Easy-decoy leakage ↓ | 0.389 |
| Noise abstention | 0.000 |
| Predicted events | 16 |
| Gold events | 9 |
| Questions asked | 0 |
| Status-line fact recall | 0.000 |
| Stale-fact rate ↓ | n/a |
| Person linking accuracy | 0.069 |
| Person linking (cross-source people) | 0.069 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Stale rate |
|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.521 | 0.421 | 8/9 | 0/11 (0.000) | 0/0 |
| cp-d3 | 38 | 0.547 | 0.444 | 9/9 | 0/10 (0.000) | 0/0 |
| cp-d5 | 64 | 0.502 | 0.350 | 14/9 | 0/15 (0.000) | 0/0 |
| cp-final | 82 | 0.503 | 0.339 | 16/9 | 0/16 (0.000) | 0/0 |
