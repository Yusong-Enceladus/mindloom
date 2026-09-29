"""Clients for the local OpenAI-compatible endpoints (vLLM on the same Spark).

Only loopback URLs are expected here. Nothing in this module talks to the internet.
"""

from __future__ import annotations

import base64
import hashlib
import math
from dataclasses import dataclass, field
from typing import Optional, Protocol

import httpx


class ModelUnavailable(RuntimeError):
    """The endpoint could not be reached or returned a server error; retry later."""


@dataclass
class ChatResult:
    text: str
    model: str
    prompt_tokens: Optional[int] = None
    completion_tokens: Optional[int] = None


class ChatClient(Protocol):
    model_id: str

    def complete(self, messages: list[dict], schema: Optional[dict], schema_name: str, max_tokens: int) -> ChatResult: ...


class EmbedClient(Protocol):
    model_id: str

    def embed(self, texts: list[str]) -> list[list[float]]: ...


def image_data_uri(data: bytes) -> str:
    mime = "image/png" if data.startswith(b"\x89PNG") else "image/jpeg"
    return f"data:{mime};base64,{base64.b64encode(data).decode()}"


def _resolve_model(client: httpx.Client, requested: str) -> str:
    if requested and requested != "auto":
        return requested
    try:
        resp = client.get("/models")
        resp.raise_for_status()
        return resp.json()["data"][0]["id"]
    except (httpx.HTTPError, KeyError, IndexError, ValueError) as exc:
        raise ModelUnavailable(f"cannot list models: {exc}") from exc


def _check_model(client: httpx.Client, requested: str) -> str:
    """Probe now; a cached model name is not evidence of current availability."""
    try:
        resp = client.get("/models", timeout=5.0)
        resp.raise_for_status()
        ids = [row["id"] for row in resp.json()["data"]]
        model = ids[0] if not requested or requested == "auto" else requested
        if model not in ids:
            raise ValueError("configured model is not served")
        return model
    except (httpx.HTTPError, KeyError, IndexError, TypeError, ValueError) as exc:
        raise ModelUnavailable(f"model readiness check failed: {exc}") from exc


class OpenAIChatClient:
    """Chat completions with guided JSON decoding, temperature 0 and thinking disabled."""

    def __init__(self, base_url: str, model: str = "auto", timeout_s: float = 180.0):
        self._http = httpx.Client(base_url=base_url.rstrip("/"), timeout=timeout_s, trust_env=False)
        self._requested = model
        self._model: Optional[str] = None

    @property
    def model_id(self) -> str:
        if self._model is None:
            self._model = _resolve_model(self._http, self._requested)
        return self._model

    def check_available(self) -> str:
        self._model = _check_model(self._http, self._requested)
        return self._model

    def complete(self, messages: list[dict], schema: Optional[dict], schema_name: str, max_tokens: int) -> ChatResult:
        body = {
            "model": self.model_id,
            "messages": messages,
            "temperature": 0,
            "max_tokens": max_tokens,
            # Qwen3 templates read enable_thinking, DeepSeek-V4 reads thinking; each ignores the other.
            # Without "thinking": false DeepSeek-V4-Flash spends the whole budget reasoning.
            "chat_template_kwargs": {"enable_thinking": False, "thinking": False},
        }
        if schema is not None:  # None = free-form output (used only by the eval's no-skill ablation)
            body["response_format"] = {
                "type": "json_schema",
                "json_schema": {"name": schema_name, "schema": schema, "strict": True},
            }
        try:
            resp = self._http.post("/chat/completions", json=body)
        except httpx.HTTPError as exc:
            raise ModelUnavailable(str(exc)) from exc
        if resp.status_code >= 500:
            raise ModelUnavailable(f"HTTP {resp.status_code}: {resp.text[:200]}")
        if resp.status_code >= 400:
            raise ValueError(f"HTTP {resp.status_code}: {resp.text[:300]}")
        data = resp.json()
        usage = data.get("usage") or {}
        return ChatResult(
            text=data["choices"][0]["message"].get("content") or "",
            model=data.get("model", self.model_id),
            prompt_tokens=usage.get("prompt_tokens"),
            completion_tokens=usage.get("completion_tokens"),
        )


