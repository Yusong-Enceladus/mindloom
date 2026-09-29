#!/usr/bin/env python3
"""Download a ModelScope repo with sha256 checks: small files directly, big files via pdl.py (ranged, parallel).
usage: msdl.py REPO OUTDIR [PARALLEL_FILES] [CONNS_PER_FILE]"""
import hashlib, json, os, subprocess, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
repo, outdir = sys.argv[1], sys.argv[2]
par = int(sys.argv[3]) if len(sys.argv) > 3 else 6
conns = int(sys.argv[4]) if len(sys.argv) > 4 else 3
os.makedirs(outdir, exist_ok=True)
api = f"https://modelscope.cn/api/v1/models/{repo}/repo/files?Revision=master&Recursive=true"
files = [f for f in json.load(urllib.request.urlopen(api, timeout=60))["Data"]["Files"] if f["Type"] == "blob"]
if os.environ.get("MSDL_ROOTONLY"): files = [f for f in files if "/" not in f["Path"]]
json.dump(files, open(os.path.join(outdir, ".files.json"), "w"))
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(16 << 20), b""):
            h.update(b)
    return h.hexdigest()
def get(f):
    path = os.path.join(outdir, f["Path"]); url = f"https://modelscope.cn/models/{repo}/resolve/master/{f['Path']}"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path) and os.path.getsize(path) == f["Size"] and not os.path.exists(path + ".done") and sha(path) == f["Sha256"]:
        return f"{f['Path']} cached"
    for attempt in range(5):
        if f["Size"] < 64 << 20:
            data = urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "pdl/1.0"}), timeout=120).read() if f["Size"] else b""
            open(path, "wb").write(data)
        else:
            r = subprocess.run([sys.executable, os.path.expanduser("~/hack/pdl.py"), url, path, f["Sha256"], str(conns)],
                               capture_output=True, text=True)
            if r.returncode != 0:
                print(f"{f['Path']} pdl rc={r.returncode} {r.stdout[-300:]}", flush=True); time.sleep(5); continue
        if os.path.getsize(path) == f["Size"] and sha(path) == f["Sha256"]:
            return f"{f['Path']} ok"
        print(f"{f['Path']} verify failed attempt {attempt}", flush=True)
    return f"{f['Path']} FAILED"
t0 = time.time()
files.sort(key=lambda f: -f["Size"])
with ThreadPoolExecutor(par) as ex:
    for i, res in enumerate(ex.map(get, files)):
        print(f"[{i+1}/{len(files)} {time.time()-t0:.0f}s] {res}", flush=True)
bad = [l for l in open(os.devnull)]
print("ALLDONE", time.time() - t0, flush=True)
