"""EngineManager — TTS dispatch layer.

Single point of dispatch for inference. Routes each request to Kokoro or
Supertonic by engine id, so endpoints never import an engine directly.
"""

from collections.abc import AsyncGenerator

import numpy as np

from app.services import supertonic_catalog as catalog
from app.services.engine_errors import (
    EngineBusyError,
    EngineInstallError,
    EngineNotInstalledError,
    UnknownEngineError,
)
from app.services.languages import (
    DEFAULT_VOICE,
    VOICES,
    language_catalog,
    voice_catalog,
)
from app.services.pronunciation import pronunciations
from app.services.supertonic_engine import SupertonicEngine
from app.services.supertonic_installer import SupertonicInstaller
from app.services.tts import TTSEngine
from app.services.voice_blends import voice_blends
from app.services.voices import KOKORO_ENGINE as KOKORO
from app.services.voices import VoiceSpec, voice_spec

SUPERTONIC = catalog.ENGINE_ID
ENGINE_IDS = (KOKORO, SUPERTONIC)
KOKORO_VOICES = [voice["id"] for voice in VOICES]
KOKORO_DEFAULT_VOICE = DEFAULT_VOICE
KOKORO_LICENSE = "Apache 2.0"
KOKORO_LANGUAGES = [language["code"] for language in language_catalog()]


class EngineManager:
    @classmethod
    def require_known(cls, engine: str) -> str:
        if engine not in ENGINE_IDS:
            raise UnknownEngineError(engine)
        return engine

    @classmethod
    def is_installed(cls, engine: str) -> bool:
        cls.require_known(engine)
        return engine == KOKORO or SupertonicInstaller.is_installed()

    @classmethod
    def require_installed(cls, engine: str) -> str:
        if not cls.is_installed(engine):
            raise EngineNotInstalledError(engine)
        return engine

    @classmethod
    def engine_for_voice(cls, voice: str | VoiceSpec) -> str:
        return voice_spec(voice).engine

    @classmethod
    def require_voice_installed(cls, voice: str | VoiceSpec) -> None:
        cls.require_installed(cls.engine_for_voice(voice))

    @classmethod
    def voices(cls, engine: str = KOKORO) -> list[str]:
        cls.require_known(engine)
        if engine == SUPERTONIC:
            return [voice["id"] for voice in catalog.VOICES]
        return KOKORO_VOICES

    @classmethod
    def default_voice(cls, engine: str = KOKORO) -> str:
        cls.require_known(engine)
        return catalog.DEFAULT_VOICE if engine == SUPERTONIC else KOKORO_DEFAULT_VOICE

    @classmethod
    def engines(cls) -> list[dict]:
        supertonic = SupertonicInstaller.status()
        return [
            {
                "id": KOKORO,
                "name": "Kokoro",
                "installed": True,
                "downloading": False,
                "progress": 1.0,
                "size_bytes": 0,
                "license": KOKORO_LICENSE,
                "languages": KOKORO_LANGUAGES,
                "voices": voice_catalog(),
                "error": None,
            },
            {
                "id": SUPERTONIC,
                "name": catalog.ENGINE_NAME,
                "installed": supertonic["installed"],
                "downloading": supertonic["downloading"],
                "progress": supertonic["progress"],
                "size_bytes": catalog.MODEL_SIZE_BYTES,
                "license": catalog.LICENSE_SUMMARY,
                "languages": list(catalog.LANGUAGES),
                "voices": [dict(voice) for voice in catalog.VOICES],
                "error": supertonic["error"],
            },
        ]

    @classmethod
    def state(cls) -> dict:
        return {
            "engine": KOKORO,
            "model": "",
            "voices": KOKORO_VOICES,
            "voice_catalog": voice_catalog(),
            "languages": language_catalog(),
            "blends": [blend.to_dict() for blend in voice_blends.list()],
            "engines": cls.engines(),
        }

    @classmethod
    def install(cls, engine: str) -> dict:
        cls.require_known(engine)
        if engine == SUPERTONIC:
            SupertonicInstaller.start()
        return cls.engine_info(engine)

    @classmethod
    def uninstall(cls, engine: str) -> dict:
        cls.require_known(engine)
        if engine == KOKORO:
            raise EngineInstallError("Kokoro is built in and cannot be removed.")
        if engine == SUPERTONIC:
            if SupertonicEngine.is_busy():
                raise EngineBusyError(
                    "Supertonic is loading or speaking. Try again when it finishes."
                )
            SupertonicInstaller.uninstall()
            SupertonicEngine.unload()
        return cls.engine_info(engine)

    @classmethod
    def engine_info(cls, engine: str) -> dict:
        cls.require_known(engine)
        return next(info for info in cls.engines() if info["id"] == engine)

    @classmethod
    async def ensure_loaded(cls, engine: str = KOKORO) -> None:
        cls.require_installed(engine)
        if engine == SUPERTONIC:
            await SupertonicEngine.ensure_loaded()
        else:
            await TTSEngine.ensure_loaded()

    @classmethod
    def touch(cls, engine: str = KOKORO) -> None:
        if engine == SUPERTONIC:
            SupertonicEngine.touch()
        else:
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
        rules = pronunciations.rules_for(book_id)
        if spec.engine == SUPERTONIC:
            chunks = SupertonicEngine.generate(
                text,
                spec,
                speed,
                lang,
                failed_segments,
                pause_scale=pause_scale,
                pronunciation=rules,
            )
        else:
            chunks = TTSEngine.generate(
                text,
                spec,
                speed,
                lang or spec.lang,
                failed_segments,
                pause_scale=pause_scale,
                pronunciation=rules,
            )
        async for chunk in chunks:
            yield chunk

    @classmethod
    def detected_language(cls, voice: str | VoiceSpec, text: str) -> str | None:
        if voice_spec(voice).engine != SUPERTONIC:
            return None
        return catalog.detect_language(text)

    @classmethod
    def split_segments(cls, text: str) -> list[str]:
        return TTSEngine._split_segments(text)

    @classmethod
    async def prewarm_with_lookahead(
        cls, text: str, voice: str, speed: float, *, pause_scale: float = 1.0
    ) -> None:
        spec = voice_spec(voice)
        if spec.engine == SUPERTONIC:
            return
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
