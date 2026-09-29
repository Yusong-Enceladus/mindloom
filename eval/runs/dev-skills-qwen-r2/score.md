### dev-week-v1 · skills · qwen3.6-35b-a3b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.715 |
| B-cubed R | 0.703 |
| B-cubed F1 | 0.709 |
| Link P (item→event, 1:1 mapped) | 0.732 |
| Link R | 0.632 |
| Link F1 | 0.678 |
| Hard-decoy leakage ↓ | 0.714 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention | 0.000 |
| Predicted events | 13 |
| Gold events | 9 |
| Questions asked | 2 |
| Status-line fact recall | 0.462 |
| Stale-fact rate ↓ | 0.000 |
| Person linking accuracy | 0.083 |
| Person linking (cross-source people) | 0.083 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Stale rate |
|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.841 | 0.772 | 8/9 | 1/11 (0.091) | 0/0 |
| cp-d3 | 38 | 0.828 | 0.741 | 9/9 | 4/10 (0.400) | 0/3 |
| cp-d5 | 64 | 0.754 | 0.701 | 10/9 | 7/15 (0.467) | 0/6 |
| cp-final | 82 | 0.709 | 0.678 | 13/9 | 12/16 (0.750) | 0/8 |
