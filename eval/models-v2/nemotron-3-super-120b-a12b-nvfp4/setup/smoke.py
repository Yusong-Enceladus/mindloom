"""Smoke test: thinking off via chat_template_kwargs (what the organizer client sends) vs default thinking."""
import time

import httpx

c = httpx.Client(base_url="http://127.0.0.1:8120/v1", timeout=600, trust_env=False)
msgs = [{"role": "user", "content": "把下面一句话里的日期换算成绝对日期（今天是2026年9月22日周二）：明天下午三点和李雷对账。只输出JSON。"}]
schema = {"type": "object", "properties": {"date": {"type": "string"}, "what": {"type": "string"}},
          "required": ["date", "what"], "additionalProperties": False}
# The organizer client's exact kwargs first, then the model's default (thinking on).
for label, kw in [("organizer-kwargs", {"enable_thinking": False, "thinking": False}), ("default", None)]:
    body = {"model": "nemotron-3-super-120b-a12b-nvfp4", "messages": msgs, "temperature": 0, "max_tokens": 2048,
            "response_format": {"type": "json_schema", "json_schema": {"name": "t", "schema": schema, "strict": True}}}
    if kw is not None:
        body["chat_template_kwargs"] = kw
    t = time.time()
    r = c.post("/chat/completions", json=body).json()
    dt = time.time() - t
    m = r["choices"][0]["message"]
    reasoning = m.get("reasoning_content") or m.get("reasoning") or ""
    print(label, round(dt, 2), "s", r["usage"], "reasoning_len", len(reasoning),
          "content", repr((m.get("content") or "")[:200]))
