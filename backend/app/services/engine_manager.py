"""EngineManager — Kokoro-only TTS dispatch layer.

Single point of dispatch for inference. Wraps TTSEngine (Kokoro) behind a
stable API so endpoints don't need to import TTSEngine directly.
"""

from collections.abc import AsyncGenerator

import numpy as np

from app.services.tts import TTSEngine

KOKORO_VOICES = [
    "af_bella",
    "af_sarah",
    "am_adam",
    "am_michael",
    "bf_emma",
    "bf_isabella",
    "bm_george",
    "bm_lewis",
]
KOKORO_DEFAULT_VOICE = "af_bella"


class EngineManager:
    @classmethod
    def voices(cls) -> list[str]:
        return KOKORO_VOICES

    @classmethod
    def default_voice(cls) -> str:
        return KOKORO_DEFAULT_VOICE

    @classmethod
    def state(cls) -> dict:
        return {
            "engine": "kokoro",
            "model": "",
            "voices": KOKORO_VOICES,
        }

    @classmethod
    async def ensure_loaded(cls) -> None:
        await TTSEngine.ensure_loaded()

    @classmethod
    def touch(cls) -> None:
        TTSEngine.touch()

    @classmethod
    async def generate(
        cls, text: str, voice: str, speed: float
    ) -> AsyncGenerator[np.ndarray, None]:
        async for chunk in TTSEngine.generate(text, voice, speed):
            yield chunk

    @classmethod
    async def prewarm_with_lookahead(cls, text: str, voice: str, speed: float) -> None:
        await TTSEngine.prewarm_with_lookahead(text, voice, speed)

    @classmethod
    def is_loaded(cls) -> bool:
        return TTSEngine.is_loaded()
