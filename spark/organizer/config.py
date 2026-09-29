"""Runtime settings, read from environment variables (ORGANIZER_*)."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Optional
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[2]


def _env(name: str, default: str) -> str:
    return os.environ.get(name, default)


@dataclass
class Settings:
    data_dir: Path = field(default_factory=lambda: Path(_env("ORGANIZER_DATA_DIR", str(Path.home() / "hack" / "organizer-data"))))
    skills_dir: Path = field(default_factory=lambda: Path(_env("ORGANIZER_SKILLS_DIR", str(_REPO_ROOT / "skills"))))
    host: str = field(default_factory=lambda: _env("ORGANIZER_HOST", "127.0.0.1"))
    port: int = field(default_factory=lambda: int(_env("ORGANIZER_PORT", "8765")))
    # OpenAI-compatible chat endpoint (vLLM). "auto" = first id from GET /v1/models.
    llm_base_url: str = field(default_factory=lambda: _env("ORGANIZER_LLM_URL", "http://127.0.0.1:8000/v1"))
    llm_model: str = field(default_factory=lambda: _env("ORGANIZER_LLM_MODEL", "auto"))
    chat_backend: str = field(default_factory=lambda: _env("ORGANIZER_CHAT_BACKEND", "openai"))
    # image-read endpoints per image type, as JSON: {"<type>" or "detect": {"url": "http://127.0.0.1:30000/v1",
    # "model": "auto", "backend": "openai" | "step3-llama-native"}}. Unset types use the chat endpoint above
    # (the mm-v1 benchmark picks Qwen3.6-35B-A3B NVFP4 for all seven types: eval/multimodal/BENCHMARK.md).
    image_routes: str = field(default_factory=lambda: _env("ORGANIZER_IMAGE_ROUTES", ""))
    llm_timeout_s: float = field(default_factory=lambda: float(_env("ORGANIZER_LLM_TIMEOUT", "180")))
    # OpenAI-compatible embeddings endpoint (vLLM --runner pooling).
    embed_base_url: str = field(default_factory=lambda: _env("ORGANIZER_EMBED_URL", "http://127.0.0.1:8002/v1"))
    embed_model: str = field(default_factory=lambda: _env("ORGANIZER_EMBED_MODEL", "auto"))
    # Open questions allowed at once, per kind (same_event and same_person are budgeted separately).
    max_open_questions: int = 2
    # same_event questions per calendar day of the subject item, and per target event per day.
    ask_per_day: int = 2
    ask_per_event_per_day: int = 1
    # Unanswered questions expire after this many hours (by the organizer clock); placements stay.
    question_ttl_h: float = 72.0
    # Model-visible / semantic time: "wall" (live default), "replay" (latest captured item time, for
    # replaying historical items) or "fixed:<ISO>" (tests). /v1/health reports it.
    # A historical stream or backfill (items captured days or weeks before they are sent) MUST use
    # "replay": with "wall", question expiry (question_ttl_h) never passes, so the first questions keep the
    # question budget full for the whole run (every later ask becomes a provisional new event and every
    # merge question is dropped), and "today" for rank and dates is the wall clock, not the stream's time.
    clock: str = field(default_factory=lambda: _env("ORGANIZER_CLOCK", "wall"))
    # Items keep the local offset the Mac sent; a UTC ("Z") capture time is read in ORGANIZER_TZ (IANA
    # name, default this host's zone) for dates, 今天/明天 and daily budgets. Read by skills/event-brief/
    # scripts/dates.py and clock.wall_now from the environment.
    tz: str = field(default_factory=lambda: _env("ORGANIZER_TZ", ""))
    # The Mac user's own voice person id(s), comma separated. A voice labelled 我/本人 is detected anyway.
    owner_person_ids: tuple = field(default_factory=lambda: tuple(
        v.strip() for v in _env("ORGANIZER_OWNER_IDS", "").split(",") if v.strip()))
    # Names the owner goes by in chats and pasted text, comma separated (e.g. a real name and a nickname).
    # Such senders are the owner and never become persons; 我/本人/自己 are always included.
    owner_aliases: tuple = field(default_factory=lambda: tuple(
        v.strip() for v in _env("ORGANIZER_OWNER_ALIASES", "我").split(",") if v.strip()))
    # Eval only (synthetic data): store each model call's user message in runs.input_text.
    record_inputs: bool = False
    candidates_k: int = 5
    rank_max_events: int = 40
    rank_every_n_items: int = 10
    job_max_attempts: int = 3
    # Contract D: model calls on a bounded pool (organizer/pipeline.py). 1 = serial (one item at a time,
    # briefs inline). >1 = pipeline mode: item-local calls prefetched, briefs/rank concurrent at a fixed
    # lag; assignments stay in queue order and the outcome does not depend on the pool size.
    workers: int = field(default_factory=lambda: int(_env("ORGANIZER_WORKERS", "1")))
    pipeline_lag: int = field(default_factory=lambda: int(_env("ORGANIZER_PIPELINE_LAG", "2")))
    start_worker: bool = True
    # Link token: <data_dir>/link_token is created on first start. While it exists, every /v1/* route
    # needs "Authorization: Bearer <token>". ORGANIZER_REQUIRE_TOKEN=0 turns the check off (tests, eval).
    require_token: bool = field(default_factory=lambda: _env("ORGANIZER_REQUIRE_TOKEN", "1") != "0")
    # Unix socket (absolute path, in a 0700 directory); default <data_dir>/organizer.sock. It is the
    # only listener unless TCP is opted into: the Mac forwards to it, and local tools (ctl.sh, eval,
    # recall) use it, so no other local process can stand in for the organizer and collect the token
    # while it is down.
    uds: Optional[Path] = field(default_factory=lambda: Path(v) if (v := _env("ORGANIZER_UDS", "")) else None)
    # Loopback TCP on host:port only with ORGANIZER_TCP=1 (explicit opt-in). Any local user can bind a
    # free loopback port while the organizer is down, and a client sending the token there leaks it.
    tcp: bool = field(default_factory=lambda: _env("ORGANIZER_TCP", "0") == "1")

    @property
    def socket_path(self) -> Path:
        return self.uds if self.uds is not None else self.data_dir / "organizer.sock"

    @property
    def db_path(self) -> Path:
        return self.data_dir / "organizer.db"

    @property
    def token_path(self) -> Path:
        return self.data_dir / "link_token"
