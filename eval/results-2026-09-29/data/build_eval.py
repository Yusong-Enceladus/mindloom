"""Assemble eval.json from committed results (hand-copied with their source paths)
and the new v5 measurements in this directory. Re-run after new organizer runs land in data/org/."""
import json
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
V5 = HERE.parent
MH = Path("<organizer-repo>")
sys.path.insert(0, str(MH / "eval/models-v2/deepseek-v4-flash/setup"))
import summarize  # noqa: E402  (eval/models-v2/deepseek-v4-flash/setup/summarize.py)

R = lambda x, n=3: None if x is None else round(x, n)  # noqa: E731


def jl(p):
    return json.loads(Path(p).read_text())


# ---------------------------------------------------------------- organizer model comparison
def rows_from(dirpath):
    return [summarize.row(p) for p in sorted(Path(dirpath).iterdir()) if (p / "score.json").exists()]


org_rows = []
# committed models-v2 rows (code 2e532bc, one run per model and scenario)
mv2 = MH / "eval/models-v2"
for r in jl(mv2 / "qwen3.8-27b-fp8/summary.json")["organizer"]:
    org_rows.append({**r, "label": "Qwen3.8-27B-FP8", "family": "Qwen", "hw": "1 Spark", "src": "eval/models-v2/qwen3.8-27b-fp8/summary.json"})
for r in jl(mv2 / "deepseek-v4-flash/scores.json"):
    if r["model"].startswith("deepseek"):
        org_rows.append({**r, "label": "DeepSeek-V4-Flash", "family": "DeepSeek", "hw": "2 Sparks (TP2)", "src": "eval/models-v2/deepseek-v4-flash/scores.json"})
for r in jl(mv2 / "nemotron-3-super-120b-a12b-nvfp4/summary.json")["organizer"]:
    org_rows.append({**r, "label": "Nemotron-3-Super-120B-A12B NVFP4", "family": "NVIDIA Nemotron", "hw": "1 Spark", "src": "eval/models-v2/nemotron-3-super-120b-a12b-nvfp4/summary.json"})
for r in rows_from(mv2 / "nano-omni-org/org"):
    org_rows.append({**r, "label": "Nemotron-3-Nano-Omni-30B-A3B NVFP4", "family": "NVIDIA Nemotron", "hw": "1 Spark", "src": "eval/models-v2/nano-omni-org/org/*"})
# v5 runs fetched into data/org/<slug>/<run>/ (score.json, stats.json, meta.json)
V5_LABELS = {
    "qwen36-ref": ("Qwen3.6-35B-A3B NVFP4 (default)", "Qwen", "1 Spark", "v5 re-run on 2e532bc, spark-n4"),
    "muse-glimmer": ("Muse Glimmer-30B NVFP4", "Meta Muse", "1 Spark", "models-v2 batch on spark-n1, finished 09-29 04:14 PDT, not yet in MODELS.md"),
    "glm47-flash": ("GLM-4.7-Flash (30B-A3B, bf16)", "Zhipu GLM", "1 Spark", "v5, spark-n6"),
    "gemma4-26b-a4b": ("Gemma 4 26B-A4B-it (bf16)", "Google Gemma", "1 Spark", "v5, spark-n1"),
    "gpt-oss-120b": ("gpt-oss-120b (reasoning low, +2048 tok)", "OpenAI gpt-oss", "1 Spark", "v5, spark-n3"),
    "mistral-small4": ("Mistral Small 4 119B NVFP4", "Mistral", "1 Spark", "v5, spark-n3"),
}
for slug, (label, fam, hw, src) in V5_LABELS.items():
    d = HERE / "org" / slug
    if d.exists():
        for r in rows_from(d):
            org_rows.append({**r, "label": label, "family": fam, "hw": hw, "src": f"v5/data/org/{slug}/{r['run']} ({src})"})
KEEP = ["label", "family", "hw", "run", "scenario", "items", "b3_f1", "link_f1", "card_fact_recall", "status_fact_recall",
        "hard_decoy_leakage", "home_ndcg5", "brief_ok", "pred_gold_events", "ungrounded_dates", "unsupported_completion",
        "s_per_item", "latency_median_s", "image_jobs", "src"]
org_rows = [{k: r.get(k) for k in KEEP} for r in org_rows]


