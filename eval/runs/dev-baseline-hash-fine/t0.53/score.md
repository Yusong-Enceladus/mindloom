### dev-week-v1 · baseline τ=0.53 · no LLM (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.581 |
| B-cubed R | 0.395 |
| B-cubed F1 | 0.471 |
| Link P (item→event, 1:1 mapped) | 0.280 |
| Link R | 0.242 |
| Link F1 | 0.260 |
| Hard-decoy leakage ↓ | 0.250 |
| Easy-decoy leakage ↓ | 0.194 |
| Noise abstention | 0.000 |
| Predicted events | 37 |
| Gold events | 9 |
| Questions asked | 0 |
| Status-line fact recall | 0.000 |
| Stale-fact rate ↓ | n/a |
| Person linking accuracy | 0.069 |
| Person linking (cross-source people) | 0.069 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Stale rate |
|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.526 | 0.421 | 15/9 | 0/11 (0.000) | 0/0 |
| cp-d3 | 38 | 0.549 | 0.420 | 19/9 | 0/10 (0.000) | 0/0 |
| cp-d5 | 64 | 0.459 | 0.277 | 32/9 | 0/15 (0.000) | 0/0 |
| cp-final | 82 | 0.471 | 0.260 | 37/9 | 0/16 (0.000) | 0/0 |
