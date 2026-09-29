### dev-week-v1 · bare · qwen3.6-35b-a3b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.927 |
| B-cubed R | 0.232 |
| B-cubed F1 | 0.371 |
| Link P (item→event, 1:1 mapped) | 0.390 |
| Link R | 0.337 |
| Link F1 | 0.362 |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention | 0.000 |
| Predicted events | 46 |
| Gold events | 9 |
| Questions asked | 2 |
| Status-line fact recall | 0.250 |
| Stale-fact rate ↓ | 0.050 |
| Person linking accuracy | 0.083 |
| Person linking (cross-source people) | 0.083 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Stale rate |
|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.707 | 0.632 | 17/9 | 2/11 (0.182) | 0/0 |
| cp-d3 | 38 | 0.592 | 0.543 | 23/9 | 3/10 (0.300) | 0/3 |
| cp-d5 | 64 | 0.431 | 0.394 | 35/9 | 3/15 (0.200) | 1/7 |
| cp-final | 82 | 0.371 | 0.362 | 46/9 | 5/16 (0.312) | 0/10 |
