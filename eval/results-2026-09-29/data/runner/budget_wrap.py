"""Run eval/run_eval.py with each chat call's max_tokens raised by V5_EXTRA_TOKENS (reasoning allowance for
models that cannot turn reasoning off, e.g. gpt-oss). Skill prompts, schemas and validators are unchanged."""
import os, runpy, sys
sys.path.insert(0, os.path.join(os.getcwd(), "spark"))
from organizer import clients  # noqa: E402
EXTRA = int(os.environ.get("V5_EXTRA_TOKENS", "2048"))
_orig = clients.OpenAIChatClient.complete
def complete(self, messages, schema, schema_name, max_tokens):
    return _orig(self, messages, schema, schema_name, max_tokens + EXTRA)
clients.OpenAIChatClient.complete = complete
sys.argv = ["eval/run_eval.py"] + sys.argv[1:]
runpy.run_path("eval/run_eval.py", run_name="__main__")
