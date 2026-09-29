# DeepSeek-V4-Flash 作为整理器 LLM（category: llm）

日期 2026-09-28 PDT（Spark 时间 09-29 CST）。一次运行/场景，技能开启（`--condition skills`），只用合成数据。

## 设置

| 项 | 值 |
|---|---|
| 模型 | DeepSeek-V4-Flash，vLLM 0.30.0，TP2（spark-D rank 0 `127.0.0.1:8100` + spark-G rank 1），MTP `num_speculative_tokens=1`，max-model-len 65536，`--max-num-seqs 4`，gpu-memory-utilization 0.85 |
| 思考 | 关闭。整理器客户端已发送 `chat_template_kwargs: {"enable_thinking": false, "thinking": false}`；vLLM 的 `deepseek_v4` tokenizer 读这两个键中的任一个，关闭后走 chat 模式。烟测：`reasoning_tokens=0`（默认模式下同一请求为 114 个推理 token）。无需改代码 |
| 代码 | `claude/multimodal` @ 2e532bc（git archive 到 spark-D `~/hack/claude-models/dsv4-organizer/repo`），`eval/run_eval.py`，进程内 TestClient（不开 TCP 端口） |
| 技能提示哈希 | event-assign 39382f7a…、event-brief f266fbee…、home-rank 5b9631d0…，与 Qwen 参考运行一致；另有 item-split 116cc813…、image-read 40a4c917…（参考运行时还没有这两个技能） |
| 向量 | Qwen3-Embedding-0.6B，从 spark-C 经内网复制到 spark-D（sha256 已核对），用 `setup/embed_server.py` 跑在 `127.0.0.1:8012`（transformers，bf16，CUDA，末 token 池化 + L2 归一化）。spark-D 在 DeepSeek 旁边只剩约 6 GB，放不下 vLLM 的 pooling 服务。与参考运行所用的 vLLM 向量在数值上会有微小差异 |
| 视觉（只用于 image-detect / image-read） | spark-C 上共享的 Qwen3.6-35B-A3B-NVFP4，经 Mac 转发的本机回环隧道接入。DeepSeek-V4-Flash 只接收文本任务（assign / brief / rank / split） |
| 命令 | `setup/run_all.sh`：`run_eval.py --condition skills --llm-url http://127.0.0.1:8100/v1 --embed-url http://127.0.0.1:8012/v1 --vision-llm-url <隧道> --llm-timeout 600 --keep-db` |

## 结果

参考行是已提交的 Qwen3.6-35B-A3B-NVFP4 运行（`eval/runs/final-{dev,h2}-skills-qwen-r{1,2}`，代码 13c3ae1，没有 item-split 和 image-read）。

| 场景 | 模型 | B³ F1 | Link F1 | 卡片事实召回 | 状态行事实召回 | 提问/100 条 | 无依据日期 | 计划写成完成 | 秒/条（墙钟） | 有效补全 tok/s |
|---|---|---|---|---|---|---|---|---|---|---|
| dev-week-v1（82） | **DeepSeek-V4-Flash** | **0.784** | **0.809** | 0.731 | 0.365 | 3.66 | 0 | 0 | 15.9 | 27.9 |
| dev-week-v1 | Qwen3.6 r1 / r2 | 0.763 / 0.733 | 0.798 / 0.740 | 0.808 / 0.692 | 0.385 / 0.346 | 3.66 / 4.88 | 0 / 0 | 0 / 0 | 13.2 / 13.6 | 43.9 / 44.7 |
| holdout-week-v2（46） | **DeepSeek-V4-Flash** | **0.735** | **0.710** | 0.609 | 0.287 | 4.35 | 0 | 0 | 24.3 | 28.3 |
| holdout-week-v2 | Qwen3.6 r1 / r2 | 0.782 / 0.782 | 0.686 / 0.686 | 0.517 / 0.506 | 0.184 / 0.138 | 6.52 / 8.70 | 0 / 0 | 0 / 0 | 15.9 / 15.8 | 44.9 / 44.9 |

