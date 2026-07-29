"""EngineManager — Kokoro-only TTS dispatch layer.

Single point of dispatch for inference. Wraps TTSEngine (Kokoro) behind a
stable API so endpoints don't need to import TTSEngine directly.
"""

from collections.abc import AsyncGenerator

import numpy as np

from app.services.languages import (
    DEFAULT_VOICE,
    VOICE_IDS,
    is_valid_voice,
    language_catalog,
    voice_catalog,
)
from app.services.tts import TTSEngine

# Compatibility aliases for existing callers and stored audiobook metadata.
KOKORO_VOICES = VOICE_IDS
KOKORO_DEFAULT_VOICE = DEFAULT_VOICE


class EngineManager:
    @classmethod
    def voices(cls) -> list[str]:
        return VOICE_IDS

    @classmethod
    def default_voice(cls) -> str:
        return DEFAULT_VOICE

    @classmethod
    def is_valid_voice(cls, voice: str) -> bool:
        return is_valid_voice(voice)

    @classmethod
    def state(cls) -> dict:
        return {
            "engine": "kokoro",
            "model": "",
            "voices": VOICE_IDS,
            "voice_catalog": voice_catalog(),
            "languages": language_catalog(),
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
    async def generate_with_timing(
        cls, text: str, voice: str, speed: float
    ) -> AsyncGenerator[dict, None]:
        """Audiobook-only sibling of generate() — mirrors it exactly, passing
        through to TTSEngine.generate_with_timing(). See that method's
        docstring for the yielded dict shape."""
        async for item in TTSEngine.generate_with_timing(text, voice, speed):
            yield item

    @classmethod
    async def prewarm_with_lookahead(cls, text: str, voice: str, speed: float) -> None:
        await TTSEngine.prewarm_with_lookahead(text, voice, speed)

    @classmethod
    def is_loaded(cls) -> bool:
        return TTSEngine.is_loaded()
