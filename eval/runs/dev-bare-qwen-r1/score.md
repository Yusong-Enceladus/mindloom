### dev-week-v1 · bare · qwen3.6-35b-a3b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.829 |
| B-cubed R | 0.693 |
| B-cubed F1 | 0.755 |
| Link P (item→event, 1:1 mapped) | 0.780 |
| Link R | 0.674 |
| Link F1 | 0.723 |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention | 0.000 |
| Predicted events | 16 |
| Gold events | 9 |
| Questions asked | 2 |
| Status-line fact recall | 0.538 |
| Stale-fact rate ↓ | 0.000 |
| Person linking accuracy | 0.083 |
| Person linking (cross-source people) | 0.083 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Stale rate |
|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.844 | 0.772 | 11/9 | 3/11 (0.273) | 0/0 |
| cp-d3 | 38 | 0.818 | 0.765 | 12/9 | 5/10 (0.500) | 0/3 |
| cp-d5 | 64 | 0.772 | 0.730 | 14/9 | 9/15 (0.600) | 0/6 |
| cp-final | 82 | 0.755 | 0.723 | 16/9 | 11/16 (0.688) | 0/8 |
