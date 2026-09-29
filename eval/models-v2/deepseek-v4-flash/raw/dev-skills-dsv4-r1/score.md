### dev-week-v1 · skills · deepseek-v4-flash (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.979 |
| B-cubed R | 0.655 |
| B-cubed F1 | 0.784 |
| Link P (item→event, 1:1 mapped) | 0.897 |
| Link R | 0.737 |
| Link F1 | 0.809 |
| Segment Link P (added; items with segment truth) | n/a |
| Segment Link R (added) | n/a |
| Segment Link F1 (added) | n/a |
| Items filed by segments (pred) | n/a |
| Items with 2+ gold segments | n/a |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | 0.000 |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 2/2 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 15 |
| Gold events | 9 |
| Questions asked | 6 |
| Same-event questions | 3 |
| Same-event questions per 100 items | 3.660 |
| Max same-event questions per day | 1 |
| Useful asks (provisional placement was wrong) | 0.333 |
| Questions whose true answer is yes | 0.833 |
| Asks suppressed by budget | 1 |
| Status-line fact recall | 0.365 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 1 |
| Unsupported completion claims in cards ↓ | 1 |
| Cards with relative dates ↓ | 1 |
| Stale-fact rate ↓ | 0.100 |
| Home rank ran (checkpoints) | 4/4 |
| Home NDCG@5 | 0.797 |
| Home NDCG@5, recency-only order | 0.531 |
| Home top-3 precision (grade ≥ 2) | 0.833 |
| Home grade-3 recall@3 | 0.646 |
| Home gross inversions (grade gap ≥ 2) ↓ | 3 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.731 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 12.000 |
| Status line width p90 (added) | 16.000 |
| Status line width max (added) | 17.000 |
| Facts repeating their own date in the text ↓ (added) | 4 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.306 |
| Person linking (cross-source people) | 0.306 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.933 | 0.929 | 9/9 | 4/11 (0.364) | 0 | 0/0 | 0.910 |
| cp-d3 | 38 | 0.893 | 0.886 | 9/9 | 3/10 (0.300) | 0 | 0/3 | 0.756 |
| cp-d5 | 64 | 0.842 | 0.866 | 11/9 | 6/15 (0.400) | 0 | 0/7 | 0.902 |
| cp-final | 82 | 0.784 | 0.809 | 15/9 | 6/16 (0.375) | 0 | 2/10 | 0.622 |