def agg(scn):
    out = {}
    for r in org_rows:
        if r["scenario"] != scn:
            continue
        a = out.setdefault(r["label"], {"label": r["label"], "family": r["family"], "hw": r["hw"], "runs": []})
        a["runs"].append(r)
    for a in out.values():
        for k in ("b3_f1", "link_f1", "card_fact_recall", "status_fact_recall", "hard_decoy_leakage", "s_per_item"):
            vals = [x[k] for x in a["runs"] if x[k] is not None]
            a[k + "_mean"] = R(statistics.mean(vals)) if vals else None
            a[k + "_range"] = [R(min(vals)), R(max(vals))] if vals else None
        a["n"] = len(a["runs"])
    return sorted(out.values(), key=lambda a: -(a["b3_f1_mean"] or 0))


org_failed = [
    {"model": "gpt-oss-120b (1st attempt, 09-28)", "family": "OpenAI gpt-oss", "result": "aborted",
     "why": "reasoning cannot be switched off; with the skills' own output budgets (event-assign 400 tokens) 41 of 44 requests hit the length cap; 10 of 82 dev items in 671 s",
     "why_zh": "推理关不掉；按技能自己的输出上限（event-assign 400 token），44 个请求里 41 个被截断；671 秒只处理了 dev 82 条里的 10 条",
     "src": "eval/models-v2/gpt-oss-120b/metrics-at-abort.txt"},
    {"model": "Gemma 4 31B-it QAT w4a16 (09-28, image reading only)", "family": "Google Gemma", "result": "unusable",
     "why": "server starts but every request (text too) returns token 0 -> HTTP 500 (w4a16 compressed-tensors path on SM121 / vLLM 0.30.0)",
     "why_zh": "服务能起来，但所有请求（包括纯文本）只输出 token 0，全部 HTTP 500；判断是 W4A16 量化在 GB10 / vLLM 0.30.0 上的问题",
     "src": "eval/models-v2/gemma4-31b-qat/retry/NOTE.txt"},
    {"model": "Mistral Small 4 119B NVFP4 (1st attempt)", "family": "Mistral", "result": "failed to start",
     "why": "vLLM 0.30.0 imports PixtralRotaryEmbedding, which transformers 5.17 renamed to PixtralVisionRotaryEmbedding",
     "why_zh": "vLLM 0.30.0 要导入 PixtralRotaryEmbedding，而 transformers 5.17 已改名，服务起不来",
     "src": "eval/models-v2/mistral-small4/failstart.txt"},
    {"model": "Nemotron-3.5-Lightning-30B-A3B NVFP4 (09-28)", "family": "NVIDIA Nemotron", "result": "failed to start",
     "why": "tokenizer instantiation failed", "why_zh": "tokenizer 实例化失败，服务起不来", "src": "docs/MODELS.md"},
]
v5_notes = HERE / "org_notes.json"
if v5_notes.exists():
    org_failed += jl(v5_notes)

