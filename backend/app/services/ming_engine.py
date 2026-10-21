from __future__ import annotations

import asyncio
import hashlib
import itertools
import json
import os
import tempfile
import time
from collections.abc import AsyncGenerator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import soundfile as sf

from app.core.config import settings
from app.core.logging import get_logger
from app.services.audio import AudioService, resample
from app.services.delivery import Delivery
from app.services.engine_errors import EngineNotInstalledError, EngineWorkerError
from app.services.ming_catalog import (
    DIALECT_CONTROLS,
    EMOTION_CONTROLS,
    ENGINE_ID,
    FAST_SPEED_LIMIT,
    PACE_CONTROLS,
    PARALINGUISTIC_TAG_RE,
    PITCH_CONTROLS,
    REFERENCE_SEED,
    REFERENCE_TEXTS,
    SAMPLE_RATE,
    SLOW_SPEED_LIMIT,
    invocation_name,
    ming_language,
    reference_language,
    roster_record,
)
from app.services.ming_installer import MingInstaller
from app.services.ming_voices import (
    DESIGN_SEEDS,
    expected_seconds,
    is_plausible_design,
    ming_voices,
)
from app.services.pronunciation import EMPTY_RULES, PronunciationRules
from app.services.tts import TTSEngine
from app.services.voices import VoiceSpec, voice_spec

log = get_logger(__name__)

WORKER_PATH = Path(settings.RESOURCE_PATH) / "app" / "engines" / "ming" / "worker.py"
LOAD_TIMEOUT_SECONDS = 600.0
REQUEST_TIMEOUT_SECONDS = 900.0
STDERR_CHUNK_BYTES = 64 * 1024
STDERR_LOG_CHARS = 1000
PROTOCOL_LINE_LIMIT = 1024 * 1024
MIN_SPEED = 0.5
MAX_SPEED = 2.0
WORKER_FAILED_MESSAGE = "Ming stopped before it finished. Try again."
DESIGN_FAILED_MESSAGE = (
    "Ming could not design a usable voice from that description. "
    "Try describing it differently."
)

TASK_TTS = "TTS"
TASK_BASIC = "BASIC"
TASK_EMOTION = "EMOTION"
TASK_DIALECT = "DIALECT"
TASK_FREEFORM = "FREEFORM"
NEUTRAL_EMOTION = "neutral"
RUNAWAY_FACTOR = 3.0
RUNAWAY_MIN_SECONDS = 4.0
RUNAWAY_FADE_SECONDS = 0.03


@dataclass(frozen=True)
class TaskChoice:
    task: str
    controls: dict[str, str] | None = None
    instruction: str | None = None
    sends_language: bool = True


@dataclass(frozen=True)
class Reference:
    wav_path: Path
    text: str


def clamp_speed(speed: float) -> float:
    return min(max(speed, MIN_SPEED), MAX_SPEED)


def effective_pace(delivery: Delivery | None, speed: float) -> str | None:
    if delivery is not None and delivery.pace is not None:
        return delivery.pace
    if speed <= SLOW_SPEED_LIMIT:
        return "slow"
    if speed >= FAST_SPEED_LIMIT:
        return "fast"
    return None


def compose_instruction(
    emotion: str | None, pace: str | None, pitch: str | None, style: str | None
) -> str:
    parts = []
    if emotion is not None:
        article = "an" if emotion[0] in "aeiou" else "a"
        parts.append(f"Speak in {article} {emotion} tone.")
    if pace is not None:
        parts.append(f"Speak at a {pace} pace.")
    if pitch is not None:
        parts.append(f"Use a {pitch} pitch.")
    if style is not None:
        parts.append(style)
    return " ".join(parts)


