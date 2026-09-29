### dev-week-v1 · bare · qwen3.6-35b-a3b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.933 |
| B-cubed R | 0.685 |
| B-cubed F1 | 0.790 |
| Link P (item→event, 1:1 mapped) | 0.866 |
| Link R | 0.747 |
| Link F1 | 0.802 |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention | 0.000 |
| Predicted events | 17 |
| Gold events | 9 |
| Questions asked | 2 |
| Status-line fact recall | 0.404 |
| Stale-fact rate ↓ | 0.000 |
| Person linking accuracy | 0.083 |
| Person linking (cross-source people) | 0.083 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Stale rate |
|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.863 | 0.842 | 11/9 | 3/11 (0.273) | 0/0 |
| cp-d3 | 38 | 0.833 | 0.790 | 13/9 | 4/10 (0.400) | 0/3 |
| cp-d5 | 64 | 0.806 | 0.818 | 14/9 | 6/15 (0.400) | 0/7 |
| cp-final | 82 | 0.790 | 0.802 | 17/9 | 8/16 (0.500) | 0/10 |
