"""Serve the fine-tuned Laya System One with Laya's own Jev-compatible app (laya.serve.create_app):
POST /v1/systemone on 127.0.0.1:8021 only.  The Router is built on our checkpoint as its
"multilingual" (and default) model, so every request, in any language, reaches it.

  LAYA_DEVICE=cuda python laya_serve_s1.py RUN_DIR/model [--port 8021]
"""
import argparse
import os

import torch

ap = argparse.ArgumentParser()
ap.add_argument("model_dir")
ap.add_argument("--port", type=int, default=8021)
ap.add_argument("--mem-gb", type=float, default=2.5)
args = ap.parse_args()

total = torch.cuda.get_device_properties(0).total_memory / 1e9
torch.zeros(1, device="cuda")  # context first (unified memory, see laya_s1.py)
torch.cuda.set_per_process_memory_fraction(min(1.0, args.mem_gb / total))

import uvicorn  # noqa: E402
from laya.router import Router  # noqa: E402
from laya.serve import create_app  # noqa: E402

path = os.path.abspath(args.model_dir)
router = Router(models={"multilingual": path, "english": path}, device=os.environ.get("LAYA_DEVICE", "cuda"),
                default="multilingual", max_loaded=1)
router.preload(["multilingual"])
uvicorn.run(create_app(router), host="127.0.0.1", port=args.port, log_level="warning")