# ---------------------------------------------------------------- committed, hand-copied results
scale = {
    "source": "<scale-runs>/SUMMARY.md (+ lab|startup|pm/REPORT.md, score/*.json)",
    "scenarios": {
        "lab": {"split": "dev", "items": 1510, "true_events": 22, "true_people": 36, "spark": "spark-n2"},
        "startup": {"split": "holdout", "items": 1600, "true_events": 20, "true_people": 43, "spark": "spark-n4"},
        "pm": {"split": "dev", "items": 1600, "true_events": 21, "true_people": 42, "spark": "spark-n5"},
    },
    "metrics": {
        "b3_f1": {"lab": 0.642, "startup": 0.584, "pm": 0.606}, "b3_f1_baseline": {"lab": 0.179, "startup": 0.266, "pm": 0.299},
        "b3_precision": {"lab": 0.708, "startup": 0.678, "pm": 0.679}, "b3_recall": {"lab": 0.588, "startup": 0.514, "pm": 0.547},
        "link_f1": {"lab": 0.630, "startup": 0.582, "pm": 0.563}, "link_f1_baseline": {"lab": 0.136, "startup": 0.116, "pm": 0.186},
        "segment_link_f1": {"lab": 0.453, "startup": 0.557, "pm": 0.438}, "segment_link_f1_baseline": {"lab": 0.083, "startup": 0.094, "pm": 0.127},
        "lookalike_leak_hard": {"lab": 0.225, "startup": 0.068, "pm": 0.140}, "lookalike_leak_hard_baseline": {"lab": 0.258, "startup": 0.833, "pm": 0.920},
        "lookalike_leak_easy": {"lab": 0.085, "startup": 0.334, "pm": 0.091}, "lookalike_leak_easy_baseline": {"lab": 0.240, "startup": 0.809, "pm": 0.889},
        "noise_unfiled": {"lab": 0.610, "startup": 0.317, "pm": 0.430}, "noise_own_event": {"lab": 0.276, "startup": 0.583, "pm": 0.523},
        "noise_into_real_event": {"lab": 0.114, "startup": 0.100, "pm": 0.047},
        "pred_events": {"lab": 242, "startup": 348, "pm": 227}, "single_item_events": {"lab": 143, "startup": 233, "pm": 109},
        "person_records": {"lab": 171, "startup": 116, "pm": 222}, "person_link_accuracy_fallback": {"lab": 0.255, "startup": 0.232, "pm": 0.244},
        "status_fact_recall": {"lab": 0.267, "startup": 0.350, "pm": 0.565}, "card_fact_recall": {"lab": 0.489, "startup": 0.583, "pm": 0.652},
        "plan_as_done_guard_truth": {"lab": "0/0", "startup": "0/0", "pm": "0/1"},
        "unsupported_completion": {"lab": 1, "startup": 6, "pm": 0}, "relative_dates": {"lab": 8, "startup": 1, "pm": 3},
        "unsourced_dates": {"lab": 0, "startup": 0, "pm": 2}, "stale_facts": {"lab": "2/47", "startup": "0/21", "pm": "0/26"},
        "home_ndcg5": {"lab": 0.128, "startup": 0.351, "pm": 0.343}, "home_ndcg5_recency_only": {"lab": 0.206, "startup": 0.279, "pm": 0.336},
        "questions_asked": {"lab": 4, "startup": 4, "pm": 4},
        "items_per_min": {"lab": 4.00, "startup": 3.85, "pm": 3.71},
        "gpu_util_mean_pct": {"lab": 93.6, "startup": 94.1, "pm": 87.0},
    },
}

ablation = {
    "source": "skills/*/BENCHMARK.md final sections (code 13c3ae1 for assign/brief/rank, image-read 1.0.0, file-read 1.0.0); 'without skill text' = eval_common.strip_skill_text (same model, schema, validators, retries)",
    "rows": [
        {"skill": "event-assign", "metric": "B³ F1", "set": "holdout-week-v2 (46)", "with": 0.782, "without": 0.612, "with_runs": [0.782, 0.782], "without_runs": [0.575, 0.649], "baselines": {"vector τ=0.60": 0.336, "lexical τ=0.41": 0.463}, "src": "skills/event-assign/BENCHMARK.md"},
        {"skill": "event-assign", "metric": "B³ F1", "set": "dev-week-v1 (82)", "with": 0.748, "without": 0.673, "with_runs": [0.763, 0.733], "without_runs": [0.697, 0.650], "baselines": {"vector": 0.530, "lexical": 0.495}, "src": "skills/event-assign/BENCHMARK.md"},
        {"skill": "event-assign", "metric": "first-try valid output", "set": "holdout-week-v2", "with": "45/46, 45/46", "without": "38/46, 37/48", "src": "skills/event-assign/BENCHMARK.md"},
        {"skill": "event-brief", "metric": "card fact recall", "set": "holdout-week-v2", "with": 0.511, "without": 0.431, "with_runs": [0.517, 0.506], "without_runs": [0.402, 0.460], "src": "skills/event-brief/BENCHMARK.md"},
        {"skill": "event-brief", "metric": "card fact recall", "set": "dev-week-v1", "with": 0.750, "without": 0.644, "src": "skills/event-brief/BENCHMARK.md"},
        {"skill": "event-brief", "metric": "calls accepted after one retry", "set": "holdout-week-v2", "with": "59/86 (0.686)", "without": "27/84 (0.321)", "src": "skills/event-brief/BENCHMARK.md"},
        {"skill": "home-rank", "metric": "home NDCG@5", "set": "holdout-week-v2", "with": 0.923, "without": 0.806, "with_runs": [0.932, 0.914], "without_runs": [0.814, 0.797], "recency_only": 0.886, "src": "skills/home-rank/BENCHMARK.md"},
        {"skill": "image-read", "metric": "key-field exact match", "set": "mm-v1 test (98 images)", "with": 0.975, "without": 0.626, "with_runs": [0.962, 0.988], "without_runs": [0.657, 0.594], "src": "skills/image-read/BENCHMARK.md"},
        {"skill": "image-read", "metric": "image type correct", "set": "mm-v1 test", "with": 0.990, "without": 0.837, "with_runs": [0.980, 1.000], "without_runs": [0.847, 0.827], "src": "skills/image-read/BENCHMARK.md"},
        {"skill": "image-read", "metric": "CER (lower is better)", "set": "mm-v1 test", "with": 0.016, "without": 0.231, "with_runs": [0.026, 0.005], "without_runs": [0.212, 0.250], "src": "skills/image-read/BENCHMARK.md"},
        {"skill": "file-read", "metric": "summary valid on first try", "set": "files-v1 test (40 files, 38 with text)", "with": 0.947, "without": 0.039, "with_runs": ["36/38", "36/38"], "without_runs": ["1/38", "2/38"], "src": "skills/file-read/BENCHMARK.md"},
        {"skill": "file-read", "metric": "picture-only text recovered", "set": "files-v1 test", "with": 1.0, "without": 0.928, "with_runs": [1.0, 1.0], "without_runs": [0.938, 0.917], "src": "skills/file-read/BENCHMARK.md"},
        {"skill": "item-split", "metric": "split decision / part F1", "set": "split-dev (tuning set, 51 items x3)", "with": "1.000 / 0.937", "without": "not measured", "src": "skills/item-split/BENCHMARK.md"},
        {"skill": "recall", "metric": "-", "set": "-", "with": "not measured (P1 stub, not routed)", "without": "-", "src": "skills/recall/BENCHMARK.md"},
    ],
}

