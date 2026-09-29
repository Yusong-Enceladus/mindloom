import httpx, time, json
c = httpx.Client(base_url="http://127.0.0.1:8100/v1", timeout=600, trust_env=False)
kw = {"enable_thinking": False, "thinking": False}
def call(msg, max_tokens, **extra):
    t = time.time()
    r = c.post("/chat/completions", json={"model":"deepseek-v4-flash","messages":[{"role":"user","content":msg}],
        "temperature":0,"max_tokens":max_tokens,"chat_template_kwargs":kw, **extra}).json()
    return time.time()-t, r["usage"]
out = {}
# decode: short prompt, long answer (ignore_eos keeps length fixed)
dt, u = call("用中文写一段关于城市夜晚的散文。", 512, ignore_eos=True); out["decode_512"] = (round(dt,2), u["completion_tokens"], round(u["completion_tokens"]/dt,1))
dt, u = call("用中文写一段关于城市夜晚的散文。", 16, ignore_eos=True); out["decode_16"] = (round(dt,2), u["completion_tokens"])
out["decode_tok_s_net"] = round((512-16)/(out["decode_512"][0]-out["decode_16"][0]),1)
# prefill: ~6k-token synthetic prompt (unique prefix so no prefix-cache hit), 1 token out
body = f"[{time.time()}] " + "；".join(f"第{i}条虚构记录：供应商{i%17}号在周{i%7+1}提交了第{i}批样品的检验报告" for i in range(260))
dt, u = call(body + "\n以上共几条？", 1); out["prefill"] = (round(dt,2), u["prompt_tokens"], round(u["prompt_tokens"]/dt,1))
print(json.dumps(out, ensure_ascii=False))
