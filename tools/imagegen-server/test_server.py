# -*- coding: utf-8 -*-
"""汪柴生图服务（8899 壳）契约单测——假 _pipe，不加载真模型。

覆盖（2026-11-12 一实例三角色方案验收口径）：
  /api/health    免鉴权 + 新字段（chat_model/te_residency/dit）；
  /v1/models     双 id（生图 + chat）+ 鉴权三态（缺 key 401 / 错 key 401 / 对 200）；
  /v1/images/generations  回归：参数校验（prompt/size/n/response_format/seed）
                 + b64 出图 + seed 回声；
  /v1/chat/completions    非流式（chat.completion + usage）/ SSE 流式
                 （role chunk → delta.content → finish stop → [DONE]）/
                 参数校验（messages 形状、temperature 非数）；
  锁互斥        chat 与 generations 并发全程 _gen_lock 单飞（并发计数 ≤1）。

跑法（依赖装齐后，本目录）：
  .venv\\Scripts\\python.exe test_server.py
纯标准库断言脚本（不依赖 pytest）；全绿打印 ALL PASS 并 exit 0。
"""
import base64
import json
import os
import queue
import sys
import threading
import time

# —— env 必须在 import server 前置好（模块常量 import 时定格）——
os.environ["QI_API_KEY"] = "sk-test"
os.environ["QI_MODEL_ID"] = "qit-test"
os.environ["QI_CHAT_MODEL_ID"] = "chat-id-x"
os.environ["QI_TE_DEVICE"] = "cpu"
os.environ["QI_TE_KEEP_SEC"] = "0"

import server  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

AUTH = {"Authorization": "Bearer sk-test"}
PASS, FAIL = [], []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    print(f"  {'✓' if cond else '✗'} {name}" + (f" — {detail}" if detail and not cond else ""))


# ------------------------------------------------------------------ 假件 ----

class _Row(list):
    """一维 token 张量替身：支持切片后仍带 .shape。"""

    def __getitem__(self, k):
        v = list.__getitem__(self, k)
        return _Row(v) if isinstance(k, slice) else v

    @property
    def shape(self):
        return (len(self),)


class _Ids:
    def __init__(self, n):
        self.shape = (1, n)


class _Inputs(dict):
    def to(self, device):
        self.device = device
        return self


CHAT_PIECES = ["一只", "橘猫", "，柔光"]
CHAT_FULL = "".join(CHAT_PIECES)


class FakeTokenizer:
    def decode(self, ids, skip_special_tokens=True):
        return CHAT_FULL


class FakeProcessor:
    def __init__(self):
        self.tokenizer = FakeTokenizer()
        self.last_text = None

    def apply_chat_template(self, messages, add_generation_prompt=True,
                            tokenize=False):
        return "||".join(f"{m['role']}:{m['content']}" for m in messages)

    def __call__(self, text=None, return_tensors=None):
        self.last_text = text
        return _Inputs({"input_ids": _Ids(len(text[0]))})


class FakeTextEncoder:
    def __init__(self):
        self.generate_calls = []

    def to(self, device):
        return self

    def generate(self, **kw):
        _lock_guard.enter("chat")
        try:
            time.sleep(0.02)
            self.generate_calls.append(kw)
            streamer = kw.get("streamer")
            in_len = kw["input_ids"].shape[1]
            if streamer is not None:
                for piece in CHAT_PIECES:
                    streamer.put(piece)
                return None  # 流式路 out 不参与 decode（_run_chat 里 gen=None）
            return [_Row([0] * in_len + [7] * len(CHAT_FULL))]
        finally:
            _lock_guard.exit("chat")


class FakeStreamer:
    """transformers.TextIteratorStreamer 替身（server 端点内 import，故整体换）。"""

    def __init__(self, tokenizer, skip_prompt=True, skip_special_tokens=True, **kw):
        self.q = queue.Queue()

    def put(self, piece):
        # 真件按 token 解码后入队；替身直接收 str（fake generate 喂的即词）。
        self.q.put(piece)

    def end(self):
        self.q.put(None)

    def __next__(self):
        v = self.q.get()
        if v is None:
            raise StopIteration
        return v


class _LockGuard:
    """并发计数器：任何两路生成同飞即破口（_gen_lock 失效）。"""

    def __init__(self):
        self.active = 0
        self.max_active = 0
        self.mu = threading.Lock()

    def enter(self, who):
        with self.mu:
            self.active += 1
            self.max_active = max(self.max_active, self.active)

    def exit(self, who):
        with self.mu:
            self.active -= 1


_lock_guard = _LockGuard()


class FakeImage:
    def convert(self, mode):
        return self

    def save(self, buf, format=None):
        buf.write(b"PNGFAKE" + (b"x" * 8))


class _Namespace:
    pass


def _fake_call_pipe(p, w, h, s):
    _lock_guard.enter("gen")
    try:
        time.sleep(0.02)
        return FakeImage()
    finally:
        _lock_guard.exit("gen")


def install_fakes():
    pipe = _Namespace()
    pipe.processor = FakeProcessor()
    pipe.text_encoder = FakeTextEncoder()
    server._pipe = pipe
    server._ensure_loaded = lambda: None
    server._state.update(status="ready", error="")
    server._use_cuda = False  # TE 调度留桩（上卡路径由真机验收，这里只测契约与锁）
    server._call_pipe = _fake_call_pipe
    import transformers  # 装依赖后必然在场（requirements 锁 >=4.57）
    transformers.TextIteratorStreamer = FakeStreamer
    return pipe


client = TestClient(server.app)
install_fakes()

# ---------------------------------------------------------------- 用例组 ----