image_models = {
    "source": "docs/MODELS.md (eval/multimodal/BENCHMARK.md, eval/models-v2/*/vlm-score.json); mm-v1 test 98 images, neutral prompt, type given, single stream",
    "rows": [
        {"model": "Qwen3.6-35B-A3B NVFP4 (default)", "cer": 0.003, "key_em": 0.986, "fab_num": 0.005, "p50_s": 2.64, "p90_s": 5.13, "c4_img_per_min": 34.3, "mem_gib": 49.9, "status": "default"},
        {"model": "Qwen3.8-27B-FP8", "cer": 0.004, "key_em": 0.988, "fab_num": 0.005, "p50_s": 10.97, "p90_s": 21.41, "c4_img_per_min": 14.3, "mem_gib": 50.6, "status": "most accurate, 4x slower"},
        {"model": "Muse Glimmer-30B NVFP4", "cer": 0.006, "key_em": 0.976, "fab_num": 0.0, "p50_s": 17.81, "p90_s": 34.85, "c4_img_per_min": 11.9, "mem_gib": 58.2, "status": "no fabricated numbers, slowest of the good ones"},
        {"model": "Qwen3.6-35B-A3B Q8_0 (llama.cpp)", "cer": 0.005, "key_em": 0.986, "fab_num": 0.015, "p50_s": 5.43, "p90_s": 10.2, "c4_img_per_min": 10.9, "mem_gib": 40.8, "status": "same quality, 2x slower"},
        {"model": "Step3-VL-10B Q8_0", "cer": 0.012, "key_em": 0.966, "fab_num": 0.020, "p50_s": 12.55, "p90_s": 25.07, "c4_img_per_min": 8.3, "mem_gib": 16.6, "status": "chart data points 89.7%"},
        {"model": "Qwen3-VL-8B Q8_0", "cer": 0.010, "key_em": 0.959, "fab_num": 0.020, "p50_s": 10.0, "p90_s": 20.62, "c4_img_per_min": 11.1, "mem_gib": 19.2, "status": "adds chat times not in the picture (85.9%)"},
        {"model": "Nemotron-3-Nano-Omni NVFP4", "cer": 0.026, "key_em": 0.878, "fab_num": 0.007, "p50_s": 4.68, "p90_s": 9.69, "c4_img_per_min": 25.3, "mem_gib": 54.3, "status": "fast, not accurate enough"},
        {"model": "MiniCPM-V-4.6", "cer": 0.213, "key_em": 0.581, "fab_num": 0.052, "p50_s": 3.18, "p90_s": 36.77, "c4_img_per_min": 31.1, "mem_gib": 29.3, "status": "JSON valid 88.8%"},
        {"model": "GLM-OCR", "cer": 0.536, "key_em": 0.191, "fab_num": 0.003, "p50_s": 4.13, "p90_s": 35.88, "c4_img_per_min": 9.3, "mem_gib": 35.9, "status": "JSON valid 55.1% (OCR model, not a JSON reader)"},
        {"model": "PaddleOCR-VL-1.6", "cer": 0.976, "key_em": 0.009, "fab_num": 0.0, "p50_s": 21.30, "p90_s": 21.36, "c4_img_per_min": 11.9, "mem_gib": 34.9, "status": "JSON valid 10.2%"},
    ],
    "failed": [
        {"model": "Gemma 4 31B-it QAT", "why": "0/98 usable, all HTTP 500 (token 0 only)"},
        {"model": "Phi-4-reasoning-vision-15B", "why": "failed to start: siglip2 lacks filter_out_non_signature_kwargs in transformers 5.17"},
        {"model": "DeepSeek-OCR-2", "why": "failed to start: Triton kernel compile error (LOG2E not constexpr)"},
        {"model": "Keye-VL-2.0-30B-A3B", "why": "failed to start: architecture not in vLLM 0.30.0; needs fast_hadamard_transform"},
        {"model": "ERNIE-4.5-VL-28B-A3B-Thinking", "why": "failed to start: missing decord"},
        {"model": "Mistral Small 4 (vision)", "why": "failed to start (Pixtral import)"},
        {"model": "DeepSeek-V4-Flash", "why": "text-only: HTTP 400 on images"},
    ],
    "organizer_path": {"source": "skills/image-read/BENCHMARK.md", "type_correct": [0.980, 1.000], "key_em": [0.962, 0.988], "qa_answerable": [0.993, 0.993], "fab_num_ex_gist": [0.009, 0.005], "p50_s": [4.09, 3.87], "p90_s": [6.58, 6.32]},
}

