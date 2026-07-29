"""TTS HTTP surface — /health, /engine, /prewarm, /speak, /debug/state.

Split out of the former `endpoints.py` monolith in HARD-031. The audiobook
surface lives in `app/api/audiobook.py`.
"""

import os
import time

from fastapi import APIRouter, BackgroundTasks, Body, HTTPException, Response
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from app.core.config import settings
from app.core.logging import get_logger
from app.services.audio import AudioService
from app.services.engine_manager import EngineManager
from app.services.tts import TTSEngine, interactive_tts_lock

router = APIRouter()
log = get_logger(__name__)


class SpeakRequest(BaseModel):
    text: str
    voice: str = "af_bella"
    speed: float = 1.0
    volume: float = 1.0
    lang: str = "en-us"


class PrewarmRequest(BaseModel):
    text: str | None = None
    voice: str | None = None
    speed: float | None = None


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
    """Return current engine state. Only Kokoro is supported.

    Kept for backward compat with older Swift clients; deletion is tracked
    by HARD-032.
    """
    if req.engine != "kokoro":
        raise HTTPException(status_code=400, detail=f"Unknown engine: {req.engine}")
    return EngineManager.state()


async def _do_prewarm(req: PrewarmRequest | None) -> None:
    """Background task: ensure model is loaded, then optionally fill lookahead cache."""
    await EngineManager.ensure_loaded()
    if req and req.text and req.voice and req.speed is not None:
        await EngineManager.prewarm_with_lookahead(req.text, req.voice, req.speed)


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


async def _guarded_wav_stream(wav_generator, lock_holder=None):
    """Wrap WAV streaming with error handling and release the preemption lock
    when the stream finishes (so audiobook generation can resume)."""
    try:
        async for chunk in wav_generator:
            yield chunk
    except Exception as e:
        log.error("speak.stream_error", extra={"error": str(e)})
    finally:
        if lock_holder is not None and lock_holder.locked():
            lock_holder.release()


@router.post("/speak")
async def speak(req: SpeakRequest):
    try:
        # Acquire preemption lock so any in-flight audiobook TTS phase pauses
        # at its next inter-page checkpoint until this stream finishes.
        await interactive_tts_lock.acquire()

        # If the model was idle-unloaded, reload it now (~1.3 s warm-up).
        await EngineManager.ensure_loaded()
        EngineManager.touch()

        raw_samples_generator = EngineManager.generate(req.text, req.voice, req.speed)
        wav_chunk_generator = AudioService.stream_samples_to_wav(
            raw_samples_generator, req.volume
        )
        guarded_stream = _guarded_wav_stream(
            wav_chunk_generator, lock_holder=interactive_tts_lock
        )

        return StreamingResponse(
            guarded_stream,
            media_type="audio/wav",
        )

    except Exception as e:
        # If we acquired the lock but bombed before returning the stream, release.
        if interactive_tts_lock.locked():
            interactive_tts_lock.release()
        log.error("speak.request_error", extra={"error": str(e)})
        return Response(status_code=500, content=str(e))


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
