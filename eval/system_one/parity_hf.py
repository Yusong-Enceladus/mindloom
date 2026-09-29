"""HF reference logits for the first N val rows (run on GPU right after training, before vLLM starts).
s1_client.py compares the served logits against <run>/parity_hf.json."""
import json, os, sys
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from s1_common import choice_pairs, load_jsonl

run, data, n = sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 20
torch.cuda.set_per_process_memory_fraction(3.0e9 / torch.cuda.get_device_properties(0).total_memory)
tok = AutoTokenizer.from_pretrained(f"{run}/model")
m = AutoModelForCausalLM.from_pretrained(f"{run}/model", torch_dtype=torch.bfloat16).cuda().eval()
Y, N = tok.convert_tokens_to_ids("yes"), tok.convert_tokens_to_ids("no")
out = {}
with torch.no_grad():
    for r in load_jsonl(f"{data}/choice_val.jsonl")[:n]:
        _, texts = choice_pairs(r)
        ce = []
        for t in texts:  # one at a time: no padding, same positions as vLLM
            ids = tok(t, return_tensors="pt").input_ids.cuda()
            h = m.model(input_ids=ids).last_hidden_state[:, -1].float()
            lg = h @ m.lm_head.weight[[Y, N]].float().T
            ce.append(float(lg[0, 0] - lg[0, 1]))
        out[r["id"]] = ce
json.dump(out, open(f"{run}/parity_hf.json", "w"))
print("parity rows", len(out))
