"""Minimal OpenAI-compatible /v1/embeddings for Qwen3-Embedding-0.6B on 127.0.0.1 (transformers).

Used only on spark-D where DeepSeek-V4-Flash leaves ~6 GB free, too little for a vLLM pooling
server. Last-token pooling + L2 normalize, left padding, bf16 on CUDA - the model card's recipe and
the same pooling vLLM's runner applies.
"""
import os
import sys
import time

import torch
import torch.nn.functional as F
import uvicorn
from fastapi import FastAPI
from pydantic import BaseModel
from transformers import AutoModel, AutoTokenizer

MODEL_DIR = sys.argv[1]
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8012
NAME = "qwen3-embedding-0.6b"
DEVICE = os.environ.get("EMB_DEVICE", "cuda")

tok = AutoTokenizer.from_pretrained(MODEL_DIR, padding_side="left")
model = AutoModel.from_pretrained(MODEL_DIR, dtype=torch.bfloat16).to(DEVICE).eval()
app = FastAPI()


class Req(BaseModel):
    input: str | list[str]
    model: str | None = None


@app.get("/v1/models")
def models():
    return {"object": "list", "data": [{"id": NAME, "object": "model", "owned_by": "local"}]}


@app.post("/v1/embeddings")
def embeddings(req: Req):
    texts = [req.input] if isinstance(req.input, str) else req.input
    out, ntok = [], 0
    with torch.inference_mode():
        for i in range(0, len(texts), 8):
            batch = tok(texts[i:i + 8], padding=True, truncation=True, max_length=8192, return_tensors="pt").to(DEVICE)
            ntok += int(batch["attention_mask"].sum())
            hidden = model(**batch).last_hidden_state
            vec = F.normalize(hidden[:, -1].float(), p=2, dim=1)
            out.extend(vec.cpu().tolist())
    return {"object": "list", "model": NAME,
            "data": [{"object": "embedding", "index": i, "embedding": v} for i, v in enumerate(out)],
            "usage": {"prompt_tokens": ntok, "total_tokens": ntok}}


if __name__ == "__main__":
    print(f"ready {time.strftime('%T')} device={DEVICE}", flush=True)
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning")
