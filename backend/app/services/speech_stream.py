from __future__ import annotations

from collections.abc import AsyncGenerator, AsyncIterator

import numpy as np
from starlette.responses import StreamingResponse
from starlette.types import Receive, Scope, Send

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


class SpeechSamples:
    """Interactive speech samples that own the preemption lock until closed.

    The lock is released exactly once: when the samples run out, fail, or are
    closed, including when they are closed before the first chunk is pulled.
    """

    def __init__(self, samples: AsyncGenerator[np.ndarray, None]) -> None:
        self._samples = samples
        self._holds_lock = True
        self._chunks = self._stream()

    def __aiter__(self) -> SpeechSamples:
        return self

    async def __anext__(self) -> np.ndarray:
        return await self._chunks.__anext__()

    def release(self) -> None:
        if self._holds_lock:
            self._holds_lock = False
            interactive_tts_lock.release()

    async def aclose(self) -> None:
        self.release()
        await self._chunks.aclose()

    async def _stream(self) -> AsyncGenerator[np.ndarray, None]:
        try:
            async for chunk in self._samples:
                yield chunk
        except Exception:
            log.error(
                "speak.stream_error",
                extra={"failure_code": "stream_generation_failed"},
                exc_info=True,
            )
        finally:
            self.release()
            await self._samples.aclose()


class SpeechStreamResponse(StreamingResponse):
    """Streams encoded speech and closes its samples however the response ends."""

    def __init__(
        self,
        samples: SpeechSamples,
        content: AsyncIterator[bytes],
        media_type: str,
    ) -> None:
        super().__init__(content, media_type=media_type)
        self._samples = samples

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        try:
            await super().__call__(scope, receive, send)
        finally:
            await self._samples.aclose()


async def open_speech_samples(
    text: str,
    voice: str,
    speed: float,
    lang: str | None = None,
    *,
    pause_scale: float = 1.0,
    book_id: str | None = None,
) -> SpeechSamples:
    """Start interactive speech under the preemption lock.

    `voice` may be a built-in voice, a blend id or a Supertonic voice. The
    global pronunciation dictionary applies, plus the book's own rules when
    `book_id` names one.
    """
    engine = EngineManager.engine_for_voice(voice)
    EngineManager.require_installed(engine)
    await interactive_tts_lock.acquire()
    try:
        await EngineManager.ensure_loaded(engine)
        EngineManager.touch(engine)
        samples = EngineManager.generate(
            text, voice, speed, lang, pause_scale=pause_scale, book_id=book_id
        )
    except BaseException:
        interactive_tts_lock.release()
        raise
    return SpeechSamples(samples)
