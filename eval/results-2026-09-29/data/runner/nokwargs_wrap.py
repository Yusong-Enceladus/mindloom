"""Run eval/run_eval.py but drop chat_template_kwargs from requests to the model on port 8140 (vLLM rejects the
field for Mistral-format tokenizers: 'chat_template is not supported for Mistral tokenizers'). Requests to other
endpoints (the Qwen3.6 image reader) are unchanged. Skill prompts, schemas and validators are unchanged."""
import os
import runpy
import sys

import httpx

PORT = os.environ.get("V5_DROP_CTK_PORT", ":8140")
_post = httpx.Client.post


def post(self, url, *a, **k):
    body = k.get("json")
    if isinstance(body, dict) and "chat_template_kwargs" in body and PORT in str(self.base_url):
        body = dict(body)
        body.pop("chat_template_kwargs")
        k["json"] = body
    return _post(self, url, *a, **k)


httpx.Client.post = post
sys.argv = ["eval/run_eval.py"] + sys.argv[1:]
runpy.run_path("eval/run_eval.py", run_name="__main__")
