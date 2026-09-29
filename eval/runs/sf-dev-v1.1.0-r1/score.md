### dev-week-v1 · skills · qwen3.6-35b-a3b-nvfp4 (dev, 82 items)

| Metric | Value |
|---|---|
| B-cubed P (extended, multi-label) | 0.956 |
| B-cubed R | 0.633 |
| B-cubed F1 | 0.762 |
| Link P (item→event, 1:1 mapped) | 0.872 |
| Link R | 0.716 |
| Link F1 | 0.786 |
| Segment Link P (added; items with segment truth) | n/a |
| Segment Link R (added) | n/a |
| Segment Link F1 (added) | n/a |
| Items filed by segments (pred) | n/a |
| Items with 2+ gold segments | n/a |
| Hard-decoy leakage ↓ | 0.000 |
| Easy-decoy leakage ↓ | 0.028 |
| Noise abstention (= noise unfiled rate) | 1.000 |
| Noise as its own one-item event | 0.000 |
| Noise inside a real event ↓ | 0.000 |
| Real items left unfiled ↓ | 0 |
| Unfiled precision (share that is noise) | 1.000 |
| Decoy seed kept apart | 2/2 |
| Matters absorbed into another event ↓ | none |
| Predicted events | 14 |
| Gold events | 9 |
| Questions asked | 7 |
| Same-event questions | 4 |
| Same-event questions per 100 items | 4.880 |
| Max same-event questions per day | 1 |
| Useful asks (provisional placement was wrong) | 0.250 |
| Questions whose true answer is yes | 0.571 |
| Asks suppressed by budget | 2 |
| Status-line fact recall | 0.404 |
| Planned facts written as done (guard's claim regex) ↓ | 0 |
| Planned facts labelled done/in_progress (gold state, independent of the guard) ↓ | 0 |
| Unsupported completion claims in cards ↓ | 0 |
| Cards with relative dates ↓ | 1 |
| Stale-fact rate ↓ | 0.000 |
| Home rank ran (checkpoints) | 4/4 |
| Home NDCG@5 | 0.582 |
| Home NDCG@5, recency-only order | 0.565 |
| Home top-3 precision (grade ≥ 2) | 0.667 |
| Home grade-3 recall@3 | 0.458 |
| Home gross inversions (grade gap ≥ 2) ↓ | 9 |
| Noise cards in home top 5 ↓ | 0 |
| Titles over 20 chars ↓ | 0 |
| Status lines over 54 chars ↓ | 0 |
| Card fact recall (status line + status facts; added metric) | 0.769 |
| Status lines wider than a Home card line (24) ↓ (added) | 0 |
| Status line width p50 (added) | 11.500 |
| Status line width p90 (added) | 14.000 |
| Status line width max (added) | 18.500 |
| Facts repeating their own date in the text ↓ (added) | 3 |
| Dates in status lines / facts not given by the cited items ↓ (added) | 0 |
| Person linking accuracy | 0.306 |
| Person linking (cross-source people) | 0.306 |

| Checkpoint | Items | B³ F1 | Link F1 | Events (pred/gold) | Fact recall | Plan-as-done | Stale rate | Home NDCG@5 |
|---|---|---|---|---|---|---|---|---|
| cp-d2 | 27 | 0.844 | 0.821 | 11/9 | 2/11 (0.182) | 0 | 0/0 | 0.730 |
| cp-d3 | 38 | 0.799 | 0.785 | 12/9 | 2/10 (0.200) | 0 | 0/3 | 0.452 |
| cp-d5 | 64 | 0.782 | 0.806 | 13/9 | 6/15 (0.400) | 0 | 0/7 | 0.746 |
| cp-final | 82 | 0.762 | 0.786 | 14/9 | 11/16 (0.688) | 0 | 0/10 | 0.399 |