def select_task(delivery: Delivery | None, speed: float) -> TaskChoice:
    if delivery is not None and delivery.dialect is not None:
        return TaskChoice(
            TASK_DIALECT,
            controls={"dialect": DIALECT_CONTROLS[delivery.dialect]},
            sends_language=False,
        )
    emotion = style = pitch = None
    if delivery is not None:
        emotion = None if delivery.emotion == NEUTRAL_EMOTION else delivery.emotion
        style = delivery.style
        pitch = delivery.pitch
    pace = effective_pace(delivery, speed)
    if emotion is not None or style is not None:
        pace = None if pace == "normal" else pace
        pitch = None if pitch == "normal" else pitch
    if style is None and (emotion is None or (pace is None and pitch is None)):
        if emotion is not None:
            return TaskChoice(
                TASK_EMOTION, controls={"emotion": EMOTION_CONTROLS[emotion]}
            )
        controls: dict[str, str] = {}
        if pace is not None:
            controls["speed"] = PACE_CONTROLS[pace]
        if pitch is not None:
            controls["pitch"] = PITCH_CONTROLS[pitch]
        if controls:
            return TaskChoice(TASK_BASIC, controls=controls)
        return TaskChoice(TASK_TTS)
    return TaskChoice(
        TASK_FREEFORM, instruction=compose_instruction(emotion, pace, pitch, style)
    )


def runaway_limit_seconds(text: str, language: str) -> float:
    return max(RUNAWAY_MIN_SECONDS, RUNAWAY_FACTOR * expected_seconds(text, language))


def truncate_runaway(audio: np.ndarray, limit_seconds: float) -> np.ndarray:
    clipped = audio[: int(limit_seconds * SAMPLE_RATE)].copy()
    fade = int(RUNAWAY_FADE_SECONDS * SAMPLE_RATE)
    clipped[-fade:] *= np.linspace(1.0, 0.0, fade, dtype=np.float32)
    return clipped


def speakable_keeping_tags(rules: PronunciationRules, segment: str) -> str | None:
    pieces = PARALINGUISTIC_TAG_RE.split(segment)
    spoken = "".join(
        piece if index % 2 else rules.apply(piece) for index, piece in enumerate(pieces)
    )
    if spoken == segment or any(ch.isalnum() for ch in spoken):
        return spoken
    return None


def worker_environment() -> dict[str, str]:
    environment = {
        key: value
        for key, value in os.environ.items()
        if key not in {"PYTHONHOME", "PYTHONPATH", "VIRTUAL_ENV"}
    }
    environment["PYTHONUNBUFFERED"] = "1"
    environment["HF_HUB_OFFLINE"] = "1"
    environment["TRANSFORMERS_OFFLINE"] = "1"
    environment["TOKENIZERS_PARALLELISM"] = "false"
    return environment


