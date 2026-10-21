from __future__ import annotations

import asyncio
import concurrent.futures
import os
import time
from collections import OrderedDict
from collections.abc import AsyncGenerator
from typing import Any

import numpy as np
from supertonic import TTS
from supertonic.config import MAX_SPEED, MIN_SPEED

from app.core.config import settings
from app.core.logging import get_logger
from app.services.audio import AudioService, resample
from app.services.engine_errors import EngineNotInstalledError
from app.services.pronunciation import EMPTY_RULES, PronunciationRules
from app.services.supertonic_catalog import (
    ENGINE_ID,
    MODEL_NAME,
    resolve_language,
    style_name,
)
from app.services.supertonic_installer import SupertonicInstaller
from app.services.tts import TTSEngine
from app.services.voices import VoiceSpec, voice_spec

log = get_logger(__name__)

WARMUP_TEXT = "Hello."
WARMUP_LANGUAGE = "en"
CHUNK_GAP_SECONDS = 0.1


def clamp_speed(speed: float) -> float:
    return min(max(speed, MIN_SPEED), MAX_SPEED)


class SupertonicEngine:
    _model: Any = None
    _executor: concurrent.futures.ThreadPoolExecutor | None = None
    _is_initializing: bool = False
    _load_event: asyncio.Event = asyncio.Event()
    _last_request_time: float = 0.0
    _IDLE_TIMEOUT: float = 300.0
    _styles: OrderedDict[str, Any] = OrderedDict()
    _MAX_STYLES: int = 10
    _active_generations: int = 0

    @classmethod
    def touch(cls) -> None:
        cls._last_request_time = time.monotonic()

    @classmethod
    def is_loaded(cls) -> bool:
        return cls._model is not None

    @classmethod
    def is_busy(cls) -> bool:
        return cls._is_initializing or cls._active_generations > 0

    @classmethod
    async def ensure_loaded(cls) -> None:
        if cls._model is not None:
            return
        if cls._is_initializing:
            await cls._load_event.wait()
            return
        cls._is_initializing = True
        cls._load_event.clear()
        try:
            log.info("supertonic.cold_start")
            await asyncio.get_running_loop().run_in_executor(None, cls.initialize)
        finally:
            cls._is_initializing = False
            cls._load_event.set()

    @classmethod
    def initialize(cls) -> None:
        if not SupertonicInstaller.is_installed():
            raise EngineNotInstalledError(ENGINE_ID)
        if cls._executor is None:
            cls._executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        if cls._model is None:
            try:
                model = TTS(
                    model=MODEL_NAME,
                    model_dir=SupertonicInstaller.model_dir(),
                    auto_download=False,
                    intra_op_num_threads=min(4, os.cpu_count() or 2),
                )
                model.synthesize(
                    WARMUP_TEXT,
                    model.get_voice_style("M1"),
                    lang=WARMUP_LANGUAGE,
                )
            except Exception:
                log.error(
                    "supertonic.fatal_error",
                    extra={"failure_code": "supertonic_initialization_failed"},
                    exc_info=True,
                )
                raise
            cls._model = model
            log.info("supertonic.ready")
        cls.touch()

    @classmethod
    def unload(cls) -> None:
        if cls._model is None and cls._executor is None:
            return
        cls._model = None
        if cls._executor is not None:
            cls._executor.shutdown(wait=False, cancel_futures=True)
            cls._executor = None
        cls._styles.clear()
        log.info("supertonic.unloaded")

    @classmethod
    async def idle_watcher(cls) -> None:
        while True:
            await asyncio.sleep(60)
            if cls._model is None or cls.is_busy():
                continue
            if cls._last_request_time == 0:
                continue
            if time.monotonic() - cls._last_request_time > cls._IDLE_TIMEOUT:
                cls.unload()

    @classmethod
    def _style(cls, model: Any, voice_id: str) -> Any:
        cached = cls._styles.get(voice_id)
        if cached is not None:
            cls._styles.move_to_end(voice_id)
            return cached
        style = model.get_voice_style(style_name(voice_id))
        cls._styles[voice_id] = style
        while len(cls._styles) > cls._MAX_STYLES:
            cls._styles.popitem(last=False)
        return style

    @classmethod
    def _synthesize(
        cls, model: Any, text: str, voice_id: str, speed: float, language: str
    ) -> np.ndarray | None:
        processor = model.model.text_processor
        _, unsupported = processor.validate_text(text)
        if unsupported:
            text = "".join(ch for ch in text if ch not in unsupported).strip()
        if not text:
            return None
        wav, _ = model.synthesize(
            text,
            cls._style(model, voice_id),
            speed=clamp_speed(speed),
            lang=language,
            silence_duration=CHUNK_GAP_SECONDS,
        )
        audio = np.asarray(wav, dtype=np.float32).reshape(-1)
        return resample(audio, model.sample_rate, settings.AUDIO_SAMPLE_RATE)

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
        pronunciation: PronunciationRules | None = None,
    ) -> AsyncGenerator[np.ndarray, None]:
        model = cls._model
        executor = cls._executor
        if not model or not executor:
            raise RuntimeError("Supertonic is not loaded. Call ensure_loaded() first.")

        segments = TTSEngine._split_segments(text)
        if not segments:
            return

        spec = voice_spec(voice)
        language = resolve_language(lang, text)
        effective_speed = clamp_speed(speed)
        rules = pronunciation or EMPTY_RULES
        loop = asyncio.get_running_loop()

        cls._active_generations += 1
        try:
            for segment in segments:
                cls.touch()
                stripped = segment.strip()
                spoken, _ = rules.speakable(stripped)
                if spoken is None:
                    continue
                failed = False
                try:
                    audio = await loop.run_in_executor(
                        executor,
                        cls._synthesize,
                        model,
                        spoken,
                        spec.id,
                        effective_speed,
                        language,
                    )
                except Exception as error:
                    log.warning(
                        "supertonic.segment_error",
                        extra={
                            "segment_chars": len(segment),
                            "error_type": type(error).__name__,
                        },
                        exc_info=True,
                    )
                    audio = None
                    failed = True
                if audio is None:
                    if failed and failed_segments is not None:
                        failed_segments.append(stripped)
                    continue
                silence = AudioService.get_silence(
                    TTSEngine._pause_seconds(stripped, effective_speed, pause_scale)
                )
                yield np.concatenate([audio, silence])
        finally:
            cls._active_generations -= 1