- 计划写成完成 = 守卫正则口径 `plan_as_done`。按金标准状态标注的口径（`plan_labelled_done`）：dev 1，h2 0（Qwen：dev 1/1，h2 0/0）。无依据的完成声明（`unsupported_completion`）：dev 1，h2 1。
- 其他（dev / h2）：事件数（预测/金标准）15/9 / 9/7；强干扰项泄漏 0.000 / 0.417（Qwen h2 0.25）；噪声不归档率 1.00 / 0.50；被吞掉的事件 无 / ev_peggy_quote；卡片里的相对日期 1 / 0；过期事实率 0.10 / 0.00；首页 NDCG@5 0.797 / 0.960。
- event-brief 最终通过校验的比例（一次重试后）：dev 61/79，h2 24/50（Qwen h2：27/43、32/43）。失败多半是 `unsupported_completion` 守卫（把「PO改成3200套」「我们会先核对…」这类计划或条件句标成 done）和相对日期（「今天」）。两次都不合格时，整理器会保留其中能通过证据规则的事实、状态行和标题（`salvage`）；什么都保不下来时，沿用上一版卡片。所以 h2 的卡片事实召回仍高于 Qwen。
- 秒/条 = 墙钟 / 素材数，含视觉和向量调用。只算 DeepSeek 调用：dev 15.5，h2 23.1 秒/条。h2 较慢，原因有三：brief 的提示更长（均值 8.1k token），重试更多（46/50），item-split 调用 15 次（把 4 条素材拆成 10 段）。
- 有效补全 tok/s = DeepSeek 调用的补全 token 总数 / 这些调用的总耗时（含预填充），与 Qwen 列口径相同。单流直测（`speed.json`）：解码 30.9 tok/s（MTP，接受长度约 1.7–1.95），5.7k token 提示的预填充 2173 tok/s。中位延迟：assign 4.2 / 4.7 s，brief 10.2 / 16.1 s，rank 9.8 / 8.3 s（dev / h2）。
- 内存：DeepSeek 在每个节点占约 115 GB（spark-D 119/121 GB，其中约 2.7 GB 是本次的向量服务器；spark-G 116 GB）。停止后两个节点都回落到已用 6 GB、可用 114–115 GB。

## 结论

- 文本技能提示相同的条件下，DeepSeek-V4-Flash 在 dev 上的分组比 Qwen3.6 好一点（B³ 0.784 对 0.73–0.76，Link 0.809 对 0.74–0.80，干扰项和噪声都分得开）。在 holdout-week-v2 上，B³ 低 0.047，Link 高 0.024，卡片事实召回更高（0.609 对 0.51）。它会多开事件（9/7），强干扰项泄漏更多（0.417 对 0.25）。每个场景只跑了一次，这些差距都在已观察到的两次运行之间的波动范围内。
- 它每条素材慢 1.2–1.5 倍（15.9 / 24.3 秒对约 13.4 / 15.8 秒），要占两台 Spark，而且 brief 更常被 schema/守卫拒绝。质量上没有明显优势，不值得替换单节点的 Qwen3.6 整理器。
- 注意事项：Qwen 参考运行用的是较早的代码（13c3ae1：没有 item-split，截图读取用 screenshot-read 而不是 image-read，向量用 vLLM）。本次运行拆分了 dev 的 1 条素材和 h2 的 4 条素材。要比较不同模型，最干净的做法是在 2e532bc 上重跑一次 Qwen3.6。`items_without_embedding`（1 / 4）数的正是这些被拆分的素材，它们的向量在各个分段上，不是失败。holdout-week-v2 只评估一次，没有据此调整提示词。

## 文件

- `raw/dev-skills-dsv4-r1/`、`raw/h2-skills-dsv4-r1/`：`meta.json`、`stats.json`、`score.json`、`score.md`、`runs.jsonl`（每次调用的输入和输出，合成数据）、`snapshots/`。SQLite 的 `data/` 留在 spark-D 的 `~/hack/claude-models/dsv4-organizer/out/`。
- `scores.json`：本次两个运行和四个 Qwen 参考运行的精简指标（`setup/summarize.py`）。
- `speed.json`：单流解码和预填充速度。
- `setup/`：`run_all.sh`、`embed_server.py`、`smoke.py`（检查思考是否关闭）、`speed.py`。
