"""Podcast HTTP surface: AI script writing and multi-voice rendering."""

import asyncio

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field, field_validator, model_validator

from app.api.audiobook import (
    _pending_audio_bytes,
    _render_cover_task,
    _spawn_bg,
    _validate_book_id,
    llm_credential,
)
from app.core.config import settings
from app.core.logging import get_logger
from app.services import podcast_library
from app.services.audiobook_service import AudiobookService
from app.services.audiobook_store import AudiobookStore
from app.services.import_limits import ImportLimitError, ensure_storage_capacity
from app.services.languages import LANGUAGES
from app.services.llm_providers import LLMConfigError, LLMCredential, LLMError
from app.services.podcast_generator import (
    MAX_SOURCE_CHARS,
    Host,
    PodcastGenerationError,
    PodcastGenerator,
    ScriptBrief,
    Style,
)
from app.services.podcast_script import (
    MAX_SPEAKER_NAME_CHARS,
    MAX_TITLE_CHARS,
    PODCAST_KIND,
    PODCAST_KOKORO_ONLY_MESSAGE,
    PodcastScript,
    Speaker,
)
from app.services.voices import is_known_voice, is_kokoro_voice, resolve_voice

router = APIRouter()
log = get_logger(__name__)

_LANGUAGE_CODES = frozenset(language["code"] for language in LANGUAGES)
_MAX_CONCURRENT_GENERATIONS = 2
_generation_slots = asyncio.Semaphore(_MAX_CONCURRENT_GENERATIONS)
_HOST_COUNTS: dict[str, frozenset[int]] = {
    "deep_dive": frozenset({1, 2}),
    "brief": frozenset({1, 2}),
    "debate": frozenset({2}),
    "lecture": frozenset({1}),
}


def _base_language(code: str) -> str:
    return code.split("-")[0]


def _optional_title(value: str | None) -> str | None:
    if value is None:
        return None
    return " ".join(value.split()) or None


class ScriptSource(BaseModel):
    text: str | None = Field(default=None, max_length=MAX_SOURCE_CHARS)
    book_id: str | None = Field(default=None, max_length=64)

    @field_validator("text")
    @classmethod
    def strip_text(cls, value: str | None) -> str | None:
        if value is None:
            return None
        value = value.strip()
        if not value:
            raise ValueError("source text must not be blank")
        return value

    @model_validator(mode="after")
    def require_one_source(self) -> "ScriptSource":
        if (self.text is None) == (self.book_id is None):
            raise ValueError("provide exactly one of text or book_id")
        return self


class HostRequest(BaseModel):
    name: str = Field(min_length=1, max_length=MAX_SPEAKER_NAME_CHARS)
    voice: str

    @field_validator("name")
    @classmethod
    def require_name(cls, value: str) -> str:
        value = " ".join(value.split())
        if not value:
            raise ValueError("host name must not be blank")
        return value

    @field_validator("voice")
    @classmethod
    def require_known_voice(cls, value: str) -> str:
        if not is_known_voice(value):
            raise ValueError(f"unknown voice: {value}")
        if not is_kokoro_voice(value):
            raise ValueError(PODCAST_KOKORO_ONLY_MESSAGE)
        return value


class ScriptRequest(BaseModel):
    source: ScriptSource
    style: Style = "deep_dive"
    minutes: int = Field(default=8, ge=2, le=30)
    language: str = "en-us"
    hosts: list[HostRequest] = Field(min_length=1, max_length=2)
    title: str | None = Field(default=None, max_length=MAX_TITLE_CHARS)

    @field_validator("language")
    @classmethod
    def require_known_language(cls, value: str) -> str:
        if value not in _LANGUAGE_CODES:
            raise ValueError(f"unsupported language: {value}")
        return value

    @field_validator("title")
    @classmethod
    def normalize_title(cls, value: str | None) -> str | None:
        return _optional_title(value)

    @model_validator(mode="after")
    def require_host_count_for_style(self) -> "ScriptRequest":
        allowed = _HOST_COUNTS[self.style]
        if len(self.hosts) not in allowed:
            counts = " or ".join(str(count) for count in sorted(allowed))
            raise ValueError(f"the {self.style} style needs {counts} host(s)")
        names = [host.name.casefold() for host in self.hosts]
        if len(set(names)) != len(names):
            raise ValueError("host names must be different")
        language = _base_language(self.language)
        specs = [resolve_voice(host.voice) for host in self.hosts]
        if any(spec is None or _base_language(spec.lang) != language for spec in specs):
            raise ValueError("every host voice must speak the script language")
        return self

    def brief(self) -> ScriptBrief:
        return ScriptBrief(
            style=self.style,
            minutes=self.minutes,
            language=self.language,
            hosts=tuple(Host(name=h.name, voice=h.voice) for h in self.hosts),
            title=self.title,
        )


