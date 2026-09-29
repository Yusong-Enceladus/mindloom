"""Regressions for eval/score.py: noise, asks, plan-vs-done, home ranking, UI fit (no model).

Uses the synthetic dev scenario and the committed dev snapshots under eval/runs (dev only; holdout
outputs are never read here).
"""

import copy
import json
import sys

import pytest

from conftest import REPO

sys.path.insert(0, str(REPO / "eval"))
import score  # noqa: E402

DEV = json.loads((REPO / "eval/scenarios/dev-week-v1/scenario.json").read_text(encoding="utf-8"))
HOLDOUT = json.loads((REPO / "eval/scenarios/holdout-week-v1/scenario.json").read_text(encoding="utf-8"))
R1 = score.load_snapshots(str(REPO / "eval/runs/dev-skills-qwen-r1/snapshots"))
REF = {it["ref"]: it["item_id"] for it in DEV["items"]}
NOISE = [it["item_id"] for it in DEV["items"] if not it["events"]]


def gold_state(cp_id, status=None, importance=None):
    """A perfect clustering at a checkpoint: one event per gold event (first label), ids ev_*."""
    gold = score.Gold(DEV)
    cp = next(c for c in DEV["checkpoints"] if c["checkpoint_id"] == cp_id)
    at = gold.item_order(cp["after_item_id"])
    events = {}
    for it in gold.items[: at + 1]:
        labels = [e for e in it["events"] if DEV and any(ev["event_id"] == e and ev["kind"] != "noise" for ev in DEV["events"])]
        eid = labels[0] if labels else "noise-" + it["ref"]
        e = events.setdefault(eid, {"event_id": eid, "title": eid, "status_line": (status or {}).get(eid, ""),
                                    "status_facts": [], "item_ids": [], "importance": (importance or {}).get(eid, 0.5),
                                    "importance_reason": "r" if importance else "", "updated_at": it["t"]})
        e["item_ids"].append(it["item_id"])
        e["updated_at"] = it["t"]
    return {"events": list(events.values())}


# ---- noise (R11) ----------------------------------------------------------------------------------

def test_noise_singletons_versus_unfiled_on_a_real_snapshot():
    base = score.score(DEV, R1)["summary"]
    assert base["noise_singleton_rate"] == 1.0 and base["noise_unfiled_rate"] == 0
    stripped = copy.deepcopy(R1)
    for snap in stripped.values():
        for e in snap["events"]:
            e["item_ids"] = [i for i in e["item_ids"] if i not in NOISE]
    s = score.score(DEV, stripped)["summary"]
    assert s["noise_unfiled_rate"] == 1.0 and s["unfiled_precision"] == 1.0
    assert s["bcubed_f1"] == pytest.approx(0.800, abs=0.002) and base["bcubed_f1"] == pytest.approx(0.782, abs=0.002)
    leaked = copy.deepcopy(stripped)
    final = leaked["cp-final"]
    big = max((e for e in final["events"] if not e.get("deleted")), key=lambda e: len(e["item_ids"]))
    big["item_ids"].append(NOISE[0])
    assert score.score(DEV, leaked)["summary"]["noise_in_real_event_rate"] > 0
    lost = copy.deepcopy(stripped)
    real = [i for e in lost["cp-final"]["events"] for i in e["item_ids"]][:5]
    for e in lost["cp-final"]["events"]:
        e["item_ids"] = [i for i in e["item_ids"] if i not in real]
    assert score.score(DEV, lost)["summary"]["false_unfiled"] == 5


# ---- questions (R12, R13) -------------------------------------------------------------------------

def _event_with(snap, item_id):
    return next(e["event_id"] for e in snap["events"] if item_id in e["item_ids"] and not e.get("deleted"))


def test_ask_usefulness_uses_the_membership_at_ask_time():
    snap = copy.deepcopy(R1["cp-final"])
    reno = _event_with(snap, REF["d1-02"])
    snap["questions"] = [
        {"kind": "same_event", "a": REF["d1-15"], "b": reno, "status": "open", "day_key": "2026-09-14",
         "provisional": {"action": "new"}, "b_items_at_ask": [REF["d1-02"], REF["d1-03"]]},
        {"kind": "same_event", "a": REF["d6-03"], "b": "merged-away", "status": "expired", "day_key": "2026-09-19",
         "provisional": {"action": "new"}, "b_items_at_ask": [REF["d2-01"], REF["d2-02"]]},
        {"kind": "same_event", "a": REF["d6-01"], "b": "gone-without-record", "status": "expired", "day_key": "2026-09-19"},
    ]
    snap["questions_asked_total"] = 3
    q = score.score(DEV, {"cp-final": snap})["final"]["questions"]
    assert q["resolvable"] == 2 and q["unresolvable_merged"] == 1
    assert q["true_yes_rate"] == 0.5          # d1-15 is not the renovation; d6-03 is mom's flat
    assert q["ask_useful_rate"] == 0.5        # only the second question had a wrong provisional placement
    assert q["asks_total"] == 3 and q["max_asks_per_day"] == 2


