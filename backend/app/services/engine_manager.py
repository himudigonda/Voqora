"""EngineManager — Kokoro-only TTS dispatch layer.

Single point of dispatch for inference. Wraps TTSEngine (Kokoro) behind a
stable API so endpoints don't need to import TTSEngine directly.
"""

from collections.abc import AsyncGenerator

import numpy as np

from app.services.languages import (
    DEFAULT_VOICE,
    VOICES,
    language_catalog,
    voice_catalog,
)
from app.services.pronunciation import pronunciations
from app.services.tts import TTSEngine
from app.services.voice_blends import voice_blends
from app.services.voices import VoiceSpec, voice_spec

KOKORO_VOICES = [voice["id"] for voice in VOICES]
KOKORO_DEFAULT_VOICE = DEFAULT_VOICE


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
            "voice_catalog": voice_catalog(),
            "languages": language_catalog(),
            "blends": [blend.to_dict() for blend in voice_blends.list()],
        }

    @classmethod
    async def ensure_loaded(cls) -> None:
        await TTSEngine.ensure_loaded()

    @classmethod
    def touch(cls) -> None:
        TTSEngine.touch()

    @classmethod
    async def generate(
        cls,
        text: str,
        voice: str | VoiceSpec,
        speed: float,
        lang: str | None = None,
        failed_segments: list[str] | None = None,
        *,
        pause_scale: float = 1.0,
        book_id: str | None = None,
    ) -> AsyncGenerator[np.ndarray, None]:
        spec = voice_spec(voice)
        async for chunk in TTSEngine.generate(
            text,
            spec,
            speed,
            lang or spec.lang,
            failed_segments,
            pause_scale=pause_scale,
            pronunciation=pronunciations.rules_for(book_id),
        ):
            yield chunk

    @classmethod
    def split_segments(cls, text: str) -> list[str]:
        return TTSEngine._split_segments(text)

    @classmethod
    async def prewarm_with_lookahead(
        cls, text: str, voice: str, speed: float, *, pause_scale: float = 1.0
    ) -> None:
        spec = voice_spec(voice)
        await TTSEngine.prewarm_with_lookahead(
            text,
            spec,
            speed,
            spec.lang,
            pause_scale=pause_scale,
            pronunciation=pronunciations.rules_for(None),
        )

    @classmethod
    def is_loaded(cls) -> bool:
        return TTSEngine.is_loaded()
