"""Summarize a capped (unfinished) organizer eval run: per-job call stats from its organizer.db and the
checkpoint-level scores of the snapshots it reached (eval/score.py per checkpoint). Aggregates only.

usage: python3 partial_run.py RUN_DIR REPO_DIR SCENARIO_JSON
"""
import glob
import json
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "spark"))
from organizer.db import open_for_analysis  # noqa: E402

run, repo, scen = map(Path, sys.argv[1:4])
db = glob.glob(str(run / "data" / "*.db"))[0]
c = open_for_analysis(db)  # plaintext, or encrypted with the synthetic key
jobs = c.execute("select count(*), sum(state='done') from jobs").fetchone()
items_done = c.execute("select count(*) from jobs where state='done' and reason='ingest'").fetchone()[0]
per = {}
for jt, st, en, ok, att, pt, ct in c.execute(
        "select job_type, started_at, ended_at, ok, attempts, prompt_tokens, completion_tokens from runs"):
    per.setdefault(jt, []).append((en - st, ok, att or 1, pt or 0, ct or 0))
jobstats = {}
for jt, rows in per.items():
    lat = sorted(r[0] for r in rows)
    jobstats[jt] = {"calls": len(rows), "ok": sum(r[1] for r in rows), "retried": sum(1 for r in rows if r[2] > 1),
                    "latency_p50_s": round(statistics.median(lat), 1), "latency_max_s": round(lat[-1], 1),
                    "prompt_tokens_mean": round(statistics.mean(r[3] for r in rows)),
                    "completion_tokens_mean": round(statistics.mean(r[4] for r in rows))}
t = c.execute("select min(started_at), max(ended_at) from runs").fetchone()
with tempfile.TemporaryDirectory() as td:
    out = Path(td) / "s.json"
    subprocess.run([sys.executable, str(repo / "eval/score.py"), "--gold", str(scen), "--snapshots", str(run / "snapshots"),
                    "--json", str(out)], cwd=repo, capture_output=True, text=True)
    cps = []
    if out.exists():
        s = json.loads(out.read_text())
        have = {p.stem for p in (run / "snapshots").glob("*.json")}
        for cp in s.get("checkpoints", []):
            if cp["checkpoint_id"] in have:
                cps.append({k: cp.get(k) for k in ("checkpoint_id", "n_items", "bcubed_f1", "link_f1", "pred_event_count",
                                                   "gold_event_count", "card_recalled", "expected", "ungrounded_card_dates")})
print(json.dumps({"jobs_total_done": list(jobs), "items_done": items_done, "wall_s_model_calls": round(t[1] - t[0]),
                  "s_per_item": round((t[1] - t[0]) / max(1, items_done), 1), "per_job": jobstats, "checkpoints": cps}))