# ---- plan-vs-done and card audits (R10) -----------------------------------------------------------

def test_plan_written_as_done_is_a_violation_not_a_recall():
    bad = gold_state("cp-final", status={"ev_momflat": "防水重做工程已于9月22日按计划完成，报价2800元。"})
    good = gold_state("cp-final", status={"ev_momflat": "报价2800元包工包料，定于9月22日（周二）开工。"})
    rb = score.score(DEV, {"cp-final": bad})
    rg = score.score(DEV, {"cp-final": good})
    det_b = rb["checkpoints"][-1]["status_details"]["ev_momflat"]
    det_g = rg["checkpoints"][-1]["status_details"]["ev_momflat"]
    assert det_b.get("plan_as_done") == ["f_mom_start"] and "f_mom_start" not in det_b["recalled"]
    assert "f_mom_start" in det_g["recalled"] and not det_g.get("plan_as_done")
    assert rb["summary"]["unsupported_completion"] == 1 and rg["summary"]["unsupported_completion"] == 0


def test_card_audit_flags_real_failures_on_committed_dev_snapshots():
    oracle = score.load_snapshots(str(REPO / "eval/runs/dev-oracle-skills-qwen/snapshots"))
    s = score.score(DEV, oracle)["summary"]
    assert s["unsupported_completion"] >= 3   # 水电已验收 / 已签月试用合同 written from plans
    assert s["plan_as_done"] >= 1
    assert s["relative_date_in_card"] > 0


# ---- home ranking (S1, S2) ------------------------------------------------------------------------

GRADE_ORDER = {"ev_lease": 0.95, "ev_beans": 0.9, "ev_reno": 0.9, "ev_sign": 0.85, "ev_menu": 0.6, "ev_anniv": 0.55,
               "ev_member": 0.5, "ev_momflat": 0.3, "ev_grinder": 0.2}


def _home(state):
    return score.score(DEV, {"cp-d2": state})["checkpoints"][0]["home"]


def test_home_metrics_reward_the_graded_order_and_count_gross_inversions():
    perfect = _home(gold_state("cp-d2", importance=GRADE_ORDER))
    assert perfect["rank_ran"] and perfect["ndcg5"] == pytest.approx(1.0) and perfect["gross_inversions"] == 0
    swapped = dict(GRADE_ORDER, ev_grinder=0.99, ev_lease=0.1)  # the grinder-over-lease failure
    h = _home(gold_state("cp-d2", importance=swapped))
    assert h["gross_inversions"] >= 1 and h["ndcg5"] < 1
    never = score.score(DEV, {"cp-d2": gold_state("cp-d2")})
    assert never["checkpoints"][0]["home"]["rank_ran"] is False
    assert never["summary"]["home_ndcg5"] is None
    noisy = gold_state("cp-d2", importance=dict(GRADE_ORDER, **{"noise-d1-13": 1.0}))
    assert _home(noisy)["clutter5"] == 1


def test_home_grades_are_validated():
    sc = copy.deepcopy(DEV)
    del sc["checkpoints"][0]["home"]["grades"]["ev_grinder"]
    errors, _ = score.validate_scenario(sc)
    assert any("miss ev_grinder" in e for e in errors)
    ho = copy.deepcopy(HOLDOUT)
    ho["checkpoints"][0]["home"]["grades"]["ev_tablet"] = 1
    errors, _ = score.validate_scenario(ho)
    assert any("ev_tablet" in e and "no items yet" in e for e in errors)
    assert score.validate_scenario(DEV)[0] == [] and score.validate_scenario(HOLDOUT)[0] == []


def test_committed_dev_run_home_metrics_match_the_prototype():
    s = score.score(DEV, R1)["summary"]
    assert s["home_ndcg5"] == pytest.approx(0.821, abs=0.001)
    assert s["home_ndcg5_recency"] == pytest.approx(0.560, abs=0.001)
    assert s["home_gross_inversions"] == 4


# ---- UI fit (U1) ----------------------------------------------------------------------------------

def test_ui_fit_flags_long_titles_and_lines():
    bare = score.load_snapshots(str(REPO / "eval/runs/dev-bare-qwen-r2/snapshots"))
    cp = score.score(DEV, bare)["checkpoints"][2]
    assert cp["checkpoint_id"] == "cp-d5" and cp["ui_fit"]["titles_over"] >= 1 and cp["ui_fit"]["status_over"] >= 1
    s = score.score(DEV, R1)["summary"]
    assert s["ui_titles_over_20"] == 0 and s["ui_status_over_54"] == 0


def test_decoy_seed_and_absorbed_matters():
    s = score.score(DEV, R1)["summary"]
    assert s["decoy_seed_ok"] == "2/2"
    assert "ev_anniv" in s["absorbed_matters"]  # the anniversary market never got its own event in r1
    r2 = score.score(DEV, score.load_snapshots(str(REPO / "eval/runs/dev-skills-qwen-r2/snapshots")))["summary"]
    assert r2["decoy_seed_ok"] == "1/2"         # d1-15 attached to the renovation
