from __future__ import annotations

import io
import re
import threading
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

import numpy as np
import soundfile as sf

from app.core.config import settings
from app.core.logging import get_logger
from app.services.audio import resample
from app.services.audiobook_store import _now_iso
from app.services.json_store import JsonDocument
from app.services.ming_catalog import (
    CUSTOM_VOICE_PREFIX,
    LANGUAGES,
    REFERENCE_TEXTS,
    SAMPLE_RATE,
)
from app.services.voice_blends import validate_name

log = get_logger(__name__)

MAX_CUSTOM_VOICES = 50
MAX_DESCRIPTION_CHARS = 300
MAX_TRANSCRIPT_CHARS = 500
MIN_CLONE_SECONDS = 3.0
MAX_CLONE_SECONDS = 30.0
MAX_CLONE_UPLOAD_BYTES = 40 * 1024 * 1024
MIN_DESIGN_SECONDS = 0.5
MAX_DESIGN_DURATION_FACTOR = 3.0
MIN_DESIGN_LIMIT_SECONDS = 4.0
SILENCE_PEAK = 1e-3
DESIGN_SEEDS = (1234, 1235, 1236)
SAMPLE_FORMAT = "WAV"
SAMPLE_SUBTYPE = "PCM_16"
_SCHEMA_VERSION = 1

CHARS_PER_SECOND: dict[str, float] = {"zh": 5.0, "ja": 5.0, "ko": 5.0}
DEFAULT_CHARS_PER_SECOND = 15.0

DESIGN_SAMPLE_TEXTS: dict[str, str] = {
    **REFERENCE_TEXTS,
    "ja": "こんにちは、これは私が読み上げるときの声のサンプルです。",
    "ko": "안녕하세요, 제가 글을 읽어 드릴 때의 목소리 샘플입니다.",
    "de": "Hallo, das ist eine kurze Probe, wie ich beim Vorlesen klinge.",
    "fr": "Bonjour, voici un court échantillon de ma voix quand je lis à voix haute.",
    "es": "Hola, esta es una breve muestra de cómo suena mi voz al leer en voz alta.",
}

VoiceKind = Literal["designed", "cloned"]

_CUSTOM_ID_RE = re.compile(rf"^{re.escape(CUSTOM_VOICE_PREFIX)}[0-9a-f]{{32}}$")


class VoiceValidationError(ValueError):
    pass


class VoiceLimitError(Exception):
    pass


class VoiceNotFoundError(Exception):
    pass


@dataclass(frozen=True)
class MingVoice:
    id: str
    name: str
    language: str
    kind: VoiceKind
    description: str
    transcript: str
    created_at: str

    def to_record(self) -> dict[str, str]:
        return {
            "id": self.id,
            "name": self.name,
            "language": self.language,
            "kind": self.kind,
            "description": self.description,
            "transcript": self.transcript,
            "created_at": self.created_at,
        }

    def to_entry(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "gender": "unknown",
            "lang": self.language,
            "description": self.description,
            "emotions": [],
            "custom": True,
            "kind": self.kind,
        }


def is_custom_voice_id(voice_id: str) -> bool:
    return bool(_CUSTOM_ID_RE.fullmatch(voice_id))


def require_language(language: str) -> str:
    cleaned = language.strip().lower()
    if cleaned not in LANGUAGES:
        raise VoiceValidationError(f"language must be one of: {', '.join(LANGUAGES)}")
    return cleaned


def require_text(value: str, label: str, maximum: int) -> str:
    cleaned = " ".join(value.split())
    if not 1 <= len(cleaned) <= maximum:
        raise VoiceValidationError(f"{label} must be 1 to {maximum} characters")
    return cleaned


def require_name(name: str) -> str:
    try:
        return validate_name(name)
    except ValueError as error:
        raise VoiceValidationError(str(error)) from None


def default_sample_text(language: str) -> str:
    return DESIGN_SAMPLE_TEXTS[language]


def expected_seconds(text: str, language: str) -> float:
    rate = CHARS_PER_SECOND.get(language, DEFAULT_CHARS_PER_SECOND)
    return len(text.strip()) / rate


def is_plausible_design(samples: np.ndarray, text: str, language: str) -> bool:
    seconds = samples.size / SAMPLE_RATE
    limit = max(
        MIN_DESIGN_LIMIT_SECONDS,
        MAX_DESIGN_DURATION_FACTOR * expected_seconds(text, language),
    )
    return MIN_DESIGN_SECONDS <= seconds <= limit


def _unreadable_audio() -> VoiceValidationError:
    return VoiceValidationError(
        "Could not read that audio file. Use WAV, FLAC, AIFF or MP3."
    )


def _require_clone_duration(seconds: float) -> None:
    if not MIN_CLONE_SECONDS <= seconds <= MAX_CLONE_SECONDS:
        raise VoiceValidationError(
            f"Use a clip between {MIN_CLONE_SECONDS:g} and "
            f"{MAX_CLONE_SECONDS:g} seconds long."
        )


