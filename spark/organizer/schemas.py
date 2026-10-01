"""Pydantic models for the organizer API contract (v1)."""

from __future__ import annotations

import base64
import binascii
import uuid
from typing import Annotated, Any, Literal, Optional, Union

from pydantic import AliasChoices, AwareDatetime, BaseModel, ConfigDict, Field, field_validator, model_validator

from . import sealed

ItemKind = Literal[
    "dictation",
    "meeting_online",
    "meeting_offline",
    "imported_media",
    "text",
    "image",
    "document",
    "file",
]

MAX_TEXT_CHARS = 400_000
MAX_IMAGE_BYTES = 12 * 1024 * 1024
# kind=file (contract "file", 2026-09-29): raw bytes up to 25 MiB; a bigger file arrives as kind=text with the
# Mac-extracted text and the same file metadata.
MAX_FILE_BYTES = 25 * 1024 * 1024
FILE_META_KEYS = ("filename", "uti", "mime", "size", "local_text", "captured_at", "parent_item_id", "frame_ms",
                  "pictures_redacted")


class _Model(BaseModel):
    # Unknown fields are ignored so a newer Mac client does not break an older service.
    model_config = ConfigDict(extra="ignore")


class SourceApp(_Model):
    bundle_id: Optional[str] = Field(default=None, max_length=256)
    name: str = Field(max_length=256)


class Segment(_Model):
    start_ms: int = Field(ge=0)
    end_ms: int = Field(ge=0)
    person_id: Optional[str] = Field(default=None, max_length=128)
    text: str = Field(max_length=MAX_TEXT_CHARS)


class PersonRef(_Model):
    person_id: str = Field(min_length=1, max_length=128)
    display_name: Optional[str] = Field(default=None, max_length=128)


