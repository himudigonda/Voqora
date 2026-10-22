from __future__ import annotations

import unicodedata
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, ValidationError, field_validator

MAX_STYLE_CHARS = 300

Emotion = Literal[
    "neutral", "happy", "sad", "angry", "fearful", "disgusted", "surprised"
]
Pace = Literal["slow", "normal", "fast"]
Pitch = Literal["low", "normal", "high"]
Dialect = Literal["cantonese", "sichuanese"]


class Delivery(BaseModel):
    model_config = ConfigDict(extra="forbid")

    emotion: Emotion | None = None
    style: str | None = None
    pace: Pace | None = None
    pitch: Pitch | None = None
    dialect: Dialect | None = None

    @field_validator("style")
    @classmethod
    def require_clean_style(cls, value: str | None) -> str | None:
        if value is None:
            return None
        cleaned = unicodedata.normalize("NFC", value).strip()
        if len(cleaned) > MAX_STYLE_CHARS:
            raise ValueError(f"style must be at most {MAX_STYLE_CHARS} characters")
        if any(unicodedata.category(ch) in {"Cc", "Cf"} for ch in cleaned):
            raise ValueError("style must not contain control characters")
        return cleaned or None

    @property
    def is_empty(self) -> bool:
        return not self.model_dump(exclude_none=True)

    def to_record(self) -> dict[str, str]:
        return self.model_dump(exclude_none=True)


def style_from_instructions(instructions: str) -> str | None:
    spaced = "".join(
        " " if ch.isspace() or unicodedata.category(ch).startswith("C") else ch
        for ch in instructions
    )
    collapsed = unicodedata.normalize("NFC", " ".join(spaced.split()))
    return collapsed[:MAX_STYLE_CHARS].rstrip() or None


def delivery_from_record(record: Any) -> Delivery | None:
    if not isinstance(record, dict):
        return None
    try:
        delivery = Delivery.model_validate(record)
    except ValidationError:
        return None
    return None if delivery.is_empty else delivery
