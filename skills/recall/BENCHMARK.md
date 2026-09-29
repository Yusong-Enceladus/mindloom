# recall benchmark

## 最终版本（提交用）：代码 13c3ae1：未测

recall 0.1.0 仍是 P1 占位：不在整理服务的 job → skill 路由表里，最终评测（`eval/runs/final-*`，holdout-week-v2 第二次评测和 dev-week-v1）没有调用它，`eval/score.py` 也没有 recall 指标；
`evals/evals.json` 的 2 条仍是文字描述，不可执行。其它技能的最终数字见 `skills/{event-assign,event-brief,home-rank,screenshot-read}/BENCHMARK.md` 的"最终版本（提交用）"一节。下面两节是历史记录。

## 历史 · holdout-week-v2 第一次一次性评测（代码 8ee22d7，2026-09-28）：未测

holdout-week-v2 的一次性评测（`eval/runs/holdout2-*`，代码 8ee22d7）没有调用 recall。原因有两个：recall 仍不在整理服务的 job → skill 路由表里，这些运行的 `runs.jsonl` 里只有 assign / brief / rank / screenshot_read；`eval/score.py` 也没有 recall 指标。
其它技能的留出集结果见 `skills/{event-assign,event-brief,home-rank,screenshot-read}/BENCHMARK.md` 的同名一节。

## 历史 · 1.0.0 首轮（2026-09-26）：未测

> P1 stub. 2026-09-26 首轮评测没有测它：未测。
> 原因：recall 不在整理服务的 job → skill 路由表里，`eval/score.py` 也没有 recall 指标；`evals/evals.json` 的 2 条是文字描述，不可执行。
> 其它四个技能的首轮结果见 `skills/{event-assign,event-brief,home-rank,screenshot-read}/BENCHMARK.md`。