embeddings = {
    "source": "eval/retrieval/README.md; eval/models-v2/embeddings/summary.json",
    "candidate_event_R5": [
        {"model": "Qwen3-Embedding-0.6B (default)", "dev": 0.986, "holdout": 1.0, "stress": 0.981, "p50_ms": 25, "mem_gib": 5.9},
        {"model": "Qwen3-Embedding-4B", "dev": 1.0, "holdout": 1.0, "stress": 0.990, "p50_ms": 43, "mem_gib": 18.7},
        {"model": "char-bigram hash (lexical)", "dev": 0.928, "holdout": 0.971, "stress": 0.760, "p50_ms": 0.03, "mem_gib": 0},
        {"model": "no vectors", "dev": 0.783, "holdout": 0.886, "stress": 0.596},
    ],
    "item_level_R5": [
        {"model": "Qwen3-VL-Embedding-8B", "dev": 0.868, "holdout": 0.854},
        {"model": "Nemotron-3-Embed-8B", "dev": 0.795, "holdout": 0.835},
        {"model": "Qwen3-Embedding-0.6B (default)", "dev": 0.798, "holdout": 0.839},
    ],
}

system_one = {
    "source": "eval/system_one/RESULTS.md (evaluation only, off by default)",
    "test_1953": [
        {"model": "retrieval top-1 (no model)", "acc": 0.773, "ece": 0.227, "coverage": 0.0},
        {"model": "25 retrieval features, logistic (no text)", "acc": 0.840, "ece": 0.038, "coverage": 0.656, "fast_precision": 0.973},
        {"model": "Qwen3-Reranker-0.6B fine-tuned (served)", "acc": 0.769, "ece": 0.021, "coverage": 0.466, "fast_precision": 0.974, "p50_ms": 419},
        {"model": "Laya multilingual fine-tuned", "acc": 0.141, "ece": 0.005, "coverage": 0.017},
    ],
    "test_300_sample": [
        {"model": "System Two: Qwen3.6 direct (answer logprob)", "acc": 0.830, "p50_ms": 1330},
        {"model": "System Two: event-assign skill", "acc": 0.797, "decides": 0.887, "precision_when_deciding": 0.898, "p50_ms": 13955},
        {"model": "Qwen3-Reranker-0.6B fine-tuned", "acc": 0.763, "coverage": 0.460, "fast_precision": 0.949, "p50_ms": 419},
    ],
    "verdict": "did not pass: reranker 76.9% < retrieval top-1 77.3% on TEST; not wired in",
}

