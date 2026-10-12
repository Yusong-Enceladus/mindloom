"""Per-kind image routing: a chat screenshot is read by StepFun Step3-VL, every other kind by the organizer's model.

The classifier is image-read's own type step (one 64-token request to the organizer's model, the Qwen3.6-35B-A3B
NVFP4 that serves everything else; the type is right on 98-100% of the 98 mm-v1 test images, see
skills/image-read/BENCHMARK.md). Its answer picks the endpoint of the extraction step through
`ORGANIZER_IMAGE_ROUTES`; this module adds three things around that table:

  * the `stepfun-chat` preset: `ORGANIZER_IMAGE_ROUTER=stepfun-chat` routes `chat_screenshot` to Step3-VL on
    `ORGANIZER_STEP3_URL` (llama.cpp, loopback), through the adapter that prefills Step3's empty think block;
  * `FallbackClient`: a routed endpoint that is down or rejects a request (and, in image_read.read_image, an
    extraction that still fails the validator after its retry) is read again by the organizer's own model, so
    capture and reading never depend on the Step3 service being up;
  * `RouteStats`: how many images of each kind were read by which model, how many were re-read by the default
    model and why. Counts only: no content, no ids, no filenames. They go to the log and to /v1/infra/health.

Charts, documents, slides, handwriting, receipts, labels and photos are never routed to Step3-VL: it reads chart
data points at 89.7% (Qwen3.6 100%) and is 3-5x slower on them (eval/multimodal/BENCHMARK.md).
"""

from __future__ import annotations

import logging
import threading
from collections import Counter
from typing import Optional

from .clients import ChatClient, ChatResult, ModelUnavailable, safe_error

log = logging.getLogger("organizer.image_router")

CHAT = "chat_screenshot"
PRESET_STEP3_CHAT = "stepfun-chat"
DEFAULT_STEP3_URL = "http://127.0.0.1:30001"


def preset_routes(preset: str, step3_url: str = DEFAULT_STEP3_URL) -> dict:
    """The route table a named preset stands for (same shape as ORGANIZER_IMAGE_ROUTES)."""
    preset = (preset or "").strip()
    if not preset:
        return {}
    if preset != PRESET_STEP3_CHAT:
        raise ValueError(f"unknown ORGANIZER_IMAGE_ROUTER preset {preset!r}")
    return {CHAT: {"url": step3_url, "backend": "step3-llama-native", "model": "auto"}}


class RouteStats:
    """Thread-safe counters. `reads[image_type][model]` is the number of images whose extraction was answered by
    that model; `rerouted` counts images re-read by the default model after the routed one failed validation;
    `fallbacks` counts requests the routed endpoint did not answer (down / rejected), by image type and reason."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._reads: Counter = Counter()
        self._rerouted: Counter = Counter()
        self._fallbacks: Counter = Counter()

    def record_read(self, image_type: str, model: Optional[str], *, rerouted: bool = False, ok: bool = True) -> None:
        model = model or "none"
        with self._lock:
            self._reads[(image_type, model)] += 1
            if rerouted:
                self._rerouted[image_type] += 1
        log.info("image-read kind=%s model=%s rerouted=%s ok=%s", image_type, model, rerouted, ok)

    def record_fallback(self, image_type: str, reason: str) -> None:
        with self._lock:
            self._fallbacks[(image_type, reason)] += 1
        log.warning("image-read kind=%s routed endpoint not used: %s", image_type, reason)

    def snapshot(self) -> dict:
        with self._lock:
            reads: dict[str, dict[str, int]] = {}
            for (kind, model), n in sorted(self._reads.items()):
                reads.setdefault(kind, {})[model] = n
            fallbacks: dict[str, dict[str, int]] = {}
            for (kind, reason), n in sorted(self._fallbacks.items()):
                fallbacks.setdefault(kind, {})[reason] = n
            return {"reads": reads, "rerouted": dict(sorted(self._rerouted.items())), "fallbacks": fallbacks}


class FallbackClient:
    """A routed endpoint with the organizer's own client behind it.

    `complete` asks the routed endpoint first. If it is unreachable or answers a server error (ModelUnavailable),
    or rejects the request (ValueError: HTTP 4xx, an image type it cannot take), the same request goes to
    `fallback`, so the item is still read. read_image also uses `.fallback` to re-read an image whose routed
    extraction failed validation twice."""

    def __init__(self, primary: ChatClient, fallback: ChatClient, image_type: str, stats: RouteStats) -> None:
        self.primary = primary
        self.fallback = fallback
        self.image_type = image_type
        self.stats = stats

    @property
    def model_id(self) -> str:
        return self.primary.model_id

    def complete(self, messages: list[dict], schema: Optional[dict], schema_name: str, max_tokens: int) -> ChatResult:
        try:
            return self.primary.complete(messages, schema, schema_name, max_tokens)
        except ModelUnavailable as exc:
            self.stats.record_fallback(self.image_type, f"unavailable ({safe_error(exc)})")
        except ValueError as exc:
            self.stats.record_fallback(self.image_type, f"rejected ({safe_error(exc)})")
        return self.fallback.complete(messages, schema, schema_name, max_tokens)
