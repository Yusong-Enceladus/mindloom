### dev-week-v1 · skills · qwen3.6-35b-a3b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.836 |
| B-cubed R | 0.735 |
| B-cubed F1 | 0.782 |
| Link P (item→event, 1:1 mapped) | 0.805 |
| Link R | 0.695 |
| Link F1 | 0.746 |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention | 0.000 |
| Predicted events | 14 |
| Gold events | 9 |
| Questions asked | 2 |
| Status-line fact recall | 0.500 |
| Stale-fact rate ↓ | 0.000 |
| Person linking accuracy | 0.083 |
| Person linking (cross-source people) | 0.083 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Stale rate |
|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.863 | 0.807 | 10/9 | 2/11 (0.182) | 0/0 |
| cp-d3 | 38 | 0.832 | 0.790 | 11/9 | 4/10 (0.400) | 0/3 |
| cp-d5 | 64 | 0.811 | 0.774 | 12/9 | 9/15 (0.600) | 0/6 |
| cp-final | 82 | 0.782 | 0.746 | 14/9 | 11/16 (0.688) | 0/8 |
