#!/usr/bin/env python3
"""v8 integration: two members' Macs side by side through the Spark's real sshd and the gate, each with its own key
and credential. What one member's way in can never reach: the other's space before it is let in, the other's Macs,
records and audit rows, the other's credential, a signature in the other's name, the owner's routes; a second
Authorization header; and after a removal or an unpairing, nothing. Positive controls: the member let into the
space reads it; each Mac sees its own record. Synthetic data only.

  member_gate_e2e.py --owner-ssh <ssh alias with the owner's shell> --env <instance env.sh on the Spark>
                     --owner-call <the deployed spark/owner-call.py on the Spark>
                     --member-host <user@host the member keys log in to> [--proxy-command "ssh -W %h:%p <relay>"]
                     --keys <local dir for the throwaway keys> --out <summary.json>

Owner calls run on the Spark (spark/owner-call.py reads the link token there; it never leaves the Spark). At the end
both Macs are unpaired, every ticket is closed and authorized_keys is compared with its SHA-256 from before. The
summary holds check names, counts and the hash prefix only."""

from __future__ import annotations

import argparse
import json
import secrets
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "spark"))
sys.path.insert(0, str(REPO / "spark" / "tests"))

from organizer import space_member as sm  # noqa: E402
from organizer.access import enroll_request, ticket_hash  # noqa: E402
from spacekit import Mac, new_id  # noqa: E402
from test_access_sshd import BridgeSession  # noqa: E402

ARGS = argparse.Namespace()
HERE = Path(".")
MARKER = "QZXV-GATE-" + secrets.token_hex(6).upper()
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


def ssh_argv(key: str, *args: str, extra: tuple = ()) -> list[str]:
    return ["ssh", "-F", "/dev/null", "-T", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
            "-o", f"UserKnownHostsFile={Path.home() / '.ssh' / 'known_hosts'}", "-o", "StrictHostKeyChecking=yes",
            "-o", "LogLevel=ERROR", *(("-o", f"ProxyCommand={ARGS.proxy_command}") if ARGS.proxy_command else ()),
            "-i", str(HERE / key), *extra, ARGS.member_host, *args]


def keypair(name: str) -> str:
    if not (HERE / name).exists():
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", f"v8-gate-{name}", "-f", str(HERE / name)],
                       check=True)
    return (HERE / f"{name}.pub").read_text().strip()


def ticket_body(invite: str) -> tuple[dict, bytes]:
    secret = secrets.token_bytes(32)
    expires = datetime.fromtimestamp(time.time() + 3600, timezone.utc).isoformat()
    return {"ticket_id": new_id(), "kind": "member", "ssh_key": keypair(invite), "secret_hash": ticket_hash(secret),
            "expires_at": expires}, secret


def enroll(invite: str, member: str, ticket: dict, secret: bytes, device: sm.Device, member_id: str) -> dict:
    wire = enroll_request(device, ticket["ticket_id"], secret, keypair(member), member_id)
    r = subprocess.run(ssh_argv(invite, "enroll"), input=json.dumps(wire).encode(), capture_output=True, timeout=60)
    lines = r.stdout.decode().strip().splitlines()
    return json.loads(lines[-1]) if lines else {"ok": False, "error": f"ssh exit {r.returncode}"}


def mac_on(session: BridgeSession, device: sm.Device, member_id: str, name: str) -> Mac:
    m = Mac(session, time.time, name)
    m.device, m.member_id = device, member_id
    return m


