### dev-week-v1 · bare · qwen3.6-35b-a3b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.745 |
| B-cubed R | 0.638 |
| B-cubed F1 | 0.687 |
| Link P (item→event, 1:1 mapped) | 0.659 |
| Link R | 0.568 |
| Link F1 | 0.610 |
| Hard-decoy leakage ↓ | 0.714 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention | 0.000 |
| Predicted events | 18 |
| Gold events | 9 |
| Questions asked | 2 |
| Status-line fact recall | 0.346 |
| Stale-fact rate ↓ | 0.059 |
| Person linking accuracy | 0.083 |
| Person linking (cross-source people) | 0.083 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Stale rate |
|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.816 | 0.772 | 10/9 | 2/11 (0.182) | 0/0 |
| cp-d3 | 38 | 0.777 | 0.691 | 12/9 | 3/10 (0.300) | 0/3 |
| cp-d5 | 64 | 0.720 | 0.642 | 16/9 | 6/15 (0.400) | 0/6 |
| cp-final | 82 | 0.687 | 0.610 | 18/9 | 7/16 (0.438) | 1/8 |
