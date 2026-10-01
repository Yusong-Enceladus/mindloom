"""Call this instance's organizer as its owner, over the private socket, from a shell on the Spark.
The link token is read here and never printed. Usage: owner-call.py METHOD PATH < body.json"""
import json
import os
import sys

import httpx

data = os.environ["ORGANIZER_DATA_DIR"]
tok = open(os.path.join(data, "link_token")).read().strip()
method, path = sys.argv[1], sys.argv[2]
body = sys.stdin.buffer.read() if not sys.stdin.isatty() else b""
with httpx.Client(transport=httpx.HTTPTransport(uds=os.path.join(data, "organizer.sock")), base_url="http://organizer",
                  timeout=300, trust_env=False) as c:
    r = c.request(method, path, content=body or None,
                  headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
try:
    out = r.json()
except ValueError:
    out = None
print(json.dumps({"status": r.status_code, "body": out}, ensure_ascii=False))
