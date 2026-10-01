#!/usr/bin/env python3
"""v8 contract C end to end against a deployed instance, every member Mac through the Spark's real sshd and its own
bridge: a member's second Mac (device ticket, device.add, org.device_add), a meeting segment's audio shared to the
members (ciphertext on the Spark, opened on another member's Mac, gone after the withdraw), a share sent again and
remade (accepted once), a snapshot removed with the item it cites, an org admin added as a signed op, the second Mac
unpaired and retired. Synthetic data only.

  spaces_c_e2e.py --owner-ssh <ssh alias with the owner's shell> --env <instance env.sh on the Spark>
                  --owner-call <the deployed spark/owner-call.py on the Spark>
                  --member-host <user@host the member keys log in to> [--proxy-command "ssh -W %h:%p <relay>"]
                  --keys <local dir for the throwaway keys> --out <summary.json>

Owner calls run on the Spark (spark/owner-call.py reads the link token there). At the end every Mac is unpaired and
authorized_keys is compared with its SHA-256 from before. The summary holds check names, counts and the hash prefix
only."""

from __future__ import annotations

import argparse
import json
import os
import secrets
import struct
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "spark"))
sys.path.insert(0, str(REPO / "spark" / "tests"))

from organizer import space_crypto as sc  # noqa: E402
from organizer import space_member as sm  # noqa: E402
from organizer.access import enroll_request, ticket_hash  # noqa: E402
from spacekit import Mac, new_id  # noqa: E402
from test_access_sshd import BridgeSession  # noqa: E402

ARGS = argparse.Namespace()
HERE = Path(".")
SENTINEL = b"QZXV-C-E2E-AUDIO"
checks: list[tuple[str, bool]] = []


def check(name: str, ok: bool) -> None:
    checks.append((name, bool(ok)))
    print(("PASS " if ok else "FAIL ") + name, flush=True)


def remote(cmd: str, stdin: bytes = b"") -> str:
    r = subprocess.run(["ssh", ARGS.owner_ssh, f". {ARGS.env}; " + cmd], input=stdin, capture_output=True, timeout=300)
    return r.stdout.decode()


def owner(method: str, path: str, body=None) -> dict:
    out = remote(f"$ORGANIZER_VENV/bin/python {ARGS.owner_call} {method} {path}",
                 json.dumps(body).encode() if body is not None else b"")
    return json.loads(out.strip().splitlines()[-1])


def ak_sha() -> str:
    return remote("sha256sum ~/.ssh/authorized_keys | cut -c1-64").strip()


def ssh_argv(key: str, *args: str) -> list[str]:
    return ["ssh", "-F", "/dev/null", "-T", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
            "-o", f"UserKnownHostsFile={Path.home() / '.ssh' / 'known_hosts'}", "-o", "StrictHostKeyChecking=yes",
            "-o", "LogLevel=ERROR", *(("-o", f"ProxyCommand={ARGS.proxy_command}") if ARGS.proxy_command else ()),
            "-i", str(HERE / key), ARGS.member_host, *args]


def keypair(name: str) -> str:
    if not (HERE / name).exists():
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", f"v8-c-{name}", "-f", str(HERE / name)],
                       check=True)
    return (HERE / f"{name}.pub").read_text().strip()


def ticket_body(invite: str, kind: str = "member", **extra) -> tuple[dict, bytes]:
    secret = secrets.token_bytes(32)
    expires = datetime.fromtimestamp(time.time() + 3600, timezone.utc).isoformat()
    return {"ticket_id": new_id(), "kind": kind, "ssh_key": keypair(invite), "secret_hash": ticket_hash(secret),
            "expires_at": expires, **extra}, secret


def enroll(invite: str, member: str, ticket: dict, secret: bytes, device: sm.Device, member_id: str) -> dict:
    wire = enroll_request(device, ticket["ticket_id"], secret, keypair(member), member_id)
    r = subprocess.run(ssh_argv(invite, "enroll"), input=json.dumps(wire).encode(), capture_output=True, timeout=60)
    return json.loads(r.stdout.decode().strip().splitlines()[-1])


