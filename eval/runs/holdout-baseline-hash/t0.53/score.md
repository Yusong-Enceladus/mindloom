### holdout-week-v1 · baseline τ=0.53 · no LLM (holdout, 32 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.865 |
| B-cubed R | 0.183 |
| B-cubed F1 | 0.302 |
| Link P (item→event, 1:1 mapped) | 0.250 |
| Link R | 0.242 |
| Link F1 | 0.246 |
| Hard-decoy leakage ↓ | 0.042 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention | 0.000 |
| Predicted events | 25 |
| Gold events | 5 |
| Questions asked | 0 |
| Status-line fact recall | 0.000 |
| Stale-fact rate ↓ | n/a |
| Person linking accuracy | 0.136 |
| Person linking (cross-source people) | 0.188 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Stale rate |
|---|---|---|---|---|---|---|
| cp-h3 | 18 | 0.484 | 0.400 | 12/4 | 0/7 (0.000) | 0/0 |
| cp-final | 32 | 0.302 | 0.246 | 25/5 | 0/9 (0.000) | 0/0 |
