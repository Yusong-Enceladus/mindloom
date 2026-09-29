### holdout-week-v1 · skills · qwen3.6-35b-a3b-nvfp4 (holdout, 32 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.750 |
| B-cubed R | 0.779 |
| B-cubed F1 | 0.764 |
| Link P (item→event, 1:1 mapped) | 0.719 |
| Link R | 0.697 |
| Link F1 | 0.708 |
| Hard-decoy leakage ↓ | 0.500 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention | 0.000 |
| Predicted events | 7 |
| Gold events | 5 |
| Questions asked | 0 |
| Status-line fact recall | 0.500 |
| Stale-fact rate ↓ | 0.000 |
| Person linking accuracy | 0.182 |
| Person linking (cross-source people) | 0.250 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Stale rate |
|---|---|---|---|---|---|---|
| cp-h3 | 18 | 0.868 | 0.857 | 4/4 | 5/7 (0.714) | 0/3 |
| cp-final | 32 | 0.764 | 0.708 | 7/5 | 3/9 (0.333) | 0/5 |
