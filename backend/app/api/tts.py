"""TTS HTTP surface — /health, /engine, /prewarm, /speak, /debug/state.

Split out of the former `endpoints.py` monolith in HARD-031. The audiobook
surface lives in `app/api/audiobook.py`.
"""

import os
import time

from fastapi import APIRouter, BackgroundTasks, Body, HTTPException, Response
from pydantic import BaseModel, Field, field_validator

from app.core.config import settings
from app.core.logging import get_logger
from app.services.audio import AudioService
from app.services.engine_errors import (
    EngineBusyError,
    EngineInstallError,
    EngineNotInstalledError,
    UnknownEngineError,
)
from app.services.engine_manager import EngineManager
from app.services.languages import DEFAULT_VOICE, LANGUAGES
from app.services.pronunciation import is_book_scope
from app.services.speech_stream import (
    MAX_ENGINE_SPEED,
    MAX_SPEECH_CHARS,
    MIN_ENGINE_SPEED,
    SpeechStreamResponse,
    open_speech_samples,
)
from app.services.text_normalizer import strip_markdown_for_narration
from app.services.tts import MAX_PAUSE_SCALE, MIN_PAUSE_SCALE, TTSEngine
from app.services.voices import is_known_voice

router = APIRouter()
log = get_logger(__name__)


_LANGUAGE_CODES = frozenset(language["code"] for language in LANGUAGES)
_MAX_VOICE_ID_CHARS = 64
_MAX_BOOK_ID_CHARS = 32


def _require_known_voice(value: str | None) -> str | None:
    if value is not None and not is_known_voice(value):
        raise ValueError(f"unknown voice: {value}")
    return value


class SpeakRequest(BaseModel):
    # Keep one request bounded. Long documents belong in the audiobook flow,
    # where progress, cancellation, and recovery are explicit.
    text: str = Field(min_length=1, max_length=MAX_SPEECH_CHARS)
    voice: str = Field(default=DEFAULT_VOICE, max_length=_MAX_VOICE_ID_CHARS)
    speed: float = Field(default=1.0, ge=MIN_ENGINE_SPEED, le=MAX_ENGINE_SPEED)
    volume: float = Field(default=1.0, ge=0.0, le=1.5)
    lang: str | None = None
    pause_scale: float = Field(default=1.0, ge=MIN_PAUSE_SCALE, le=MAX_PAUSE_SCALE)
    book_id: str | None = Field(default=None, max_length=_MAX_BOOK_ID_CHARS)

    @field_validator("voice")
    @classmethod
    def require_known_voice(cls, value: str) -> str:
        return _require_known_voice(value)

    @field_validator("book_id")
    @classmethod
    def require_book_id(cls, value: str | None) -> str | None:
        if value is not None and not is_book_scope(value):
            raise ValueError("book_id must be a book id")
        return value

    @field_validator("lang")
    @classmethod
    def require_known_lang(cls, value: str | None) -> str | None:
        if value is not None and value not in _LANGUAGE_CODES:
            raise ValueError(f"unsupported language: {value}")
        return value

    @field_validator("text")
    @classmethod
    def require_meaningful_text(cls, value: str) -> str:
        # Normalize at the API boundary, not in the client. The Swift app has
        # its own lighter-weight strip, but the backend must not depend on a
        # client having run it -- /speak is the one endpoint that takes
        # arbitrary user text (a clipboard selection, often lifted straight out
        # of a README) and hands it to the phonemizer. Without this, anything
        # the client missed gets vocalized as "hash", "asterisk", "pipe".
        value = strip_markdown_for_narration(value.strip())
        if not value:
            raise ValueError("text must not be blank")
        return value


class PrewarmRequest(BaseModel):
    # Same bound as SpeakRequest.text — unbounded here would make this an
    # easier DoS amplifier than /speak for the same cost.
    text: str | None = Field(default=None, max_length=MAX_SPEECH_CHARS)

    @field_validator("text")
    @classmethod
    def normalize_text(cls, value: str | None) -> str | None:
        # Must match SpeakRequest's normalization exactly: the lookahead cache
        # is keyed on the first *segment* of the text, so if prewarm cached a
        # segment built from un-stripped text, the /speak that follows would
        # compute a different key and miss the cache entirely -- silently
        # wasting the warm-up this endpoint exists to provide.
        if value is None:
            return None
        return strip_markdown_for_narration(value)

    voice: str | None = Field(default=None, max_length=_MAX_VOICE_ID_CHARS)
    speed: float | None = Field(default=None, ge=MIN_ENGINE_SPEED, le=MAX_ENGINE_SPEED)
    pause_scale: float = Field(default=1.0, ge=MIN_PAUSE_SCALE, le=MAX_PAUSE_SCALE)

    @field_validator("voice")
    @classmethod
    def require_known_voice(cls, value: str | None) -> str | None:
        return _require_known_voice(value)


class EngineRequest(BaseModel):
    engine: str
    model: str | None = None