class MingEngine:
    _process: asyncio.subprocess.Process | None = None
    _starting: asyncio.subprocess.Process | None = None
    _stderr_task: asyncio.Task | None = None
    _reapers: set[asyncio.Task] = set()
    _lock: asyncio.Lock = asyncio.Lock()
    _reference_lock: asyncio.Lock = asyncio.Lock()
    _is_initializing: bool = False
    _load_event: asyncio.Event = asyncio.Event()
    _request_ids = itertools.count(1)
    _unanswered: dict[int, str | None] = {}
    _last_request_time: float = 0.0
    _IDLE_TIMEOUT: float = 300.0
    _active_generations: int = 0

    @classmethod
    def touch(cls) -> None:
        cls._last_request_time = time.monotonic()

    @classmethod
    def is_loaded(cls) -> bool:
        return cls._process is not None and cls._process.returncode is None

    @classmethod
    def is_busy(cls) -> bool:
        return cls._is_initializing or cls._active_generations > 0

    @classmethod
    def command(cls) -> list[str]:
        return [
            str(MingInstaller.runtime_python()),
            "-I",
            str(WORKER_PATH),
            "--code",
            str(MingInstaller.code_dir()),
            "--model",
            str(MingInstaller.model_dir()),
        ]

    @classmethod
    async def ensure_loaded(cls) -> None:
        if cls._is_initializing:
            await cls._load_event.wait()
            if not cls.is_loaded():
                raise EngineWorkerError(WORKER_FAILED_MESSAGE)
            return
        if cls.is_loaded():
            return
        cls._is_initializing = True
        cls._load_event.clear()
        try:
            log.info("ming.cold_start")
            await cls.initialize()
        finally:
            cls._is_initializing = False
            cls._load_event.set()

    @classmethod
    async def initialize(cls) -> None:
        if not MingInstaller.is_installed():
            raise EngineNotInstalledError(ENGINE_ID)
        if cls.is_loaded():
            cls.touch()
            return
        cls.unload()
        try:
            process = await asyncio.create_subprocess_exec(
                *cls.command(),
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                env=worker_environment(),
                limit=PROTOCOL_LINE_LIMIT,
            )
        except OSError:
            log.error(
                "ming.fatal_error",
                extra={"failure_code": "ming_spawn_failed"},
                exc_info=True,
            )
            raise EngineWorkerError(WORKER_FAILED_MESSAGE) from None
        cls._starting = process
        cls._stderr_task = asyncio.create_task(cls._drain_stderr(process))
        try:
            ready = await cls._read_ready(process)
        except BaseException:
            cls.unload()
            raise
        if not ready:
            log.error(
                "ming.fatal_error",
                extra={"failure_code": "ming_initialization_failed"},
            )
            cls.unload()
            raise EngineWorkerError(WORKER_FAILED_MESSAGE)
        cls._starting = None
        cls._process = process
        cls.touch()
        log.info("ming.ready")

    @classmethod
    async def _read_ready(cls, process: asyncio.subprocess.Process) -> bool:
        try:
            line = await asyncio.wait_for(
                process.stdout.readline(), timeout=LOAD_TIMEOUT_SECONDS
            )
            message = json.loads(line) if line else {}
        except (TimeoutError, ValueError):
            return False
        return isinstance(message, dict) and bool(message.get("ready"))

    @classmethod
    async def _drain_stderr(cls, process: asyncio.subprocess.Process) -> None:
        stream = process.stderr
        while stream is not None:
            chunk = await stream.read(STDERR_CHUNK_BYTES)
            if not chunk:
                return
            log.debug(
                "ming.worker_output",
                extra={
                    "output": chunk.decode("utf-8", errors="replace")[
                        -STDERR_LOG_CHARS:
                    ]
                },
            )

    @classmethod
    def unload(cls) -> None:
        processes = [p for p in (cls._process, cls._starting) if p is not None]
        cls._process = None
        cls._starting = None
        drain, cls._stderr_task = cls._stderr_task, None
        abandoned = [path for path in cls._unanswered.values() if path]
        cls._unanswered.clear()
        for path in abandoned:
            Path(path).unlink(missing_ok=True)
        for process in processes:
            if process.stdin is not None:
                process.stdin.close()
            if process.returncode is None:
                try:
                    process.kill()
                except ProcessLookupError:
                    pass
            log.info("ming.unloaded")
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            return
        waiters = [loop.create_task(process.wait()) for process in processes]
        for task in (*waiters, drain):
            if task is not None:
                cls._reapers.add(task)
                task.add_done_callback(cls._reapers.discard)

    @classmethod
    async def shutdown(cls) -> None:
        cls.unload()
        if cls._reapers:
            await asyncio.gather(*cls._reapers, return_exceptions=True)

    @classmethod
    async def idle_watcher(cls) -> None:
        while True:
            await asyncio.sleep(60)
            if not cls.is_loaded() or cls.is_busy():
                continue
            if cls._last_request_time == 0:
                continue
            if time.monotonic() - cls._last_request_time > cls._IDLE_TIMEOUT:
                cls.unload()

    @classmethod
    async def _read_reply(
        cls, process: asyncio.subprocess.Process, request_id: int
    ) -> dict[str, Any]:
        loop = asyncio.get_running_loop()
        deadline = loop.time() + REQUEST_TIMEOUT_SECONDS
        while True:
            line = await asyncio.wait_for(
                process.stdout.readline(), timeout=max(deadline - loop.time(), 0.0)
            )
            if not line:
                raise EOFError("worker closed its output")
            reply = json.loads(line)
            reply_id = reply["id"]
            if reply_id == request_id:
                cls._unanswered.pop(request_id, None)
                return reply
            if reply_id not in cls._unanswered:
                raise ValueError("worker replied to a request nobody sent")
            abandoned_output = cls._unanswered.pop(reply_id)
            if abandoned_output is not None:
                Path(abandoned_output).unlink(missing_ok=True)

    @classmethod
    async def _request(cls, payload: dict[str, Any]) -> dict[str, Any]:
        async with cls._lock:
            process = cls._process
            if (
                process is None
                or process.returncode is not None
                or process.stdin is None
                or process.stdout is None
            ):
                raise EngineWorkerError(WORKER_FAILED_MESSAGE)
            cls.touch()
            request_id = next(cls._request_ids)
            line_out = (
                json.dumps({**payload, "id": request_id}, ensure_ascii=False).encode()
                + b"\n"
            )
            try:
                process.stdin.write(line_out)
                cls._unanswered[request_id] = payload.get("out_path")
                await process.stdin.drain()
                reply = await cls._read_reply(process, request_id)
            except asyncio.CancelledError:
                raise
            except Exception:
                log.error(
                    "ming.worker_protocol_failed",
                    extra={"failure_code": "ming_worker_protocol_failed"},
                    exc_info=True,
                )
                if cls._process is process:
                    cls.unload()
                raise EngineWorkerError(WORKER_FAILED_MESSAGE) from None
            if not reply.get("ok"):
                log.warning(
                    "ming.request_error",
                    extra={
                        "failure_code": "ming_request_failed",
                        "op": payload["op"],
                        "worker_error": str(reply.get("error"))[:STDERR_LOG_CHARS],
                    },
                )
                raise EngineWorkerError(WORKER_FAILED_MESSAGE)
            return reply

    @classmethod
    async def _render(cls, payload: dict[str, Any]) -> np.ndarray:
        descriptor, out_path = tempfile.mkstemp(prefix="ming-", suffix=".f32")
        os.close(descriptor)
        try:
            reply = await cls._request({**payload, "out_path": out_path})
            audio = np.fromfile(out_path, dtype="<f4")
        finally:
            Path(out_path).unlink(missing_ok=True)
        if audio.size == 0:
            raise EngineWorkerError(WORKER_FAILED_MESSAGE)
        return resample(audio, int(reply.get("sample_rate", SAMPLE_RATE)), SAMPLE_RATE)

    @classmethod
    def _builtin_reference_paths(cls, ip: str) -> tuple[Path, Path]:
        stem = hashlib.sha1(ip.encode("utf-8")).hexdigest()[:16]
        directory = MingInstaller.references_dir()
        return directory / f"{stem}.wav", directory / f"{stem}.txt"

    @classmethod
    async def _builtin_reference(cls, voice_id: str) -> Reference:
        record = roster_record(voice_id)
        if record is None:
            raise EngineWorkerError(WORKER_FAILED_MESSAGE)
        ip = invocation_name(record)
        language = reference_language(record["language"])
        text = REFERENCE_TEXTS[language]
        wav_path, text_path = cls._builtin_reference_paths(ip)
        async with cls._reference_lock:
            if not (wav_path.is_file() and text_path.is_file()):
                samples = await cls._render(
                    {
                        "op": "ip_reference",
                        "ip": ip,
                        "text": text,
                        "language": language,
                        "seed": REFERENCE_SEED,
                    }
                )
                wav_path.parent.mkdir(parents=True, exist_ok=True)
                partial = wav_path.with_suffix(".partial.wav")
                sf.write(str(partial), samples, SAMPLE_RATE, subtype="PCM_16")
                os.replace(partial, wav_path)
                text_path.write_text(text, encoding="utf-8")
        return Reference(wav_path, text_path.read_text(encoding="utf-8"))

    @classmethod
    async def reference_for(cls, spec: VoiceSpec) -> Reference:
        custom = ming_voices.get(spec.id)
        if custom is None:
            return await cls._builtin_reference(spec.id)
        wav_path = ming_voices.wav_path(custom.id)
        if not wav_path.is_file():
            raise EngineWorkerError(WORKER_FAILED_MESSAGE)
        return Reference(wav_path, custom.transcript)

    @classmethod
    async def _synthesize(
        cls,
        text: str,
        spec: VoiceSpec,
        lang: str | None,
        speed: float,
        delivery: Delivery | None,
    ) -> np.ndarray:
        await cls.ensure_loaded()
        reference = await cls.reference_for(spec)
        choice = select_task(delivery, speed)
        language = ming_language(lang) or spec.lang
        limit_seconds = runaway_limit_seconds(text, language)
        attempts = (
            (REFERENCE_SEED, reference.text if choice.task == TASK_TTS else None),
            (REFERENCE_SEED + 1, reference.text),
        )
        for seed, reference_text in attempts:
            audio = await cls._render(
                {
                    "op": "synthesize",
                    "text": text,
                    "language": language if choice.sends_language else None,
                    "reference_wav": str(reference.wav_path),
                    "reference_text": reference_text,
                    "task": choice.task,
                    "controls": choice.controls,
                    "instruction": choice.instruction,
                    "seed": seed,
                }
            )
            if audio.size / SAMPLE_RATE <= limit_seconds:
                return audio
            log.warning(
                "ming.runaway_segment",
                extra={
                    "failure_code": "ming_runaway_segment",
                    "task": choice.task,
                    "seed": seed,
                    "seconds": round(audio.size / SAMPLE_RATE, 1),
                    "limit_seconds": round(limit_seconds, 1),
                },
            )
        return truncate_runaway(audio, limit_seconds)

    @classmethod
    async def prepare_reference(cls, spec: VoiceSpec) -> Reference:
        cls._active_generations += 1
        try:
            await cls.ensure_loaded()
            return await cls.reference_for(spec)
        finally:
            cls._active_generations -= 1

    @classmethod
    async def design_sample(
        cls, description: str, language: str, text: str
    ) -> np.ndarray:
        cls._active_generations += 1
        try:
            await cls.ensure_loaded()
            for seed in DESIGN_SEEDS:
                samples = await cls._render(
                    {
                        "op": "design",
                        "text": text,
                        "language": language,
                        "description": description,
                        "seed": seed,
                    }
                )
                if is_plausible_design(samples, text, language):
                    return samples
                log.warning(
                    "ming.design_rejected",
                    extra={"failure_code": "ming_design_implausible", "seed": seed},
                )
            raise EngineWorkerError(DESIGN_FAILED_MESSAGE)
        finally:
            cls._active_generations -= 1

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
        delivery: Delivery | None = None,
    ) -> AsyncGenerator[np.ndarray, None]:
        await cls.ensure_loaded()

        segments = TTSEngine._split_segments(text)
        if not segments:
            return

        spec = voice_spec(voice)
        effective_speed = clamp_speed(speed)
        rules = pronunciation or EMPTY_RULES

        cls._active_generations += 1
        try:
            for segment in segments:
                cls.touch()
                stripped = segment.strip()
                spoken = speakable_keeping_tags(rules, stripped)
                if spoken is None:
                    continue
                try:
                    audio = await cls._synthesize(
                        spoken, spec, lang, effective_speed, delivery
                    )
                except Exception as error:
                    log.warning(
                        "ming.segment_error",
                        extra={
                            "segment_chars": len(segment),
                            "error_type": type(error).__name__,
                        },
                        exc_info=True,
                    )
                    if failed_segments is not None:
                        failed_segments.append(stripped)
                    continue
                audio = resample(audio, SAMPLE_RATE, settings.AUDIO_SAMPLE_RATE)
                silence = AudioService.get_silence(
                    TTSEngine._pause_seconds(stripped, effective_speed, pause_scale)
                )
                yield np.concatenate([audio, silence])
        finally:
            cls._active_generations -= 1
