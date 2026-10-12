#!/usr/bin/env python3
"""Were the scenario's screenshots filed with the right matter? For every image item in the three synthetic scenarios and
each run directory written by run_router_bench.sh part 2 (and its dev repeats), look at the event the screenshot ended in
and take the gold matter most of that event's other items belong to; the screenshot is right when that matter is one of
its own gold matters. No model is called.   usage: shots_placement.py OUT_DIR [scenarios_dir]
"""
import json,glob,collections,sys
out=sys.argv[1]; scen=sys.argv[2] if len(sys.argv)>2 else "eval/scenarios"
res={}
for sc in ["dev-week-v1","holdout-week-v1","holdout-week-v2"]:
    s=json.load(open(f"{scen}/{sc}/scenario.json"))
    by={i["item_id"].lower():i for i in s["items"]}
    shots=[i for i in s["items"] if i["kind"]=="image"]
    for cond in ["allqwen","router","allqwen-r2","router-r2"]:
        fs=sorted(glob.glob(f"{out}/e2e-{sc}-{cond}/snapshots/*final*.json")) or sorted(glob.glob(f"{out}/e2e-{sc}-{cond}/snapshots/*.json"))
        if not fs: continue
        snap=json.load(open(fs[-1]))
        evs=[e for e in snap["events"] if not e.get("deleted")]
        ok=0; tot=0; detail=[]
        for sh in shots:
            tot+=1
            home=[e for e in evs if sh["item_id"].lower() in [x.lower() for x in e["item_ids"]]]
            if not home: detail.append((sh["ref"],"unplaced")); continue
            c=collections.Counter(g for x in home[0]["item_ids"] if x.lower()!=sh["item_id"].lower() for g in (by[x.lower()].get("events") or []))
            top=c.most_common(1)[0][0] if c else None
            good= top in (sh.get("events") or [])
            ok+=good; detail.append((sh["ref"],"ok" if good else f"wrong({top})"))
        print(sc,cond,f"{ok}/{tot}",detail)