def prepare_clone_audio(data: bytes) -> np.ndarray:
    if len(data) > MAX_CLONE_UPLOAD_BYTES:
        raise VoiceValidationError("That audio file is too large.")
    try:
        _require_clone_duration(sf.info(io.BytesIO(data)).duration)
    except VoiceValidationError:
        raise
    except Exception:
        raise _unreadable_audio() from None
    try:
        audio, rate = sf.read(io.BytesIO(data), dtype="float32", always_2d=True)
    except Exception:
        raise _unreadable_audio() from None
    mono = audio.mean(axis=1) if audio.size else audio.reshape(-1)
    _require_clone_duration(mono.size / rate if rate else 0.0)
    if float(np.max(np.abs(mono))) < SILENCE_PEAK:
        raise VoiceValidationError("That audio file is silent.")
    return resample(mono.astype(np.float32), rate, SAMPLE_RATE)


def _voice_from_record(record: Any) -> MingVoice:
    if not isinstance(record, dict):
        raise ValueError("record must be an object")
    voice_id = str(record.get("id", ""))
    if not is_custom_voice_id(voice_id):
        raise ValueError("invalid voice id")
    kind = record.get("kind")
    if kind not in ("designed", "cloned"):
        raise ValueError("invalid kind")
    return MingVoice(
        id=voice_id,
        name=validate_name(str(record.get("name", ""))),
        language=require_language(str(record.get("language", ""))),
        kind=kind,
        description=str(record.get("description", "")),
        transcript=str(record.get("transcript", "")),
        created_at=str(record.get("created_at", "")),
    )


class MingVoiceStore:
    def __init__(
        self, path_provider: Callable[[], str], directory_provider: Callable[[], str]
    ) -> None:
        self._document = JsonDocument(path_provider, "ming_voices")
        self._directory_provider = directory_provider
        self._lock = threading.RLock()
        self._voices: dict[str, MingVoice] | None = None

    def reset(self) -> None:
        with self._lock:
            self._voices = None

    def wav_path(self, voice_id: str) -> Path:
        return Path(self._directory_provider()) / f"{voice_id.rsplit(':', 1)[-1]}.wav"

    def list(self) -> list[MingVoice]:
        with self._lock:
            return list(self._loaded().values())

    def get(self, voice_id: str) -> MingVoice | None:
        if not is_custom_voice_id(voice_id):
            return None
        with self._lock:
            return self._loaded().get(voice_id)

    def create(
        self,
        *,
        name: str,
        language: str,
        kind: VoiceKind,
        description: str,
        transcript: str,
        samples: np.ndarray,
    ) -> MingVoice:
        with self._lock:
            voices = self._loaded()
            if len(voices) >= MAX_CUSTOM_VOICES:
                raise VoiceLimitError(
                    f"You can save up to {MAX_CUSTOM_VOICES} custom Ming voices."
                )
            voice = MingVoice(
                id=f"{CUSTOM_VOICE_PREFIX}{uuid.uuid4().hex}",
                name=name,
                language=language,
                kind=kind,
                description=description,
                transcript=transcript,
                created_at=_now_iso(),
            )
            path = self.wav_path(voice.id)
            path.parent.mkdir(parents=True, exist_ok=True)
            sf.write(
                str(path),
                samples,
                SAMPLE_RATE,
                format=SAMPLE_FORMAT,
                subtype=SAMPLE_SUBTYPE,
            )
            try:
                self._commit({**voices, voice.id: voice})
            except BaseException:
                path.unlink(missing_ok=True)
                raise
            return voice

    def delete(self, voice_id: str) -> bool:
        with self._lock:
            voices = self._loaded()
            if voice_id not in voices:
                return False
            self._commit({k: v for k, v in voices.items() if k != voice_id})
            self.wav_path(voice_id).unlink(missing_ok=True)
            return True

    def _loaded(self) -> dict[str, MingVoice]:
        if self._voices is None:
            self._voices = self._read()
        return self._voices

    def _read(self) -> dict[str, MingVoice]:
        voices: dict[str, MingVoice] = {}
        skipped = 0
        for record in self._document.load().get("voices") or []:
            try:
                voice = _voice_from_record(record)
            except (TypeError, ValueError):
                skipped += 1
                continue
            if voice.id in voices or not self.wav_path(voice.id).is_file():
                skipped += 1
                continue
            voices[voice.id] = voice
        if skipped:
            log.warning(
                "ming_voices.records_skipped",
                extra={"skipped": skipped, "failure_code": "ming_voice_invalid"},
            )
        return voices

    def _commit(self, voices: dict[str, MingVoice]) -> None:
        self._document.save(
            {
                "schema": _SCHEMA_VERSION,
                "voices": [voice.to_record() for voice in voices.values()],
            }
        )
        self._voices = voices


ming_voices = MingVoiceStore(
    lambda: settings.MING_VOICES_PATH, lambda: settings.MING_VOICES_DIR
)
