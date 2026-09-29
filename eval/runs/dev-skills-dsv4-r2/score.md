### dev-week-v1 · skills · deepseek-v4-flash (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.844 |
| B-cubed R | 0.664 |
| B-cubed F1 | 0.743 |
| Link P (item→event, 1:1 mapped) | 0.841 |
| Link R | 0.726 |
| Link F1 | 0.780 |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | 0.222 |
| Noise abstention | 0.000 |
| Predicted events | 16 |
| Gold events | 9 |
| Questions asked | 2 |
| Status-line fact recall | 0.596 |
| Stale-fact rate ↓ | 0.000 |
| Person linking accuracy | 0.083 |
| Person linking (cross-source people) | 0.083 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Stale rate |
|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.933 | 0.912 | 9/9 | 5/11 (0.455) | 0/0 |
| cp-d3 | 38 | 0.881 | 0.864 | 10/9 | 6/10 (0.600) | 0/3 |
| cp-d5 | 64 | 0.781 | 0.803 | 14/9 | 10/15 (0.667) | 0/7 |
| cp-final | 82 | 0.743 | 0.780 | 16/9 | 10/16 (0.625) | 0/10 |