def error_of(reply) -> str:
    try:
        body = reply.json()
    except Exception:
        return ""
    return str(body.get("error") or (body.get("detail") or {}).get("error") or "") if isinstance(body, dict) else ""


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
    tickets: list[str] = []
    sessions: list[BridgeSession] = []

    def session(key: str, credential: str) -> BridgeSession:
        s = BridgeSession(ssh_argv(key, "bridge"), credential)
        sessions.append(s)
        return s

    try:
        # ---- two members, each with its own invite key, member key, device and credential -------------------------
        body_a, secret_a = ticket_body("invite-a")
        body_b, secret_b = ticket_body("invite-b")
        ok_a = owner("POST", "/v1/access/tickets", body_a)["status"] == 200
        ok_b = owner("POST", "/v1/access/tickets", body_b)["status"] == 200
        tickets += [body_a["ticket_id"], body_b["ticket_id"]]
        check("owner: a ticket for each member", ok_a and ok_b)
        dev_a, member_a = sm.Device(), new_id()
        dev_b, member_b = sm.Device(), new_id()
        out_a = enroll("invite-a", "member-a", body_a, secret_a, dev_a, member_a)
        out_b = enroll("invite-b", "member-b", body_b, secret_b, dev_b, member_b)
        check("A and B enrolled, each with its own key", out_a.get("ok") is True and out_b.get("ok") is True and
              out_a["access_id"] != out_b["access_id"])
        access_ids += [out_a["access_id"], out_b["access_id"]]
        check("the invite keys are dead after enrollment",
              subprocess.run(ssh_argv("invite-b", "enroll"), input=b"{}", capture_output=True, timeout=60).returncode
              == 255)
        sa = session("member-a", out_a["credential"])
        sb = session("member-b", out_b["credential"])
        a = mac_on(sa, dev_a, member_a, "A")
        b = mac_on(sb, dev_b, member_b, "B")
        me_a, me_b = sa.get("/v1/access/me").json(), sb.get("/v1/access/me").json()
        check("each bridge answers as its own member", me_a["access"]["member_id"] == member_a and
              me_b["access"]["member_id"] == member_b)
        # ---- A's org space, with one item ----------------------------------------------------------------------
        org_id = a.create_org()
        sid = a.create_space("org", org_id)
        x = a.share(sid, f"合成：周五前把 Twin-7 复测结论发给大家 {MARKER}")["item_id"]
        # ---- B is not in it: nothing of A's reaches B --------------------------------------------------------
        r = b.get(f"/v1/spaces/{sid}")
        check("B cannot read A's space summary", r.status_code in (401, 403))
        r = b.get(f"/v1/spaces/{sid}/ops", since=0, limit=100)
        check("B cannot read A's space log", r.status_code in (401, 403))
        r = b.get(f"/v1/spaces/{sid}/keys")
        check("B gets no key of A's space", r.status_code in (401, 403))
        r = sb.get(f"/v1/access/devices?member_id={member_a}")
        check("B cannot list A's Macs", r.status_code == 403)
        r = sb.request("DELETE", f"/v1/access/members/{out_a['access_id']}")
        check("B cannot unpair A", r.status_code == 403)
        members = sb.get("/v1/access/members").json().get("members") or []
        check("B's member list holds only B", {m["member_id"] for m in members} == {member_b})
        entries = sb.get("/v1/access/audit").json().get("entries") or []
        check("B's audit view holds no row about A", entries and not any(
            e["target"].get("member_id") == member_a or e["target"].get("access_id") == out_a["access_id"]
            for e in entries))
        body_x, _ = ticket_body("invite-x")
        r = sb.post("/v1/access/tickets", json=body_x)
        check("B (no admin anywhere) cannot invite a new member", r.status_code == 403)
        if r.status_code == 200:
            tickets.append(body_x["ticket_id"])
        check("B cannot read the Spark's health", sb.get("/v1/infra/health").status_code == 403)
        check("B cannot reach the owner's store", sb.get("/v1/state").status_code == 403)
        # ---- B in A's name ---------------------------------------------------------------------------------------
        wire = dev_b.org_op(new_id(), member_a, "org.create", {"device": dev_b.public(), "policy": {"recovery_admins": 1}})
        r = sb.post("/v1/orgs", json=wire)
        check("B cannot sign as A's member id (access_member)", r.status_code == 403 and
              error_of(r) == "access_member")
        other = sm.Device()
        wire = other.org_op(new_id(), member_b, "org.create", {"device": other.public(), "policy": {"recovery_admins": 1}})
        r = sb.post("/v1/orgs", json=wire)
        check("B cannot sign with another device (access_device)", r.status_code == 403 and
              error_of(r) == "access_device")
        cross = session("member-b", out_a["credential"])
        r = cross.get("/v1/access/me")
        check("A's credential over B's key is refused at the gate", r.status_code == 403 and
              error_of(r) == "gate_refused")
        two = session("member-b", out_b["credential"])
        r = two.get("/v1/access/me", headers={"Authorization": "Bearer " + out_a["credential"]})
        check("two Authorization headers are refused", r.status_code == 400)
        # ---- A lets B in: B reads (positive control) -------------------------------------------------------------
        host_keys = sa.get("/v1/spaces/host-keys").json()["host_keys"]
        inv = a.invite(sid, role="write", host_key=host_keys[0])
        r = b.request_join(sid, inv)
        check("A lets B into the space", inv["result"]["ok"] and r.status_code == 200 and
              a.approve(sid, r.json()["request_id"])["ok"])
        b.sync_keys(sid)
        check("B reads A's item once let in", x in b.read_items(sid))
        # ---- A removes B: B is out ---------------------------------------------------------------------------------
        check("A removes B (member.remove with a new key)", a.remove_member(sid, member_b)["ok"])
        y = a.share(sid, f"合成：移除之后的新条目 {MARKER}")["item_id"]
        r = b.get(f"/v1/spaces/{sid}/ops", since=0, limit=100)
        check("removed B cannot read the space any more", r.status_code == 403 and error_of(r) == "not_member")
        r = b.get(f"/v1/spaces/{sid}/keys")
        check("removed B gets no new key", r.status_code == 403)
        check("A still reads both items", {x, y} <= set(a.read_items(sid)))
        # ---- the owner unpairs B: B's key is gone, B's old device never comes back --------------------------------
        for s in (cross, two, sb):
            try:
                s.close()
            except Exception:
                pass
            sessions.remove(s)
        r = owner("DELETE", f"/v1/access/members/{out_b['access_id']}")
        check("owner unpairs B", r["status"] == 200 and r["body"]["removed"] == 1)
        r = subprocess.run(ssh_argv("member-b", "bridge"), capture_output=True, timeout=60)
        check("B's key refused after unpairing", r.returncode == 255)
        r = sa.get("/v1/access/me", headers={})
        check("A unaffected by B's unpairing", r.status_code == 200 and r.json()["access"]["status"] == "active")
        body_c, secret_c = ticket_body("invite-c")
        ok = owner("POST", "/v1/access/tickets", body_c)["status"] == 200
        tickets.append(body_c["ticket_id"])
        again = enroll("invite-c", "member-c", body_c, secret_c, dev_b, member_b)
        check("B's unpaired device cannot enroll again", ok and again.get("ok") is False and
              again.get("error") == "device_revoked")
        # ---- the marker never reached the Spark in the clear ----------------------------------------------------
        hits = remote(f"grep -rlF -D skip {MARKER} $ORGANIZER_DATA_DIR $ORGANIZER_LOG_DIR | wc -l").strip()
        check("no item text on the Spark in the clear", hits == "0")
    except Exception as exc:  # a broken step ends the run; the summary says so, the cleanup below still runs
        check(f"run completed ({type(exc).__name__}: {str(exc)[:120]})", False)
    finally:
        for s in sessions:
            try:
                s.close()
            except Exception:
                pass
        for access_id in access_ids:
            owner("DELETE", f"/v1/access/members/{access_id}")
        for ticket_id in tickets:
            owner("DELETE", f"/v1/access/tickets/{ticket_id}")
    r = subprocess.run(ssh_argv("member-a", "bridge"), capture_output=True, timeout=60)
    check("A's key refused after unpairing", r.returncode == 255)
    check("authorized_keys byte-identical", ak_sha() == before)
    summary = {"checks": len(checks), "passed": sum(ok for _, ok in checks), "seconds": round(time.time() - t0, 1),
               "authorized_keys_sha256_prefix": before[:16], "failed": [n for n, ok in checks if not ok]}
    Path(ARGS.out).write_text(json.dumps(summary, ensure_ascii=False, indent=1))
    print(json.dumps(summary, ensure_ascii=False))
    return 0 if not summary["failed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