@router.get("/health")
def health_check():
    """
    Swift polls this to know when the backend is ready.

    Always returns HTTP 200 while the server process is running — even when the
    ONNX model has been idle-unloaded. Returning 503 here would cause the Swift
    heartbeat to kill and restart the entire process unnecessarily.

    The `loaded` field lets the UI distinguish "fully ready" from "cold standby"
    (model will auto-reload on the next /speak request).
    """
    loaded = EngineManager.is_loaded()
    return {"status": "ready" if loaded else "cold", "loaded": loaded}


@router.get("/engine")
def get_engine():
    """Return current active engine, model, and available voices."""
    return EngineManager.state()


@router.post("/engine")
async def set_engine(req: EngineRequest):
    """Return current engine state. Kokoro stays the default engine.

    A request names an engine only to check it is usable; each speech request
    picks its engine through its voice id.
    """
    try:
        EngineManager.require_installed(req.engine)
    except UnknownEngineError:
        raise HTTPException(status_code=400, detail=f"Unknown engine: {req.engine}")
    except EngineNotInstalledError as error:
        raise HTTPException(status_code=409, detail=str(error))
    return EngineManager.state()


@router.post("/engine/{engine_id}/install", status_code=202)
async def install_engine(engine_id: str):
    """Start downloading an optional engine. Poll GET /engine for progress."""
    try:
        return EngineManager.install(engine_id)
    except UnknownEngineError:
        raise HTTPException(status_code=404, detail=f"Unknown engine: {engine_id}")


@router.delete("/engine/{engine_id}")
async def uninstall_engine(engine_id: str):
    try:
        return EngineManager.uninstall(engine_id)
    except UnknownEngineError:
        raise HTTPException(status_code=404, detail=f"Unknown engine: {engine_id}")
    except EngineBusyError as error:
        raise HTTPException(status_code=409, detail=str(error))
    except EngineInstallError as error:
        raise HTTPException(status_code=400, detail=str(error))


async def _do_prewarm(req: PrewarmRequest | None) -> None:
    """Background task: ensure model is loaded, then optionally fill lookahead cache."""
    engine = EngineManager.engine_for_voice(req.voice) if req and req.voice else None
    try:
        await EngineManager.ensure_loaded(engine or "kokoro")
    except EngineNotInstalledError:
        return
    if req and req.text and req.voice and req.speed is not None:
        await EngineManager.prewarm_with_lookahead(
            req.text, req.voice, req.speed, pause_scale=req.pause_scale
        )


@router.post("/prewarm")
async def prewarm(
    background_tasks: BackgroundTasks,
    req: PrewarmRequest | None = Body(default=None),
):
    """
    Fire-and-forget warm-up: called by the Swift client when it detects a clipboard
    change or the app gains focus, before the user has pressed the hotkey.

    Returns immediately. When a JSON body with {text, voice, speed} is provided,
    the backend also pre-runs inference on the first text segment and caches the
    audio so /speak can stream it instantly (cache-hit TTFA <20ms).
    """
    background_tasks.add_task(_do_prewarm, req)
    return {"status": "warming"}


@router.post("/speak")
async def speak(req: SpeakRequest):
    try:
        # Hold the preemption lock so any in-flight audiobook TTS phase pauses
        # at its next inter-page checkpoint until this stream finishes.
        samples = await open_speech_samples(
            req.text,
            req.voice,
            req.speed,
            req.lang,
            pause_scale=req.pause_scale,
            book_id=req.book_id,
        )
    except EngineNotInstalledError as error:
        raise HTTPException(status_code=409, detail=str(error))
    except Exception:
        log.error(
            "speak.request_error",
            extra={
                "failure_code": "speech_request_failed",
                "voice": req.voice,
                "speed": req.speed,
                "text_len": len(req.text),
            },
            exc_info=True,
        )
        # Provider/model exception text can include local paths or request
        # content. The client needs a stable recovery message, not internals.
        return Response(
            status_code=500,
            content="Speech generation failed. Check that the voice model is available and try again.",
        )
    return SpeechStreamResponse(
        samples,
        AudioService.stream_samples_to_wav(samples, req.volume),
        media_type="audio/wav",
    )


@router.get("/debug/state")
def debug_state():
    """Optional dev/debug surface. Returns runtime knobs that are otherwise
    only observable via logs. Gated by `DEBUG_ENDPOINTS` so production
    builds don't expose it. See HARD-070.

    Includes process RSS (via `psutil` if available — already a runtime
    dep) so we can quantify the idle-unload savings.
    """
    if not settings.DEBUG_ENDPOINTS:
        raise HTTPException(status_code=404, detail="Debug endpoints disabled.")

    rss_mb: float | None = None
    try:
        import psutil

        rss_mb = round(psutil.Process(os.getpid()).memory_info().rss / 1024 / 1024, 1)
    except Exception:  # psutil failure is non-fatal here
        rss_mb = None

    now = time.monotonic()
    last_request = TTSEngine._last_request_time
    idle_seconds = round(now - last_request, 1) if last_request else None

    return {
        "model_loaded": TTSEngine.is_loaded(),
        "is_initializing": TTSEngine._is_initializing,
        "last_request_monotonic": last_request,
        "idle_seconds": idle_seconds,
        "rss_mb": rss_mb,
        "lookahead_cache_size": len(TTSEngine._lookahead_cache),
    }