print("[health/models] 鉴权与双 id")
r = client.get("/api/health")
check("health 免鉴权 200", r.status_code == 200)
body = r.json()
check("health 报 chat_model", body.get("chat_model") == "chat-id-x", str(body))
check("health 报 te_residency/dit", "te_residency" in body and "dit" in body, str(body))

check("models 缺 key 401",
      client.get("/v1/models").status_code == 401)
check("models 错 key 401",
      client.get("/v1/models", headers={"Authorization": "Bearer nope"}).status_code == 401)
r = client.get("/v1/models", headers=AUTH)
ids = [m["id"] for m in r.json()["data"]]
check("models 双 id（生图+chat）", r.status_code == 200 and ids == ["qit-test", "chat-id-x"], str(ids))

print("[generations] 回归")
check("缺 prompt 400", client.post("/v1/images/generations", headers=AUTH,
                                   json={}).status_code == 400)
check("坏 size 400", client.post("/v1/images/generations", headers=AUTH,
                                 json={"prompt": "p", "size": "big"}).status_code == 400)
check("坏 n 400", client.post("/v1/images/generations", headers=AUTH,
                              json={"prompt": "p", "n": "many"}).status_code == 400)
check("url 格式 400", client.post("/v1/images/generations", headers=AUTH,
                                  json={"prompt": "p", "response_format": "url"}).status_code == 400)
check("generations 缺 key 401", client.post("/v1/images/generations",
                                            json={"prompt": "p"}).status_code == 401)
r = client.post("/v1/images/generations", headers=AUTH,
                json={"prompt": "一只橘猫", "size": "1024x1024", "seed": 7})
j = r.json()
ok = (r.status_code == 200 and j["seed"] == 7
      and base64.b64decode(j["data"][0]["b64_json"]).startswith(b"PNGFAKE"))
check("出图 b64 + seed 回声", ok, str(j)[:120])

print("[chat] 非流式")
check("messages 缺失 400", client.post("/v1/chat/completions", headers=AUTH,
                                       json={}).status_code == 400)
check("temperature 非数 400", client.post(
    "/v1/chat/completions", headers=AUTH,
    json={"messages": [{"role": "user", "content": "x"}], "temperature": "hot"}).status_code == 400)
check("chat 缺 key 401", client.post("/v1/chat/completions",
                                     json={"messages": [{"role": "user", "content": "x"}]}).status_code == 401)
r = client.post("/v1/chat/completions", headers=AUTH, json={
    "model": "anything-goes", "temperature": 0.7, "max_tokens": 128,
    "messages": [{"role": "system", "content": "你是提示词工程师"},
                 {"role": "user", "content": "画只猫"}]})
j = r.json()
ok = (r.status_code == 200 and j["object"] == "chat.completion"
      and j["choices"][0]["message"]["content"] == CHAT_FULL
      and j["choices"][0]["finish_reason"] == "stop"
      and j["usage"]["total_tokens"]
      == j["usage"]["prompt_tokens"] + j["usage"]["completion_tokens"])
check("非流式 chat.completion + usage", ok, str(j)[:200])
sys_p = server._pipe.processor.last_text[0]
check("chat template 带 system+user", "system:你是提示词工程师" in sys_p and "user:画只猫" in sys_p, sys_p)

print("[chat] SSE 流式")
with client.stream("POST", "/v1/chat/completions", headers=AUTH, json={
        "stream": True, "messages": [{"role": "user", "content": "画只猫"}]}) as resp:
    check("流式 content-type SSE",
          resp.headers.get("content-type", "").startswith("text/event-stream"))
    lines = [ln for ln in (raw.strip() for raw in resp.iter_lines()) if ln]
payloads = [ln[5:].strip() for ln in lines if ln.startswith("data:")]
check("以 [DONE] 收尾", payloads and payloads[-1] == "[DONE]", str(payloads[-2:]))
chunks = [json.loads(p) for p in payloads[:-1]]
first = chunks[0]["choices"][0]["delta"]
contents = "".join(c["choices"][0]["delta"].get("content", "") for c in chunks)
last_finish = chunks[-1]["choices"][0]["finish_reason"]
check("首块 role delta", first.get("role") == "assistant", str(first))
check("增量拼接 = 全文", contents == CHAT_FULL, contents)
check("末块 finish stop", last_finish == "stop", str(last_finish))
check("chunk 对象形状对齐 OpenAI",
      all(c["object"] == "chat.completion.chunk" for c in chunks))

print("[锁] chat × generations 并发单飞")
_lock_guard.max_active = 0
barrier = threading.Barrier(2)
results = []


def _fire(fn):
    barrier.wait()
    results.append(fn())


t1 = threading.Thread(target=_fire, args=(
    lambda: client.post("/v1/chat/completions", headers=AUTH,
                        json={"messages": [{"role": "user", "content": "画只猫"}]}),))
t2 = threading.Thread(target=_fire, args=(
    lambda: client.post("/v1/images/generations", headers=AUTH,
                        json={"prompt": "一只橘猫"}),))
t1.start(); t2.start(); t1.join(timeout=30); t2.join(timeout=30)
check("双路并发各自 200", len(results) == 2 and all(r.status_code == 200 for r in results),
      str([getattr(r, "status_code", "?") for r in results]))
check("_gen_lock 单飞（并发计数 ≤1）", _lock_guard.max_active <= 1,
      f"max_active={_lock_guard.max_active}")

# ------------------------------------------------------------------ 汇总 ----
print(f"\n{len(PASS)} passed, {len(FAIL)} failed")
if FAIL:
    print("FAILED:", *FAIL, sep="\n  - ")
    sys.exit(1)
print("ALL PASS")
