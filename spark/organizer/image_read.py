"""Reading an image item with the image-read skill: type first, then that type's extraction.

Both steps send the same system prompt and the image first, so a prefix-caching server (vLLM) reuses the
image prefill for the second step. The type decides the extraction schema and, optionally, the endpoint:
`clients` maps an image type (or "detect") to another chat client; anything unmapped uses the organizer's
own model (Qwen3.6-35B-A3B NVFP4 on the same Spark, the benchmark's pick for every type:
eval/multimodal/BENCHMARK.md).

A failed type step reads the image as "other" (plain text lines). An extraction that still fails the
validator after the retry is kept only after skills/image-read/scripts/validate.py sanitize() has emptied
every value the rules reject. An endpoint that rejects the request (HTTP 4xx, e.g. a text-only model)
raises ValueError to the caller, which places the item without a reading.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Optional

from .clients import ChatClient
from .skills import Harness, RunResult

SKILL = "image-read"
DETECT_MAX_TOKENS = 64


@dataclass
class ImageReading:
    ok: bool                      # a reading was produced (possibly sanitized)
    image_type: str
    output: Optional[dict]        # the type's extraction as kept (sanitized when needed)
    reading: dict                 # reading.compose(): type, gist, text, lines, fields, numbers, messages
    run_id: Optional[str]         # the extraction run
    detect_run_id: Optional[str]
    detected: bool                # the type came from a valid type step (else "other")
    sanitized: int = 0            # values emptied because they failed validation after the retry
    attempts: int = 0
    runs: list[RunResult] = field(default_factory=list)
    latency_s: float = 0.0


def read_image(harness: Harness, image: bytes, data: dict, *, subject: Optional[str] = None,
               clients: Optional[dict[str, ChatClient]] = None, as_of: Optional[str] = None,
               forced_type: Optional[str] = None) -> ImageReading:
    """Read one image. `data` is the item context shown to the model (source_app, captured_at).
    `forced_type` skips the type step (eval: extraction with the true type)."""
    started = time.time()
    reg = harness.registry
    reading_mod = reg.script(SKILL, "reading")
    validate_mod = reg.script(SKILL, "validate")
    clients = clients or {}
    runs: list[RunResult] = []

    detect_run_id = None
    detected = False
    if forced_type:
        image_type = forced_type
    else:
        det = harness.run("image_detect", data, context={"stage": "detect"}, images=[image], subject=subject,
                          task=reading_mod.detect_task(), schema=reading_mod.DETECT_SCHEMA,
                          client=clients.get("detect"), max_tokens=DETECT_MAX_TOKENS, as_of=as_of)
        runs.append(det)
        detect_run_id = det.run_id
        detected = det.ok and det.output.get("type") in reading_mod.TYPE_SCHEMAS
        image_type = det.output["type"] if detected else "other"

    res = harness.run("image_read", {**data, "type": image_type}, context={"stage": "extract", "type": image_type},
                      images=[image], subject=subject, task=reading_mod.extract_task(image_type),
                      schema=reading_mod.schema_for(image_type), client=clients.get(image_type), as_of=as_of)
    runs.append(res)
    output, sanitized = res.output, 0
    if not res.ok and res.candidate is not None:
        output, sanitized = validate_mod.sanitize(image_type, res.candidate)
    ok = output is not None
    reading = reading_mod.compose(image_type, output) if ok else reading_mod.compose(image_type, {})
    return ImageReading(ok=ok, image_type=image_type, output=output, reading=reading, run_id=res.run_id,
                        detect_run_id=detect_run_id, detected=detected, sanitized=sanitized,
                        attempts=sum(r.attempts for r in runs), runs=runs, latency_s=time.time() - started)
