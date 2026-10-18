from __future__ import annotations

from collections.abc import AsyncGenerator, AsyncIterator

import numpy as np

from app.core.logging import get_logger
from app.services.engine_manager import EngineManager
from app.services.text_normalizer import strip_markdown_for_narration
from app.services.tts import interactive_tts_lock

log = get_logger(__name__)

MAX_SPEECH_CHARS = 50_000
MIN_ENGINE_SPEED = 0.5
MAX_ENGINE_SPEED = 2.0


def speakable_text(value: str) -> str:
    value = strip_markdown_for_narration(value.strip())
    if not value:
        raise ValueError("text must not be blank")
    return value


def clamp_engine_speed(speed: float) -> float:
    return min(max(speed, MIN_ENGINE_SPEED), MAX_ENGINE_SPEED)


async def open_speech_samples(
    text: str,
    voice: str,
    speed: float,
    lang: str | None = None,
    *,
    pause_scale: float = 1.0,
) -> AsyncIterator[np.ndarray]:
    """Start interactive speech under the preemption lock.

    `voice` may be a built-in voice or a blend id. The global pronunciation
    dictionary applies, as it does everywhere outside an audiobook.
    """
    await interactive_tts_lock.acquire()
    try:
        await EngineManager.ensure_loaded()
        EngineManager.touch()
        samples = EngineManager.generate(
            text, voice, speed, lang, pause_scale=pause_scale
        )
    except BaseException:
        interactive_tts_lock.release()
        raise
    return _release_lock_when_done(samples)


async def _release_lock_when_done(
    samples: AsyncIterator[np.ndarray],
) -> AsyncGenerator[np.ndarray, None]:
    try:
        async for chunk in samples:
            yield chunk
    except Exception:
        log.error(
            "speak.stream_error",
            extra={"failure_code": "stream_generation_failed"},
            exc_info=True,
        )
    finally:
        if interactive_tts_lock.locked():
            interactive_tts_lock.release()
