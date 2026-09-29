### holdout-week-v1 · skills · deepseek-v4-flash (holdout, 32 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.794 |
| B-cubed R | 0.722 |
| B-cubed F1 | 0.756 |
| Link P (item→event, 1:1 mapped) | 0.781 |
| Link R | 0.758 |
| Link F1 | 0.769 |
| Hard-decoy leakage ↓ | 0.167 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention | 0.000 |
| Predicted events | 9 |
| Gold events | 5 |
| Questions asked | 0 |
| Status-line fact recall | 0.688 |
| Stale-fact rate ↓ | 0.111 |
| Person linking accuracy | 0.182 |
| Person linking (cross-source people) | 0.250 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Stale rate |
|---|---|---|---|---|---|---|
| cp-h3 | 18 | 0.868 | 0.857 | 4/4 | 5/7 (0.714) | 0/3 |
| cp-final | 32 | 0.756 | 0.769 | 9/5 | 6/9 (0.667) | 1/6 |
