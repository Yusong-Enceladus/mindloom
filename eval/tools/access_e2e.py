#!/usr/bin/env python3
"""v8 per-member access end to end against a deployed instance, through the Spark's real sshd (B1, with the admin
console's health B2 and a backup B4 through the bridge). Synthetic data only.

  access_e2e.py --owner-ssh <ssh alias with the owner's shell> --env <instance env.sh on the Spark>
                --owner-call <the deployed spark/owner-call.py on the Spark>
                --member-host <user@host the member key logs in to> [--proxy-command "ssh -W %h:%p <relay>"]
                --keys <local dir for the throwaway invite / member keys> --out <summary.json>

Owner calls run on the Spark (spark/owner-call.py reads the link token there; it never
leaves the Spark). The member side runs here: its own keys, enrollment through the invite key, then HTTP over
`ssh -T <spark> bridge`. At the end the member is unpaired and authorized_keys is compared with its SHA-256 from
before. The summary holds check names, counts and the hash prefix only."""

from __future__ import annotations

import json
import os
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
from organizer import backup  # noqa: E402
from organizer.access import enroll_request, ticket_hash  # noqa: E402
from spacekit import Mac, new_id  # noqa: E402
from test_access_sshd import BridgeSession  # noqa: E402

import argparse  # noqa: E402

ARGS = argparse.Namespace(owner_ssh="", env="", owner_call="", member_host="", proxy_command="", keys=".", out="")
HERE = Path(".")
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


def main() -> int:
    global ARGS, HERE
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--owner-ssh", required=True)
    ap.add_argument("--env", required=True)
    ap.add_argument("--owner-call", required=True, help="spark/owner-call.py of the deployed code, on the Spark")
    ap.add_argument("--member-host", required=True)
    ap.add_argument("--proxy-command", default="")
    ap.add_argument("--keys", required=True)
    ap.add_argument("--out", required=True)
    ARGS = ap.parse_args()
    HERE = Path(ARGS.keys)
    HERE.mkdir(parents=True, exist_ok=True)
    for name in ("invite", "member"):
        if not (HERE / name).exists():
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", f"v8-smoke-{name}", "-f", str(HERE / name)],
                           check=True)
    before = ak_sha()
    t0 = time.time()
    # owner: a ticket for the invite key
    secret, ticket_id = secrets.token_bytes(32), new_id()
    expires = datetime.fromtimestamp(time.time() + 3600, timezone.utc).isoformat()
    r = owner("POST", "/v1/access/tickets", {"ticket_id": ticket_id, "kind": "member",
                                             "ssh_key": (HERE / "invite.pub").read_text().strip(),
                                             "secret_hash": ticket_hash(secret), "expires_at": expires})
    check("ticket registered", r["status"] == 200)
    r = subprocess.run(ssh_argv("invite", "cat /etc/hostname"), capture_output=True, timeout=60)
    check("invite key cannot run a command", r.returncode == 1 and b"not_allowed" in r.stdout)
    device, member_id = sm.Device(), new_id()
    wire = enroll_request(device, ticket_id, secret, (HERE / "member.pub").read_text().strip(), member_id)
    r = subprocess.run(ssh_argv("invite", "enroll"), input=json.dumps(wire).encode(), capture_output=True, timeout=60)
    out = json.loads(r.stdout.decode().strip().splitlines()[-1])
    check("enrolled through the invite key", r.returncode == 0 and out.get("ok") is True)
    r = subprocess.run(ssh_argv("invite", "enroll"), input=json.dumps(wire).encode(), capture_output=True, timeout=60)
    check("invite key dead after enrollment", r.returncode == 255)
    session = BridgeSession(ssh_argv("member", "bridge"), out["credential"])
    try:
        check("bridge: /v1/access/me", session.get("/v1/access/me").json()["access"]["member_id"] == member_id)
        check("bridge: personal store refused", session.get("/v1/state").status_code == 403)
        check("bridge: infra health refused for a plain member", session.get("/v1/infra/health").status_code == 403)
        mac = Mac(session, time.time)
        mac.device, mac.member_id = device, member_id
        org_id = mac.create_org()
        h = session.get("/v1/infra/health")
        body = h.json() if h.status_code == 200 else {}
        check("bridge: infra health for an org admin", h.status_code == 200 and body.get("gpu") is not None)
        check("infra health: chat model up", any(m["role"] == "chat" and m["up"] for m in body.get("models") or []))
        check("infra health: unified memory reported",
              ((body.get("gpu") or {}).get("unified_memory") or {}).get("total_mib", 0) > 0)
        space_id = mac.create_space("org", org_id)
        shared = mac.share(space_id, "合成：v8 冒烟测试素材", original=os.urandom(1024 * 1024))
        check("bridge: share with a 1 MB original", shared["result"]["ok"])
        bid = new_id()
        key = sm.backup_key(mac.key(space_id), bid)
        r = mac.post_json(f"/v1/spaces/{space_id}/backup", {"backup_id": bid, "epoch": 1, "key": key.hex()})
        check("bridge: backup streamed", r.status_code == 200 and r.content.startswith(backup.MAGIC))
        import io
        fh = io.BytesIO(r.content)
        header, line = backup.read_header(fh)
        kinds = [k for k, _ in backup.decrypt_records(fh, key, line)]
        check("backup opens with the derived key", kinds[0] == b"M" and kinds[-1] == b"E" and b"B" in kinds)
        check("backup holds no plaintext", "冒烟".encode() not in r.content)
    finally:
        session.close()
    r = subprocess.run(ssh_argv("member", "cat /etc/hostname"), capture_output=True, timeout=60)
    check("member key cannot run a command", r.returncode == 1 and not r.stdout)
    r = subprocess.run(ssh_argv("member", extra=("-W", "127.0.0.1:22")), capture_output=True, timeout=30)
    check("member key cannot open a tunnel", r.returncode != 0)
    r = owner("DELETE", f"/v1/access/members/{out['access_id']}")
    check("unpaired", r["status"] == 200 and r["body"]["removed"] == 1)
    check("authorized_keys byte-identical", ak_sha() == before)
    r = subprocess.run(ssh_argv("member", "bridge"), capture_output=True, timeout=60)
    check("member key refused after unpairing", r.returncode == 255)
    summary = {"checks": len(checks), "passed": sum(ok for _, ok in checks), "seconds": round(time.time() - t0, 1),
               "authorized_keys_sha256_prefix": before[:16], "failed": [n for n, ok in checks if not ok]}
    Path(ARGS.out).write_text(json.dumps(summary, ensure_ascii=False, indent=1))
    print(json.dumps(summary, ensure_ascii=False))
    return 0 if not summary["failed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