class Item(_Model):
    # Stable per item; "id" is accepted as an alias. revision is monotonic per id: the same revision
    # again is a duplicate, a higher one replaces the content, a lower one is ignored as stale.
    item_id: str = Field(validation_alias=AliasChoices("item_id", "id"))
    revision: int = Field(ge=0)
    kind: ItemKind
    source_app: SourceApp
    started_at: AwareDatetime
    ended_at: Optional[AwareDatetime] = None
    text: Optional[str] = Field(default=None, max_length=MAX_TEXT_CHARS)
    segments: Optional[list[Segment]] = None
    persons: Optional[list[PersonRef]] = None
    image_b64: Optional[str] = None
    sha256: str = Field(min_length=1, max_length=128)
    # --- files (contract "file"; all optional and ignored by older services) ---
    filename: Optional[str] = Field(default=None, max_length=512)
    uti: Optional[str] = Field(default=None, max_length=256)
    mime: Optional[str] = Field(default=None, max_length=256)
    size: Optional[int] = Field(default=None, ge=0)
    bytes_b64: Optional[str] = None
    local_text: Optional[str] = Field(default=None, max_length=MAX_TEXT_CHARS)
    captured_at: Optional[AwareDatetime] = None
    # A video keyframe (or an extra GIF frame) sent as its own kind=image item: the media item it came from
    # and its position. It is read like any image and filed with its parent.
    parent_item_id: Optional[str] = Field(default=None, max_length=64)
    frame_ms: Optional[int] = Field(default=None, ge=0)
    # Privacy review F3: the Mac rebuilt this file's send copy with every picture in it redacted (and audio /
    # video left out). Only then are pictures inside the file bytes read with the vision model; otherwise they
    # are skipped (a picture that reaches a model must be the Mac's redacted copy, contract section 4).
    pictures_redacted: Optional[bool] = None

    @model_validator(mode="before")
    @classmethod
    def _captured_at_is_started_at(cls, data):
        # A file item may carry only captured_at; it is the item's time.
        if isinstance(data, dict) and not data.get("started_at") and data.get("captured_at"):
            data = {**data, "started_at": data["captured_at"]}
        return data

    @field_validator("parent_item_id")
    @classmethod
    def _parent_uuid(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return v
        try:
            uuid.UUID(v)
        except ValueError as exc:
            raise ValueError("parent_item_id must be a UUID string") from exc
        return v

    @field_validator("item_id")
    @classmethod
    def _uuid(cls, v: str) -> str:
        # Keep the Mac's exact spelling (Swift uses upper case) so ids round-trip.
        try:
            uuid.UUID(v)
        except ValueError as exc:
            raise ValueError("item_id must be a UUID string") from exc
        return v

    @model_validator(mode="after")
    def _content(self) -> "Item":
        if self.image_b64 is not None:
            if self.kind != "image":
                raise ValueError("image_b64 is only allowed for kind=image")
            try:
                raw = base64.b64decode(self.image_b64, validate=True)
            except (binascii.Error, ValueError) as exc:
                raise ValueError("image_b64 is not valid base64") from exc
            if len(raw) > MAX_IMAGE_BYTES:
                raise ValueError("image too large")
            if not (raw.startswith(b"\x89PNG") or raw.startswith(b"\xff\xd8")):
                raise ValueError("image_b64 must be PNG or JPEG")
        if self.bytes_b64 is not None:
            if self.kind != "file":
                raise ValueError("bytes_b64 is only allowed for kind=file")
            try:
                raw = base64.b64decode(self.bytes_b64, validate=True)
            except (binascii.Error, ValueError) as exc:
                raise ValueError("bytes_b64 is not valid base64") from exc
            if len(raw) > MAX_FILE_BYTES:
                raise ValueError("file too large: send it as kind=text with the extracted text")
        if self.kind == "file":
            if not (self.filename or "").strip():
                raise ValueError("kind=file needs filename")
            if self.bytes_b64 is None and not (self.local_text or self.text):
                raise ValueError("kind=file needs bytes_b64 or local_text")
            return self
        if self.kind == "image" and self.image_b64 is None and not self.text:
            raise ValueError("kind=image needs image_b64 or text")
        if self.kind != "image" and not (self.text or self.segments):
            raise ValueError("item needs text or segments")
        return self

    def image_bytes(self) -> Optional[bytes]:
        return base64.b64decode(self.image_b64) if self.image_b64 else None

    def file_bytes(self) -> Optional[bytes]:
        return base64.b64decode(self.bytes_b64) if self.bytes_b64 else None

    def blob(self) -> Optional[bytes]:
        """The item's binary content (image or file) as stored with the revision."""
        return self.image_bytes() if self.kind == "image" else self.file_bytes()


class ItemsIn(_Model):
    items: list[Item] = Field(max_length=500)


class ItemsOut(BaseModel):
    accepted: int
    duplicates: int


# ---- decisions -------------------------------------------------------------------


class _Decision(_Model):
    # Stable across retries from the Mac outbox. Older fixture callers may omit it.
    decision_id: Optional[str] = Field(default=None, min_length=1, max_length=128)


class RenameEvent(_Decision):
    kind: Literal["rename_event"]
    event_id: str
    title: str = Field(min_length=1, max_length=80)


# seg_id (optional, added for item-split): acts on one segment of an item filed by segments. Without it,
# a decision on such an item acts on all of its segments (remove_item: those in that event).
SegId = Optional[str]


class RemoveItem(_Decision):
    kind: Literal["remove_item"]
    event_id: str
    item_id: str
    seg_id: SegId = Field(default=None, min_length=1, max_length=32)


class MoveItem(_Decision):
    kind: Literal["move_item"]
    item_id: str
    to_event_id: str
    seg_id: SegId = Field(default=None, min_length=1, max_length=32)


class SameEvent(_Decision):
    kind: Literal["same_event"]
    a: str
    b: str
    answer: bool


class SamePerson(_Decision):
    kind: Literal["same_person"]
    a: str
    b: str
    answer: bool


class NamePerson(_Decision):
    kind: Literal["name_person"]
    person_id: str
    display_name: str = Field(min_length=1, max_length=128)


class PinEvent(_Decision):
    kind: Literal["pin_event"]
    event_id: str
    pinned: bool


class FeatureLess(_Decision):
    kind: Literal["feature_less"]
    event_id: str


class DeleteEvent(_Decision):
    kind: Literal["delete_event"]
    event_id: str


class UnfileItem(_Decision):
    kind: Literal["unfile_item"]
    item_id: str
    seg_id: SegId = Field(default=None, min_length=1, max_length=32)


class FileItemNewEvent(_Decision):
    """File an item (unfiled, or taken out of its event) as a new event of its own. The client may pick
    the new event's id (a UUID) so its local overlay and the Spark agree before the next pull."""
    kind: Literal["file_item_new_event"]
    item_id: str
    new_event_id: Optional[str] = Field(default=None, pattern=r"^[0-9a-fA-F-]{36}$")
    seg_id: SegId = Field(default=None, min_length=1, max_length=32)


Decision = Annotated[
    Union[RenameEvent, RemoveItem, MoveItem, SameEvent, SamePerson, NamePerson, PinEvent, FeatureLess, DeleteEvent,
          UnfileItem, FileItemNewEvent],
    Field(discriminator="kind"),
]


class DecisionsIn(_Model):
    decisions: list[Decision] = Field(max_length=200)


class Rejected(BaseModel):
    index: int
    reason: str


class DecisionsOut(BaseModel):
    applied: int
    rejected: list[Rejected] = []


class AnswerIn(_Model):
    answer: bool


# ---- phone inbox (contract C) ---------------------------------------------------------


class InboxIn(_Model):
    """Something from the phone, put here by `zhiji-inbox add --sealed` over SSH (the 织机 iPhone app, phone
    contract section 5). It waits on the Spark only until the Mac acks it.

    Only sealed entries are accepted: `blob` is an `mlseal1.` string sealed to the Mac's key on the phone. The
    Spark checks its shape only and stores it as is; it cannot open it. `inbox_id` is required and must be the
    lowercase entry id the phone sealed with (it is in the seal's AAD); `source` is "sealed" (the real source
    is inside the seal). The plaintext kinds of the retired iOS Shortcut path ("text", "image") are refused:
    that path could not seal, so its shares waited on the Spark in plaintext (privacy review F9)."""
    inbox_id: Optional[str] = Field(default=None, pattern=r"^[0-9a-fA-F-]{36}$")
    source: str = Field(min_length=1, max_length=64)
    kind: str = Field(min_length=1, max_length=16)
    blob: Optional[str] = Field(default=None, max_length=sealed.MAX_WIRE_CHARS)
    received_at: AwareDatetime

    @model_validator(mode="before")
    @classmethod
    def _no_plaintext(cls, data: Any) -> Any:
        # Refused before any field is read: a plaintext share is never parsed, measured or echoed.
        if isinstance(data, dict) and (data.get("kind") != "sealed" or "text" in data or "image_b64" in data):
            raise ValueError("only sealed entries are accepted (the plaintext phone path is retired)")
        return data

    @model_validator(mode="after")
    def _content(self) -> "InboxIn":
        if self.source != "sealed":
            raise ValueError('a sealed entry\'s source is "sealed"')
        if not sealed.is_entry_id(self.inbox_id):
            raise ValueError("a sealed entry needs the lowercase entry id it was sealed with")
        problem = sealed.wire_problem(self.blob)
        if problem:
            raise ValueError(f"blob: {problem}")
        return self
