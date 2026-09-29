### holdout-week-v1 · bare · qwen3.6-35b-a3b-nvfp4 (holdout, 32 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.798 |
| B-cubed R | 0.795 |
| B-cubed F1 | 0.796 |
| Link P (item→event, 1:1 mapped) | 0.844 |
| Link R | 0.818 |
| Link F1 | 0.831 |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention | 0.000 |
| Predicted events | 7 |
| Gold events | 5 |
| Questions asked | 0 |
| Status-line fact recall | 0.312 |
| Stale-fact rate ↓ | 0.000 |
| Person linking accuracy | 0.182 |
| Person linking (cross-source people) | 0.250 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Stale rate |
|---|---|---|---|---|---|---|
| cp-h3 | 18 | 0.868 | 0.857 | 4/4 | 2/7 (0.286) | 0/3 |
| cp-final | 32 | 0.796 | 0.831 | 7/5 | 3/9 (0.333) | 0/6 |
