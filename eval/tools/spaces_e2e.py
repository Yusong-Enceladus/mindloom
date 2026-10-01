#!/usr/bin/env python3
"""Shared spaces end to end against a running organizer (SPACES-CONTRACT section 5, E2E). Synthetic data only.

Two synthetic Mac roots (A and B: device keys, space keys and originals in their own directories, marked
SYNTHETIC_DATA_ROOT) and one Spark instance with its real model:
  1. A creates an org and an org space and invites B; B joins (A opens B's sealed name).
  2. Both share their version of the same matter (originals encrypted to the members, the organizing payload
     masked by the space's mask key).
  3. The space organizer (real model) assembles the shared matter: the union of the items, and "same_as" links
     to both personal matters.
  4. B withdraws one item; A removes B (the space key rotates).
  5. B can no longer read anything new; the space store is re-keyed at A's next lease; the withdrawn item is gone.
  6. The Spark's data directory holds no plaintext sentinel (--data-dir, when run on the Spark).

    spaces_e2e.py --uds <data_dir>/organizer.sock --token-file <data_dir>/link_token --roots <dir> [--data-dir <dir>]
    spaces_e2e.py --url http://127.0.0.1:<forwarded port> --token-file <local copy> --roots <dir>

The token is read from the file and sent only in the Authorization header; it is never printed. The output is
JSON with ids, counts, pass/fail and the assembled matter's (synthetic) title. Exit status 0 = every check passed.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "spark"))
sys.path.insert(0, str(ROOT / "spark" / "tests"))

import httpx  # noqa: E402
from cryptography.exceptions import InvalidTag  # noqa: E402

from organizer import space_member as sm  # noqa: E402
from spacekit import Mac, new_id  # noqa: E402

TZ = timezone(timedelta(hours=8))
SENTINELS = ["哨兵A拾光ZQ7", "哨兵B拾光ZQ8", "13700004321", "shiguang.owner@example.com"]
A_TEXTS = [f"拾光咖啡馆开业筹备：开业日期定在10月18日周六，{SENTINELS[0]}，装修队周三完工。",
           f"拾光咖啡馆开业筹备：装修尾款还差两万，找施工队王工对账，电话 {SENTINELS[2]}。"]
B_TEXTS = [f"拾光咖啡馆开业筹备：咖啡豆供应商报价每公斤120元，下周二前确认，{SENTINELS[1]}。",
           f"拾光咖啡馆开业筹备：开业菜单打样周五出，发到 {SENTINELS[3]} 给老板过目。"]


class WallClock:
    def __call__(self) -> float:
        return time.time()


class Root:
    """A synthetic Mac data root (keys and originals as files, mode 0600)."""

    def __init__(self, path: Path, mac: Mac):
        self.path, self.mac = path, mac
        path.mkdir(parents=True, exist_ok=False)
        os.chmod(path, 0o700)
        (path / "SYNTHETIC_DATA_ROOT").write_text("synthetic\n")
        self.save()

    def save(self) -> None:
        state = {"device_id": self.mac.device.device_id, "member_id": self.mac.member_id,
                 "sign_priv": self.mac.device.sign_priv.hex(), "seal_priv": self.mac.device.seal_priv.hex(),
                 "space_keys": {s: {str(e): k.hex() for e, k in ks.items()} for s, ks in self.mac.space_keys.items()}}
        p = self.path / "keys.json"
        p.write_text(json.dumps(state))
        os.chmod(p, 0o600)

    def keep(self, item_id: str, text: str) -> None:
        p = self.path / f"{item_id}.txt"
        p.write_text(text, encoding="utf-8")
        os.chmod(p, 0o600)


def item_payload(item_id: str, text: str, t: datetime, origin: str) -> dict:
    import secrets
    return {"item_id": item_id, "revision": 1, "kind": "dictation",
            "source_app": {"bundle_id": "com.apple.Notes", "name": "备忘录"},
            "started_at": t.isoformat(), "ended_at": (t + timedelta(minutes=1)).isoformat(),
            "text": text, "sha256": secrets.token_hex(32), "origin_matter_id": origin}


def wait_organized(mac: Mac, sid: str, timeout: float) -> dict:
    deadline = time.time() + timeout
    last = {}
    while time.time() < deadline:
        r = mac.get(f"/v1/spaces/{sid}/organizer/state")
        if r.status_code == 200:
            last = r.json()
            if last["busy"]["queue"] == 0 and last["busy"]["briefs"] == 0 and \
                    any(not e["deleted"] for e in last["events"]):
                return last
        time.sleep(3)
    raise SystemExit(json.dumps({"ok": False, "error": "organizing timed out", "busy": last.get("busy")}))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--uds")
    ap.add_argument("--url")
    ap.add_argument("--token-file", required=True)
    ap.add_argument("--roots", required=True, help="an empty directory for the two synthetic Mac roots")
    ap.add_argument("--data-dir", help="the organizer's data directory (sentinel scan; on the Spark only)")
    ap.add_argument("--timeout", type=float, default=900)
    a = ap.parse_args(argv)
    for p in (a.roots, a.data_dir or ""):
        if "Application Support" in p:
            raise SystemExit("refusing: synthetic data only")
    token = Path(a.token_file).expanduser().read_text().strip()
    transport = httpx.HTTPTransport(uds=a.uds) if a.uds else None
    client = httpx.Client(base_url=a.url or "http://organizer", transport=transport, trust_env=False, timeout=120,
                          headers={"Authorization": f"Bearer {token}"})
    del token
    roots = Path(a.roots).expanduser().resolve()
    run = roots / time.strftime("run-%Y%m%d-%H%M%S")
    clock = WallClock()
    A, B = Mac(client, clock, "A"), Mac(client, clock, "B")
    rootA, rootB = Root(run / "mac-A", A), Root(run / "mac-B", B)
    checks: dict[str, bool] = {}
    t0 = time.time()

    # 1. create, invite, join
    org_id = A.create_org()
    sid = A.create_space("org", org_id, name="拾光合伙人")
    host_keys = client.get("/v1/spaces/host-keys").json()["host_keys"]
    inv = A.invite(sid, role="write", host_key=host_keys[0] if host_keys else None)
    checks["1_invite_pins_host_key"] = inv["result"]["ok"] and bool(host_keys)
    r = B.request_join(sid, inv, name="韩策")
    req = A.get(f"/v1/spaces/{sid}/join-requests", status="pending").json()["requests"][0]
    checks["1_join_profile_opens"] = sm.open_profile(req["profile"], A.device.seal_priv, sid,
                                                     req["request_id"]) == {"display_name": "韩策"}
    checks["1_joined"] = r.status_code == 200 and A.approve(sid, req["request_id"])["ok"]
    B.sync_keys(sid)
    rootA.save()
    rootB.save()

    # 2. both share their version of the same matter
    now = datetime.now(TZ).replace(microsecond=0)
    shared: dict[str, tuple] = {}
    for mac, root, texts, matter, base in ((A, rootA, A_TEXTS, "personal-A-shiguang", 0),
                                           (B, rootB, B_TEXTS, "personal-B-cafe", 20)):
        ids = []
        for n, text in enumerate(texts):
            s = mac.share(sid, text, original=f"原件：{text}".encode())
            assert s["result"]["ok"], s["result"]
            root.keep(s["item_id"], text)
            ids.append(s["item_id"])
            shared[s["item_id"]] = (mac, text, now - timedelta(minutes=60 - base - n * 5), matter)
        op_id = new_id()
        assert mac.op(sid, "matter.share", {"package_id": new_id(), "item_ids": ids}, epoch=1, op_id=op_id,
                      enc=sm.enc_op(mac.key(sid), {"title": "拾光开业", "matter_id": matter}, sid, op_id))["ok"]
    checks["2_members_open_all_originals"] = set(A.read_items(sid)) == set(shared) == set(B.read_items(sid))

    # 3. the space organizer assembles the shared matter
    checks["3_lease"] = A.lease(sid).status_code == 200
    for item_id, (mac, text, t, matter) in shared.items():
        res = mac.organize(sid, [item_payload(item_id, text, t, matter)])
        assert res.status_code == 200, res.text
    st = wait_organized(A, sid, a.timeout)
    live = [e for e in st["events"] if not e["deleted"]]
    biggest = max(live, key=lambda e: len(e["item_ids"]))
    checks["3_union_in_one_matter"] = set(biggest["item_ids"]) == set(shared)
    checks["3_same_as_both_members"] = {(l["member_id"], l["matter_id"]) for l in st["same_as"]
                                        if l["event_id"] == biggest["event_id"]} == \
        {(A.member_id, "personal-A-shiguang"), (B.member_id, "personal-B-cafe")}
    blob = json.dumps(st, ensure_ascii=False)
    checks["3_state_has_placeholders_only"] = SENTINELS[2] not in blob and SENTINELS[3] not in blob
    assembled = {"events": len(live), "biggest_items": len(biggest["item_ids"]), "title": biggest["title"],
                 "status_line": biggest["status_line"], "facts": len(biggest["status_facts"])}

    # 4. B withdraws one item; A removes B
    b_items = [i for i, v in shared.items() if v[0] is B]
    checks["4_withdraw"] = B.op(sid, "item.withdraw", {"item_id": b_items[0]})["ok"]
    checks["4_remove"] = A.remove_member(sid, B.member_id)["ok"]
    rootA.save()

    # 5. rotation: B can no longer read new items; the space store is re-keyed at A's next lease
    new = A.share(sid, "拾光咖啡馆开业筹备：开业当天排班表周四定。")
    rootA.keep(new["item_id"], "拾光咖啡馆开业筹备：开业当天排班表周四定。")
    checks["5_new_item_epoch_2"] = new["result"]["effects"]["epoch"] == 2
    checks["5_b_refused"] = B.get(f"/v1/spaces/{sid}/ops").status_code == 403
    wrapped = next(o["item_key"] for o in A.get(f"/v1/spaces/{sid}/ops", limit=1000).json()["ops"]
                   if o["type"] == "item.share" and o.get("item_key")
                   and json.loads(sm.sc.b64u_decode(o["op"]))["body"]["item_id"] == new["item_id"])
    try:
        sm.unwrap_item_key(wrapped["wrapped_dk"], B.key(sid), sid, wrapped["epoch"], new["item_id"])
        checks["5_b_cannot_unwrap"] = False
    except InvalidTag:
        checks["5_b_cannot_unwrap"] = True
    checks["5_old_key_refused"] = A.lease(sid).json().get("error") == "wrong_key"
    checks["5_rekeyed_lease"] = A.lease(sid, previous_epoch=1).status_code == 200
    A.organize(sid, [item_payload(new["item_id"], "拾光咖啡馆开业筹备：开业当天排班表周四定。", now, "personal-A-shiguang")])
    st = wait_organized(A, sid, a.timeout)
    items = {i for e in st["events"] if not e["deleted"] for i in e["item_ids"]}
    checks["5_withdrawn_gone"] = b_items[0] not in items
    checks["5_contribution_kept"] = b_items[1] in items and new["item_id"] in items
    A.post_json(f"/v1/spaces/{sid}/organizer/lock", {})

    # 6. no plaintext sentinel on the Spark
    if a.data_dir:
        data = Path(a.data_dir).expanduser()
        hits = 0
        for p in data.rglob("*"):
            if p.is_file() and not p.is_symlink() and not p.name.endswith(".sock"):
                blob = p.read_bytes()
                hits += sum(1 for s in SENTINELS + ["韩策", "拾光合伙人"] if s.encode() in blob)
        checks["6_no_plaintext_on_spark"] = hits == 0
    out = {"ok": all(checks.values()), "space_id": sid, "checks": checks, "assembled": assembled,
           "seconds": round(time.time() - t0, 1), "roots": str(run)}
    print(json.dumps(out, ensure_ascii=False, indent=1))
    return 0 if out["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