class ScriptResponse(BaseModel):
    script: PodcastScript
    used_notes: bool
    repaired: bool
    source_truncated: bool
    estimated_audio_seconds: float
    llm_provider: str
    llm_model: str


class RenderRequest(BaseModel):
    script: PodcastScript
    title: str | None = Field(default=None, max_length=MAX_TITLE_CHARS)

    @field_validator("title")
    @classmethod
    def normalize_title(cls, value: str | None) -> str | None:
        return _optional_title(value)


class RenderResponse(BaseModel):
    status: str
    book_id: str
    kind: str
    title: str
    turn_count: int
    speakers: list[Speaker]
    estimated_audio_seconds: float


def _script_credential(credential: LLMCredential | None) -> LLMCredential:
    if credential is None:
        raise HTTPException(
            status_code=400,
            detail="Choose an AI provider in Settings to write a podcast script.",
        )
    problem = credential.problem()
    if problem:
        raise HTTPException(status_code=400, detail=problem)
    return credential


async def _book_source(book_id: str) -> tuple[str, bool]:
    _validate_book_id(book_id)
    if AudiobookStore.read_meta(book_id) is None:
        raise HTTPException(status_code=404, detail="Book not found.")
    try:
        text, truncated = await asyncio.get_running_loop().run_in_executor(
            None, podcast_library.book_source_text, book_id, MAX_SOURCE_CHARS
        )
    except (OSError, ValueError) as exc:
        log.warning(
            "podcast.source_unreadable",
            extra={"book_id": book_id, "failure_code": "podcast_source_unreadable"},
        )
        raise HTTPException(
            status_code=422, detail="Voqora could not read this item's text."
        ) from exc
    if not text.strip():
        raise HTTPException(
            status_code=422, detail="This item has no text to turn into a podcast."
        )
    return text, truncated


async def _source_text(source: ScriptSource) -> tuple[str, bool]:
    if source.book_id is not None:
        return await _book_source(source.book_id)
    return source.text or "", False


def _require_affordable(
    credential: LLMCredential, brief: ScriptBrief, source_chars: int
) -> None:
    envelope = PodcastGenerator.cost_envelope_usd(credential, brief, source_chars)
    cap = settings.MAX_GEMINI_COST_USD_PER_BOOK
    if envelope > cap:
        raise HTTPException(
            status_code=413,
            detail=(
                f"The conservative {credential.name} cost envelope "
                f"${envelope:.2f} exceeds the ${cap:.2f} limit. "
                "Use a shorter source or a cheaper model."
            ),
        )


@router.post("/podcast/script", response_model=ScriptResponse)
async def write_podcast_script(
    req: ScriptRequest,
    credential: LLMCredential | None = Depends(llm_credential),
):
    """Write a multi-voice podcast script from text or a Library item."""
    credential = _script_credential(credential)
    source, truncated = await _source_text(req.source)
    brief = req.brief()
    _require_affordable(credential, brief, len(source))
    if _generation_slots.locked():
        raise HTTPException(
            status_code=429,
            detail="Voqora is already writing podcast scripts. Try again shortly.",
        )
    async with _generation_slots:
        try:
            generated = await PodcastGenerator.generate(credential, brief, source)
        except (LLMError, PodcastGenerationError) as error:
            raise _generation_http_error(error) from error
        except Exception as error:
            log.error(
                "podcast.script_failed",
                extra={
                    "failure_code": "podcast_script_failed",
                    "error_type": type(error).__name__,
                },
            )
            raise HTTPException(
                status_code=500, detail="Script writing failed. Please try again."
            ) from error
    return ScriptResponse(
        script=generated.script,
        used_notes=generated.used_notes,
        repaired=generated.repaired,
        source_truncated=truncated,
        estimated_audio_seconds=podcast_library.estimated_audio_seconds(
            generated.script
        ),
        llm_provider=credential.provider,
        llm_model=credential.resolved_model,
    )


