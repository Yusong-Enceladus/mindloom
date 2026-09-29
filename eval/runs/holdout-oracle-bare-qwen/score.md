### holdout-week-v1 · bare · oracle assign · qwen3.6-35b-a3b-nvfp4 (holdout, 32 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.938 |
| B-cubed R | 0.884 |
| B-cubed F1 | 0.910 |
| Link P (item→event, 1:1 mapped) | 0.938 |
| Link R | 0.909 |
| Link F1 | 0.923 |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention | 0.000 |
| Predicted events | 7 |
| Gold events | 5 |
| Questions asked | 0 |
| Status-line fact recall | 0.438 |
| Stale-fact rate ↓ | 0.000 |
| Person linking accuracy | 0.182 |
| Person linking (cross-source people) | 0.250 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Stale rate |
|---|---|---|---|---|---|---|
| cp-h3 | 18 | 0.971 | 0.971 | 5/4 | 3/7 (0.429) | 0/3 |
| cp-final | 32 | 0.910 | 0.923 | 7/5 | 4/9 (0.444) | 0/6 |
