### dev-week-v1 · skills · oracle assign · deepseek-v4-flash (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.951 |
| B-cubed R | 0.782 |
| B-cubed F1 | 0.858 |
| Link P (item→event, 1:1 mapped) | 0.951 |
| Link R | 0.821 |
| Link F1 | 0.881 |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention | 0.000 |
| Predicted events | 13 |
| Gold events | 9 |
| Questions asked | 2 |
| Status-line fact recall | 0.596 |
| Stale-fact rate ↓ | 0.000 |
| Person linking accuracy | 0.083 |
| Person linking (cross-source people) | 0.083 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Stale rate |
|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.933 | 0.912 | 9/9 | 4/11 (0.364) | 0/0 |
| cp-d3 | 38 | 0.894 | 0.889 | 11/9 | 6/10 (0.600) | 0/3 |
| cp-d5 | 64 | 0.866 | 0.891 | 12/9 | 8/15 (0.533) | 0/7 |
| cp-final | 82 | 0.858 | 0.881 | 13/9 | 13/16 (0.812) | 0/10 |