file_read_v1 = {
    "source": "skills/file-read/BENCHMARK.md (files-v1 test, 40 files, 20 templates, n=2)",
    "type_ok": "40/40", "parsed_text_recall": 1.0, "picture_text_recall": 1.0, "summary_topic_hit": [0.988, 0.950],
    "first_try_valid": "36/38", "key_fields": "6/6 files", "p50_s": [7.4, 7.8], "p90_s": [25.0, 33.1],
    "parse_only_60_files": {"type_ok": "60/60", "text_recall": 1.0, "p50_s": 0.07},
}

mac = {
    "source": "bestASR DICTATION_ARCHITECTURE.md §2/§4/§5; IMPLEMENTATION_STATUS.md (Round 7; speaker freeze line 1444); aggregates of the user's own dictation only",
    "dictation_recognizers_240": [
        {"model": "Qwen3-ASR 1.7B 8-bit + 41-term list (final, default)", "cer": 0.0374, "eng_terms": "30/41", "decode_p50_ms": 939},
        {"model": "Qwen3-ASR 1.7B bf16 (H100 reference)", "cer": 0.0378, "eng_terms": "29/41", "decode_p50_ms": 710},
        {"model": "FireRedASR2-AED (75-item subset)", "cer": 0.0407, "eng_terms": "6/10", "decode_p50_ms": 1367},
        {"model": "Fun-ASR-Nano-2512", "cer": 0.0469, "eng_terms": "27/41", "decode_p50_ms": 396},
        {"model": "SenseVoice small int8 (live draft)", "cer": 0.0575, "eng_terms": "24/41", "decode_p50_ms": 150},
    ],
    "feature_bug_fix_40_proofread": {"cer_before": 0.0320, "cer_after": 0.0271, "eng_terms_before": 0.68, "eng_terms_after": 0.76},
    "release_to_insert_ms": {"p50": 545, "p90": 635, "n": 24},
    "memory_gb": {"dictating": 5.17, "idle": 0.93},
    "cleanup_model": {"model": "Qwen3-0.6B 8-bit LoRA + faithfulness guard", "precision_vs_proofread": 0.9812, "gen_p50_ms": 193, "size_mb": 630},
    "rejected": {"personal ASR LoRA": "CER 2.57% -> 8.43%", "auto-picked term list": "4.06% vs 3.74% hand-picked"},
    "public_profiles": {"Paraformer-large Mandarin FLEURS CER": 0.0917, "Parakeet Unified English FLEURS WER": 0.0780},
    "speaker_ami_holdout": {"model": "FluidAudio 0.15.5 + fluid-speaker-diarization-coreml", "speaker_confusion": 0.0207, "known_person_misid": 0,
                            "false_merges": 0, "known_queries": "15/16", "unknown_rejections": "16/16", "rtf": 0.0056, "peak_rss_gb": 0.71,
                            "der": 0.2493, "jer": 0.3178},
}

# ---------------------------------------------------------------- new v5 measurements
ledger = jl(HERE / "ledger_latency.json")
split = {k: jl(HERE / f"split-{k}.json") for k in ("lab", "startup", "pm")}
egress = jl(HERE / "egress.json")
mf = {}
for tag, fn in (("parse_only", "multiformat-parse-only-score.json"), ("full_path", "multiformat-full-score.json"),
                ("full_path_r2", "multiformat-full-r2-score.json")):
    p = HERE / fn
    if p.exists():
        mf[tag] = jl(p)["summary"]
mf_meta = HERE / "multiformat-full-meta.json"
MAC_ROUTED = {"heic", "mp4", "mov"}  # the Mac converts HEIC and sends video as audio transcript + keyframe images
for tag, fn in (("parse_only", "multiformat-parse-only-score.json"), ("full_path", "multiformat-full-score.json"),
                ("full_path_r2", "multiformat-full-r2-score.json")):
    p = HERE / fn
    if p.exists():
        rows = [r for r in jl(p)["files"] if r["type"] not in MAC_ROUTED]
        hits = sum(sum(r["qa_hits"]) for r in rows); n = sum(len(r["qa_hits"]) for r in rows)
        kl = [r["key_line_recall"] for r in rows if r.get("key_line_recall") is not None]
        mf.setdefault("excluding_mac_routed_types", {})[tag] = {"formats": 30, "files": len(rows), "qa_n": n,
            "answer_present": round(hits / n, 4), "key_line_recall": round(sum(kl) / len(kl), 4)}

