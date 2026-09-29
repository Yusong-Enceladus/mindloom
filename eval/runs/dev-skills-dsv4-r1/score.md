### dev-week-v1 · skills · deepseek-v4-flash (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.866 |
| B-cubed R | 0.644 |
| B-cubed F1 | 0.739 |
| Link P (item→event, 1:1 mapped) | 0.829 |
| Link R | 0.716 |
| Link F1 | 0.768 |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention | 0.000 |
| Predicted events | 18 |
| Gold events | 9 |
| Questions asked | 2 |
| Status-line fact recall | 0.481 |
| Stale-fact rate ↓ | 0.000 |
| Person linking accuracy | 0.083 |
| Person linking (cross-source people) | 0.083 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Stale rate |
|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.933 | 0.912 | 9/9 | 2/11 (0.182) | 0/0 |
| cp-d3 | 38 | 0.881 | 0.864 | 10/9 | 5/10 (0.500) | 0/3 |
| cp-d5 | 64 | 0.781 | 0.803 | 14/9 | 9/15 (0.600) | 0/7 |
| cp-final | 82 | 0.739 | 0.768 | 18/9 | 9/16 (0.562) | 0/10 |
