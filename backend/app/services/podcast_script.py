import math

from pydantic import (
    BaseModel,
    Field,
    ValidationInfo,
    field_validator,
    model_validator,
)

from app.services.text_normalizer import strip_markdown_for_narration
from app.services.voice_blends import is_blend_id
from app.services.voices import is_known_voice, is_kokoro_voice

PODCAST_KIND = "podcast"

MAX_SPEAKERS = 4
MAX_TURNS = 600
MAX_TURN_CHARS = 2_000
MAX_TITLE_CHARS = 200
MAX_SPEAKER_NAME_CHARS = 60
MAX_SECTION_TITLE_CHARS = 120
MAX_PAUSE_SECONDS = 3.0
DEFAULT_PAUSE_SECONDS = 0.4
_MAX_LISTED_UNKNOWN = 5
PODCAST_KOKORO_ONLY_MESSAGE = "podcasts support Kokoro voices only"
SPEAKER_ID_PATTERN = r"^[A-Za-z0-9_-]{1,32}$"
STORED_SCRIPT_CONTEXT = {"stored": True}


def _single_line(value: str) -> str:
    return " ".join(value.split())


def _require_voice(value: str, info: ValidationInfo) -> str:
    if is_known_voice(value) and not is_kokoro_voice(value):
        raise ValueError(PODCAST_KOKORO_ONLY_MESSAGE)
    if is_known_voice(value):
        return value
    if is_blend_id(value) and (info.context or {}).get("stored"):
        return value
    raise ValueError(f"unknown voice: {value}")


class Speaker(BaseModel):
    id: str = Field(pattern=SPEAKER_ID_PATTERN)
    name: str = Field(min_length=1, max_length=MAX_SPEAKER_NAME_CHARS)
    voice: str

    @field_validator("name")
    @classmethod
    def require_name(cls, value: str) -> str:
        value = _single_line(value)
        if not value:
            raise ValueError("speaker name must not be blank")
        return value

    @field_validator("voice")
    @classmethod
    def require_known_voice(cls, value: str, info: ValidationInfo) -> str:
        return _require_voice(value, info)


class Turn(BaseModel):
    speaker_id: str = Field(pattern=SPEAKER_ID_PATTERN)
    text: str = Field(min_length=1, max_length=MAX_TURN_CHARS)
    pause_after_seconds: float = Field(
        default=DEFAULT_PAUSE_SECONDS, ge=0.0, le=MAX_PAUSE_SECONDS
    )
    section: str | None = Field(default=None, max_length=MAX_SECTION_TITLE_CHARS)

    @field_validator("text")
    @classmethod
    def require_spoken_text(cls, value: str) -> str:
        value = strip_markdown_for_narration(value.strip()).strip()
        if not value or value == "-":
            raise ValueError("turn text must not be blank")
        return value

    @field_validator("pause_after_seconds")
    @classmethod
    def require_finite_pause(cls, value: float) -> float:
        if not math.isfinite(value):
            raise ValueError("pause must be a finite number")
        return value

    @field_validator("section")
    @classmethod
    def normalize_section(cls, value: str | None) -> str | None:
        if value is None:
            return None
        return _single_line(value) or None


class PodcastScript(BaseModel):
    title: str = Field(min_length=1, max_length=MAX_TITLE_CHARS)
    speakers: list[Speaker] = Field(min_length=1, max_length=MAX_SPEAKERS)
    turns: list[Turn] = Field(min_length=1, max_length=MAX_TURNS)

    @field_validator("title")
    @classmethod
    def require_title(cls, value: str) -> str:
        value = _single_line(value)
        if not value:
            raise ValueError("title must not be blank")
        return value

    @model_validator(mode="after")
    def require_known_speakers(self) -> "PodcastScript":
        ids = [speaker.id for speaker in self.speakers]
        if len(set(ids)) != len(ids):
            raise ValueError("speaker ids must be unique")
        known = set(ids)
        unknown = sorted(
            {t.speaker_id for t in self.turns if t.speaker_id not in known}
        )
        if unknown:
            listed = ", ".join(unknown[:_MAX_LISTED_UNKNOWN])
            raise ValueError(f"turns reference unknown speakers: {listed}")
        return self

    def speaker(self, speaker_id: str) -> Speaker:
        return next(s for s in self.speakers if s.id == speaker_id)

    def sections(self) -> list[dict[str, int | str]]:
        starts = [
            (index, turn.section)
            for index, turn in enumerate(self.turns, start=1)
            if turn.section
        ]
        if not starts or starts[0][0] != 1:
            starts.insert(0, (1, self.title))
        return [
            {
                "title": title,
                "start_page": start,
                "end_page": (
                    starts[i + 1][0] - 1 if i + 1 < len(starts) else len(self.turns)
                ),
            }
            for i, (start, title) in enumerate(starts)
        ]

    def word_count(self) -> int:
        return sum(len(turn.text.split()) for turn in self.turns)

    def pause_seconds(self) -> float:
        return sum(turn.pause_after_seconds for turn in self.turns)