brief_waste = {}
SC = Path("<demo>/scale")
for sc in ("lab", "startup", "pm"):
    runs = jl(HERE / "lab-runs-tokens.json") if sc == "lab" else jl(SC / sc / "score/spark-db-extract.json")["runs"]
    tot = sum(r["prompt_tokens"] or 0 for r in runs)
    rej = sum(r["prompt_tokens"] or 0 for r in runs if r["skill"] == "event-brief" and not r["ok"])
    s = ledger[sc]["skills"]["event-brief"]
    brief_waste[sc] = {"brief_calls": s["calls"], "accepted_share": s["ok_rate"], "share_of_prompt_tokens": s["share_of_prompt_tokens"],
                       "share_of_call_seconds": s["share_of_call_seconds"],
                       "rejected_brief_share_of_all_prompt_tokens": round(rej / tot, 3)}

skill_cases = None
if (HERE / "skill-evals-main-n3.json").exists():
    se = jl(HERE / "skill-evals-main-n3.json")
    per = {}
    for c in se["cases"]:
        a = per.setdefault(c["skill"], {"cases": 0, "all_pass_cases": 0, "passes": 0, "runs": 0, "failing": []})
        a["cases"] += 1; a["passes"] += c["passes"]; a["runs"] += c["n"]; a["all_pass_cases"] += c["passes"] == c["n"]
        if c["passes"] < c["n"]:
            a["failing"].append(f"{c['id']} {c['passes']}/{c['n']}")
    skill_cases = {"source": "eval/run_skill_evals.py --n 3 on main 0f48a71, Qwen3.6-35B-A3B NVFP4 on spark-n4 (v5 run)",
                   "summary": se["summary"], "per_skill": per,
                   "note": "split-005-injection: the injected instruction was never obeyed; in 2/3 runs the injected sentence was kept as its own aside segment instead of being skipped, which the case counts as a fail"}

out = {
    "meta": {"title": "织机 Mindloom evaluation v5", "date": "2026-09-29", "data": "synthetic only on every Spark; Mac speech numbers are aggregates of the user's own dictation",
             "hardware": "NVIDIA DGX Spark (GB10, 121 GiB unified memory), vLLM 0.30.0; Mac: Apple Silicon",
             "default_models": {"organizer + image-read + file-read": "Qwen3.6-35B-A3B NVFP4 (vLLM, MTP x3, fp8 KV)", "retrieval": "Qwen3-Embedding-0.6B",
                                "dictation final": "Qwen3-ASR 1.7B 8-bit (MLX)", "dictation draft": "SenseVoice small int8 (Core ML)",
                                "cleanup": "Qwen3-0.6B 8-bit LoRA", "speaker": "FluidAudio 0.15.5 + fluid-speaker-diarization-coreml",
                                "translation": "macOS Translation framework", "voice commands": "Qwen3-1.7B MLX 4-bit"}},
    "scale_runs": scale,
    "skills_ablation": ablation,
    "skill_eval_cases": skill_cases,
    "organizer_models": {"code": "2e532bc (skills event-assign 2.1.0, event-brief 1.4.0, home-rank 1.3.0, item-split 1.1.1, image-read 1.0.0)",
                         "holdout-week-v2": agg("holdout-week-v2"), "dev-week-v1": agg("dev-week-v1"), "not_scored": org_failed, "runs": org_rows},
    "per_skill_latency_tokens": ledger,
    "event_brief_rejections": brief_waste,
    "item_split_production": {"method": "data/split_boundary.py on each scale run's organizer.db (no new model calls)", **split},
    "image_read": image_models,
    "embeddings": embeddings,
    "file_read": {"files_v1": file_read_v1, "multiformat_33": mf},
    "system_one": system_one,
    "mac": mac,
    "privacy_egress": egress,
}
if mf_meta.exists():
    out["file_read"]["multiformat_33_meta"] = jl(mf_meta)
(V5 / "eval.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
print("wrote", V5 / "eval.json", "org rows", len(org_rows))
for scn in ("holdout-week-v2", "dev-week-v1"):
    for a in out["organizer_models"][scn]:
        print(scn, a["label"], a["n"], a["b3_f1_mean"], a["b3_f1_range"], a["card_fact_recall_mean"], a["hard_decoy_leakage_mean"], a["s_per_item_mean"])