def _generation_http_error(error: Exception) -> HTTPException:
    if isinstance(error, LLMConfigError):
        return HTTPException(status_code=400, detail=error.user_message)
    if isinstance(error, PodcastGenerationError):
        return HTTPException(
            status_code=502,
            detail=(
                "The AI provider did not return a usable script. "
                "Try again or choose another model."
            ),
        )
    if isinstance(error, LLMError) and not error.retryable:
        return HTTPException(status_code=502, detail=error.user_message)
    return HTTPException(
        status_code=503,
        detail="The AI provider is temporarily unavailable. Try again later.",
    )


def _require_render_capacity(script: PodcastScript) -> float:
    seconds = podcast_library.estimated_audio_seconds(script)
    if seconds > settings.MAX_AUDIOBOOK_DURATION_SECONDS:
        raise HTTPException(
            status_code=413,
            detail="This podcast would exceed Voqora's 24-hour narration limit.",
        )
    try:
        ensure_storage_capacity(
            len(podcast_library.transcript_text(script).encode("utf-8")),
            seconds,
            library_root=AudiobookStore.root_dir(),
            reserved_bytes=_pending_audio_bytes(exclude=None),
        )
    except ImportLimitError as exc:
        raise HTTPException(status_code=413, detail=str(exc)) from exc
    return seconds


async def _create_item(script: PodcastScript, title: str) -> str:
    try:
        return await asyncio.get_running_loop().run_in_executor(
            None, podcast_library.create_item, script, title
        )
    except Exception as exc:
        log.warning(
            "podcast.create_failed",
            extra={"failure_code": "podcast_create_failed"},
        )
        raise HTTPException(
            status_code=500, detail="Voqora could not save this podcast. Try again."
        ) from exc


@router.post("/podcast/render", response_model=RenderResponse)
async def render_podcast(req: RenderRequest):
    """Create a podcast Library item and narrate it turn by turn."""
    title = req.title or req.script.title
    script = req.script.model_copy(update={"title": title})
    seconds = _require_render_capacity(script)
    book_id = await _create_item(script, title)
    try:
        accepted = await AudiobookService.start(book_id, None, uses_llm_cleanup=False)
    except Exception:
        AudiobookStore.delete_book(book_id)
        raise
    if not accepted:
        AudiobookStore.delete_book(book_id)
        raise HTTPException(
            status_code=409, detail="This podcast is already processing."
        )
    _spawn_bg(_render_cover_task(book_id, False))
    log.info(
        "podcast.render_queued",
        extra={
            "book_id": book_id,
            "turns": len(script.turns),
            "speakers": len(script.speakers),
        },
    )
    return RenderResponse(
        status="queued",
        book_id=book_id,
        kind=PODCAST_KIND,
        title=title,
        turn_count=len(script.turns),
        speakers=script.speakers,
        estimated_audio_seconds=seconds,
    )


@router.get("/podcast/{book_id}/script", response_model=PodcastScript)
def get_podcast_script(book_id: str):
    """Return the script a podcast item was rendered from."""
    _validate_book_id(book_id)
    meta = AudiobookStore.read_meta(book_id)
    if not podcast_library.is_podcast(meta):
        raise HTTPException(status_code=404, detail="Podcast not found.")
    script = podcast_library.load_script(book_id)
    if script is None:
        raise HTTPException(status_code=404, detail="Podcast script not found.")
    return script