def mac_on(session: BridgeSession, device: sm.Device, member_id: str, name: str) -> Mac:
    m = Mac(session, time.time, name)
    m.device, m.member_id = device, member_id
    return m


def wav(seconds: int) -> bytes:
    n = 16_000 * seconds
    samples = (SENTINEL * (2 * n // len(SENTINEL) + 1))[: 2 * n]
    return (b"RIFF" + struct.pack("<I", 36 + len(samples)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 16_000,
                                                                                       32_000, 2, 16)
            + b"data" + struct.pack("<I", len(samples)) + samples)


def share_wire(mac: Mac, sid: str, item_id: str, text: str, share_key: str) -> dict:
    dk, e = os.urandom(32), mac.epoch(sid)
    return mac.device.op(sid, mac.member_id, "item.share",
                         {"item_id": item_id, "revision": 1, "kind": "text", "blobs": [], "share_key": share_key},
                         epoch=e, enc=sm.enc_item(dk, {"text": text}, sid, item_id, 1),
                         wrapped_dk=sm.wrap_item_key(mac.key(sid, e), dk, sid, e, item_id))


def post_op(session: BridgeSession, sid: str, wire: dict) -> dict:
    return session.post(f"/v1/spaces/{sid}/ops", json={"ops": [wire]}).json()["results"][0]


def main() -> int:
    global ARGS, HERE
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for flag in ("--owner-ssh", "--env", "--owner-call", "--member-host", "--keys", "--out"):
        ap.add_argument(flag, required=True)
    ap.add_argument("--proxy-command", default="")
    ARGS = ap.parse_args()
    HERE = Path(ARGS.keys)
    HERE.mkdir(parents=True, exist_ok=True)
    before = ak_sha()
    t0 = time.time()
    access_ids: list[str] = []
    sessions: list[BridgeSession] = []
    try:
        # ---- Mac A (a new member) and its second Mac A2 (a device ticket A makes through its own bridge) ----------
        body, secret = ticket_body("invite-a")
        check("owner: ticket for A", owner("POST", "/v1/access/tickets", body)["status"] == 200)
        dev_a, member_a = sm.Device(), new_id()
        out_a = enroll("invite-a", "member-a", body, secret, dev_a, member_a)
        check("A enrolled", out_a.get("ok") is True)
        access_ids.append(out_a["access_id"])
        sa = BridgeSession(ssh_argv("member-a", "bridge"), out_a["credential"])
        sessions.append(sa)
        a = mac_on(sa, dev_a, member_a, "A")
        org_id = a.create_org()
        sid = a.create_space("org", org_id)
        x = a.share(sid, "合成：周四 B203 复测机械臂")["item_id"]
        body, secret = ticket_body("invite-a2", kind="device")
        r = sa.post("/v1/access/tickets", json=body)
        check("A: device ticket for its second Mac", r.status_code == 200)
        dev_a2 = sm.Device()
        out_a2 = enroll("invite-a2", "member-a2", body, secret, dev_a2, member_a)
        check("A2 enrolled under A's member id", out_a2.get("ok") is True and out_a2["member_id"] == member_a)
        access_ids.append(out_a2["access_id"])
        view = {d["device_id"]: d for d in sa.get("/v1/access/devices").json()["devices"]}
        check("devices: A2 still to add to the space and the org",
              view[dev_a2.device_id]["to_add"] == {"spaces": [sid], "orgs": [org_id]})
        e = a.epoch(sid)
        r1 = a.op(sid, "device.add", {"device": dev_a2.public(), "wraps": sm.wraps_for(a.key(sid), [dev_a2.public()],
                                                                                      sid, e)})
        r2 = sa.post(f"/v1/orgs/{org_id}/ops", json={"ops": [dev_a.org_op(org_id, member_a, "org.device_add",
                                                                          {"device": dev_a2.public()})]})
        check("A signs device.add and org.device_add for A2", r1["ok"] and r2.json()["results"][0]["ok"])
        sa2 = BridgeSession(ssh_argv("member-a2", "bridge"), out_a2["credential"])
        sessions.append(sa2)
        a2 = mac_on(sa2, dev_a2, member_a, "A2")
        a2.sync_keys(sid)
        check("A2 reads what A shared", x in a2.read_items(sid))
        check("A2 is admin in the org space", a2.get(f"/v1/spaces/{sid}").json()["me"]["role"] == "admin")
        # ---- B joins and shares a meeting segment's audio -----------------------------------------------------------
        body, secret = ticket_body("invite-b")
        owner("POST", "/v1/access/tickets", body)
        dev_b, member_b = sm.Device(), new_id()
        out_b = enroll("invite-b", "member-b", body, secret, dev_b, member_b)
        check("B enrolled", out_b.get("ok") is True)
        access_ids.append(out_b["access_id"])
        sb = BridgeSession(ssh_argv("member-b", "bridge"), out_b["credential"])
        sessions.append(sb)
        b = mac_on(sb, dev_b, member_b, "B")
        host_keys = sa.get("/v1/spaces/host-keys").json()["host_keys"]      # the invite pins this Spark's own key
        inv = a.invite(sid, role="write", host_key=host_keys[0])
        r = b.request_join(sid, inv)
        check("B joined", inv["result"]["ok"] and r.status_code == 200 and
              a.approve(sid, r.json()["request_id"])["ok"])
        b.sync_keys(sid)
        audio = wav(20)
        rec = new_id()
        part = b.share(sid, "合成：会议里这二十秒的转写", kind="meeting_online", original=audio, blob_role="audio",
                       segment={"parent_item_id": rec, "start_ms": 60_000, "end_ms": 80_000,
                                "recording_ms": 3_600_000})
        check("B shares an audio part", part["result"]["ok"])
        blob_id = part["blobs"][0]["blob_id"]
        got = a2.get(f"/v1/spaces/{sid}/blobs/{blob_id}").content
        entry = next(o for o in a2.get(f"/v1/spaces/{sid}/ops", since=0, limit=1000).json()["ops"]
                     if o["type"] == "item.share" and json.loads(sc.b64u_decode(o["op"]))["body"]["item_id"] ==
                     part["item_id"])
        k = entry["item_key"]
        dk = sm.unwrap_item_key(k["wrapped_dk"], a2.key(sid, k["epoch"]), sid, k["epoch"], part["item_id"])
        opened = sm.open_blob(got, dk, sid, part["item_id"], blob_id)
        check("A2 opens the audio part", opened == audio)
        declared = json.loads(sc.b64u_decode(entry["op"]))["body"]["segment"]
        check("the sound matches the declared part", sm.audio_part_ok((len(opened) - 44) // 32, declared))
        path = f"$ORGANIZER_DATA_DIR/spaces/{sid}/blobs/{blob_id}"
        check("on the Spark: the audio is a ciphertext file", remote(f"head -c 4 {path}") == "MLB1")
        hits = remote(f"grep -rlF -D skip {SENTINEL.decode()} $ORGANIZER_DATA_DIR $ORGANIZER_LOG_DIR | wc -l").strip()
        check("on the Spark: no audio sentinel anywhere", hits == "0")
        second = b.share(sid, "合成：同一场另一段", kind="meeting_online", original=wav(2), blob_role="audio",
                         segment={"parent_item_id": rec, "start_ms": 0, "end_ms": 2_000, "recording_ms": 3_600_000})
        check("one audio part per recording", second["result"].get("error") == "one_part_per_recording")
        # ---- a share sent twice and remade (its answer lost) ------------------------------------------------------
        item, key = new_id(), new_id()
        w = share_wire(b, sid, item, "合成：断网时记下的", key)
        first = post_op(sb, sid, w)
        again = post_op(sb, sid, w)
        remade = post_op(sb, sid, share_wire(b, sid, item, "合成：断网时记下的", key))
        check("retried share accepted once", first["ok"] and again["duplicate"] and remade.get("accepted_as") ==
              "share_key" and remade["seq"] == first["seq"])
        # ---- a snapshot goes with the item it cites ----------------------------------------------------------------
        snap_id, sdk = new_id(), os.urandom(32)
        e = b.epoch(sid)
        snap = b.op(sid, "item.share", sm.snapshot_body(snap_id, 1, matter_id="E1", cites=[x], share_key=new_id()),
                    epoch=e, enc=sm.enc_item(sdk, {"text": "合成：乙的小结"}, sid, snap_id, 1),
                    wrapped_dk=sm.wrap_item_key(b.key(sid, e), sdk, sid, e, snap_id))
        check("B shares a snapshot citing A's item", snap["ok"])
        res = a.ok(sid, "item.withdraw", {"item_id": x})
        ops = a.get(f"/v1/spaces/{sid}/ops", since=res["seq"], limit=10).json()["ops"]
        check("withdrawing the cited item removes the snapshot",
              [o["type"] for o in ops] == ["system.remove"] and
              json.loads(sc.b64u_decode(ops[0]["op"]))["body"]["reason"] == "cited_item_gone")
        # ---- the audio part is withdrawn: the file goes -------------------------------------------------------------
        check("B withdraws the audio part", b.ok(sid, "item.withdraw", {"item_id": part["item_id"]})["ok"])
        check("on the Spark: the audio file is gone", remote(f"test -e {path} && echo yes || echo no").strip() == "no")
        check("the blob answers 410", a.get(f"/v1/spaces/{sid}/blobs/{blob_id}").status_code == 410)
        # ---- an org admin added as a signed op ------------------------------------------------------------------
        r = sa.post(f"/v1/orgs/{org_id}/ops", json={"ops": [dev_a.org_op(org_id, member_a, "org.admin_add", {
            "member_id": member_b, "device": dev_b.public()})]}).json()["results"][0]
        check("A adds B as org admin (B's own Mac)", r["ok"])
        check("B is admin in the org space", b.get(f"/v1/spaces/{sid}").json()["me"]["role"] == "admin")
        # ---- A2 is lost: unpaired, then retired in the space and the org -----------------------------------------
        sa2.close()
        sessions.remove(sa2)
        r = sa.request("DELETE", f"/v1/access/members/{out_a2['access_id']}")
        check("A unpairs A2", r.status_code == 200 and r.json()["removed"] == 1)
        view = {d["device_id"]: d for d in sa.get("/v1/access/devices").json()["devices"]}
        check("devices: A2 still to remove", view[dev_a2.device_id]["to_remove"] == {"spaces": [sid], "orgs": [org_id]})
        roster = a.roster(sid)[0]
        keep = [d for d in sm.active_devices(roster) if d["device_id"] != dev_a2.device_id]
        e = max(a.epoch(sid), roster["epoch"])
        new_key = os.urandom(32)
        res = a.op(sid, "device.remove", {"device_id": dev_a2.device_id, "epoch": e + 1,
                                          "wraps": sm.wraps_for(new_key, keep, sid, e + 1),
                                          "epoch_link": sm.epoch_link(new_key, a.key(sid), sid, e + 1)})
        r = sa.post(f"/v1/orgs/{org_id}/ops", json={"ops": [dev_a.org_op(org_id, member_a, "org.device_remove", {
            "device_id": dev_a2.device_id})]}).json()["results"][0]
        check("A retires A2 (device.remove with a new key, org.device_remove)", res["ok"] and r["ok"])
        view = {d["device_id"]: d for d in sa.get("/v1/access/devices").json()["devices"]}
        check("devices: nothing left to remove", view[dev_a2.device_id]["to_remove"] == {"spaces": [], "orgs": []})
    except Exception as exc:  # a broken step ends the run; the summary says so, the cleanup below still runs
        check(f"run completed ({type(exc).__name__})", False)
    finally:
        for s in sessions:
            try:
                s.close()
            except Exception:
                pass
        for access_id in access_ids:
            owner("DELETE", f"/v1/access/members/{access_id}")
    check("authorized_keys byte-identical", ak_sha() == before)
    summary = {"checks": len(checks), "passed": sum(ok for _, ok in checks), "seconds": round(time.time() - t0, 1),
               "authorized_keys_sha256_prefix": before[:16], "failed": [n for n, ok in checks if not ok]}
    Path(ARGS.out).write_text(json.dumps(summary, ensure_ascii=False, indent=1))
    print(json.dumps(summary, ensure_ascii=False))
    return 0 if not summary["failed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