class Step3LlamaNativeClient(OpenAIChatClient):
    """Opt-in adapter for Step3-VL's always-thinking llama.cpp template.

    Prefill an empty reasoning block using the native completion endpoint, as
    required by that template. Keep JSON grammar and skill validation enabled.
    Only inline images are supported; no remote image URLs are fetched.
    """

    def __init__(self, base_url: str, model: str = "auto", timeout_s: float = 180.0):
        root = base_url.rstrip("/").removesuffix("/v1")
        super().__init__(root + "/v1", model, timeout_s)
        self._native = httpx.Client(base_url=root, timeout=timeout_s, trust_env=False)

    def complete(self, messages: list[dict], schema: Optional[dict], schema_name: str, max_tokens: int) -> ChatResult:
        images, blocks = [], []
        marker = None
        for message in messages:
            role = message["role"]
            if role not in {"system", "user", "assistant"}:
                raise ValueError("Step3 organizer adapter supports text/image messages only")
            content = message["content"]
            parts = [{"type": "text", "text": content}] if isinstance(content, str) else content
            text = ""
            for part in parts:
                if part["type"] == "text":
                    # Quoted material must not inject a native ChatML role delimiter.
                    text += part["text"].replace("<|", "\\u003c|")
                elif part["type"] == "image_url":
                    url = part["image_url"]["url"]
                    if not url.startswith(("data:image/png;base64,", "data:image/jpeg;base64,")):
                        raise ValueError("only inline PNG/JPEG data is allowed")
                    image = url.split(",", 1)[1]
                    base64.b64decode(image, validate=True)
                    if marker is None:
                        try:
                            props = self._native.get("/props")
                            props.raise_for_status()
                            marker = props.json()["media_marker"]
                        except (httpx.HTTPError, KeyError, ValueError) as exc:
                            raise ModelUnavailable("cannot resolve native image marker") from exc
                    images.append(image)
                    text += marker
                else:
                    raise ValueError("unsupported message part")
            blocks.append(f"<|im_start|>{role}\n{text}<|im_end|>\n")
        prompt = "".join(blocks) + "<|im_start|>assistant\n<think>\n\n</think>\n"
        body = {"prompt": {"prompt_string": prompt, "multimodal_data": images} if images else prompt,
                "n_predict": max_tokens, "temperature": 0, "cache_prompt": False}
        if schema is not None:  # None = free-form output, as in OpenAIChatClient
            body["json_schema"] = schema
        try:
            resp = self._native.post("/completion", json=body)
        except httpx.HTTPError as exc:
            raise ModelUnavailable(str(exc)) from exc
        if resp.status_code >= 500:
            raise ModelUnavailable(f"HTTP {resp.status_code}")
        if resp.status_code >= 400:
            # Same contract as OpenAIChatClient: a rejected request is permanent (ValueError), so
            # image-read falls back to placing the item without text instead of failing its job.
            raise ValueError(f"HTTP {resp.status_code}: {resp.text[:300]}")
        data = resp.json()
        timings = data.get("timings") or {}
        return ChatResult(data["content"], self.model_id, timings.get("prompt_n"), timings.get("predicted_n"))


class OpenAIEmbedClient:
    def __init__(self, base_url: str, model: str = "auto", timeout_s: float = 30.0):
        self._http = httpx.Client(base_url=base_url.rstrip("/"), timeout=timeout_s, trust_env=False)
        self._requested = model
        self._model: Optional[str] = None

    @property
    def model_id(self) -> str:
        if self._model is None:
            self._model = _resolve_model(self._http, self._requested)
        return self._model

    def check_available(self) -> str:
        self._model = _check_model(self._http, self._requested)
        return self._model

    def embed(self, texts: list[str]) -> list[list[float]]:
        try:
            resp = self._http.post("/embeddings", json={"model": self.model_id, "input": texts})
            resp.raise_for_status()
        except httpx.HTTPError as exc:
            raise ModelUnavailable(str(exc)) from exc
        rows = sorted(resp.json()["data"], key=lambda r: r["index"])
        return [normalize(r["embedding"]) for r in rows]


def normalize(vec: list[float]) -> list[float]:
    norm = math.sqrt(sum(v * v for v in vec)) or 1.0
    return [v / norm for v in vec]


@dataclass
class HashEmbedClient:
    """Deterministic character-bigram hashing embedder. Used by tests; no model."""

    dim: int = 256
    model_id: str = "hash-bigram-256"
    calls: int = field(default=0)

    def embed(self, texts: list[str]) -> list[list[float]]:
        self.calls += 1
        out = []
        for text in texts:
            vec = [0.0] * self.dim
            chars = [c for c in text if not c.isspace()]
            for a, b in zip(chars, chars[1:]):
                h = int.from_bytes(hashlib.blake2b((a + b).encode(), digest_size=4).digest(), "big")
                vec[h % self.dim] += 1.0
            out.append(normalize(vec))
        return out
