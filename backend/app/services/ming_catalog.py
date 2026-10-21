from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from app.core.config import settings

ENGINE_ID = "ming"
ENGINE_NAME = "Ming"
VOICE_PREFIX = f"{ENGINE_ID}:"
CUSTOM_VOICE_PREFIX = f"{VOICE_PREFIX}custom:"
DEFAULT_VOICE = f"{VOICE_PREFIX}US_Stella"

INSTALL_DIR_NAME = "ming-3.0-tts"

CODE_REPO = "inclusionAI/Ming-3.0-tts"
CODE_REVISION = "e999c39fa676722aaa9ea29b5aa19a90525b271f"
CODE_TARBALL_URL = f"https://codeload.github.com/{CODE_REPO}/tar.gz/{CODE_REVISION}"
CODE_TOP_LEVEL_DIRECTORIES = ("audio_tokenizer", "fm", "frontend")
CODE_TOP_LEVEL_FILES = ("LICENSE", "LEGAL.md")

MODEL_REPO = "inclusionAI/Ming-3.0-tts-0.5B"
MODEL_REVISION = "e5bd8da31ecf1b9276cdbdda821fa891068f1368"
MODEL_IGNORE_PATTERNS = ("figures/*", "README.md")

MODEL_SIZE_BYTES = 3_003_320_700
RUNTIME_SIZE_BYTES = 700_000_000
CODE_SIZE_BYTES = 12_000_000
SIZE_BYTES = MODEL_SIZE_BYTES + RUNTIME_SIZE_BYTES + CODE_SIZE_BYTES

RUNTIME_PROGRESS_WEIGHT = 0.2
CODE_PROGRESS_WEIGHT = 0.02
MODEL_PROGRESS_WEIGHT = 0.78

LICENSE_SUMMARY = "MIT"
NOTICE = "Renders slower than real time on most Macs. Best for audiobooks and exports."
CAPABILITIES: tuple[str, ...] = (
    "emotion",
    "style",
    "pace",
    "pitch",
    "dialect",
    "design",
    "clone",
    "tags",
)

LANGUAGES: tuple[str, ...] = ("en", "zh", "ja", "ko", "de", "fr", "es")
LANGUAGE_ALIASES: dict[str, str] = {"cmn": "zh"}
SAMPLE_RATE = 44100

PARALINGUISTIC_TAGS: tuple[str, ...] = (
    "[Breathing]",
    "[Cough]",
    "[Sigh]",
    "[Laughter]",
    "[Surprise-ah]",
    "[Surprise-oh]",
    "[Dissatisfaction-hnn]",
    "[Uhm]",
    "[Confirmation-en]",
    "[Question-ei]",
    "[Question-ah]",
    "[Question-en]",
    "[Question-oh]",
    "[Question-huh]",
)
PARALINGUISTIC_TAG_RE = re.compile(
    "(" + "|".join(re.escape(tag) for tag in PARALINGUISTIC_TAGS) + ")"
)

EMOTION_CONTROLS: dict[str, str] = {
    "neutral": "中性",
    "happy": "高兴",
    "sad": "悲伤",
    "angry": "愤怒",
    "fearful": "恐惧",
    "disgusted": "厌恶",
    "surprised": "惊讶",
}
PACE_CONTROLS: dict[str, str] = {"slow": "慢速", "normal": "中速", "fast": "快速"}
PITCH_CONTROLS: dict[str, str] = {"low": "低", "normal": "中", "high": "高"}
DIALECT_CONTROLS: dict[str, str] = {
    "cantonese": "cantonese",
    "sichuanese": "chuanyu dialect",
}

SLOW_SPEED_LIMIT = 0.85
FAST_SPEED_LIMIT = 1.2

REFERENCE_TEXTS: dict[str, str] = {
    "en": "Hello there. This is a short sample of how I sound when I read aloud.",
    "zh": "你好，这是我朗读时的声音样本，希望你喜欢。",
}
REFERENCE_SEED = 1234

_ROSTER_PATH = Path(settings.RESOURCE_PATH) / "app" / "services" / "ming_voices.json"
_ENGLISH_PREFIX_RE = re.compile(r"^(US|UK)_")


def display_name(ip: str, language: str) -> str:
    return _ENGLISH_PREFIX_RE.sub("", ip) if language == "en" else ip


def reference_language(language: str) -> str:
    return "zh" if language == "zh" else "en"


def _load_roster() -> tuple[dict[str, Any], ...]:
    return tuple(json.loads(_ROSTER_PATH.read_text(encoding="utf-8")))


def _voice_entry(record: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": f"{VOICE_PREFIX}{record['ip']}",
        "name": display_name(record["ip"], record["language"]),
        "gender": record["gender"],
        "lang": record["language"],
        "description": record["description"],
        "emotions": sorted(record["emotions"], key=list(EMOTION_CONTROLS).index),
        "custom": False,
    }


ROSTER: tuple[dict[str, Any], ...] = _load_roster()
VOICES: tuple[dict[str, Any], ...] = tuple(_voice_entry(record) for record in ROSTER)
VOICE_IDS: frozenset[str] = frozenset(voice["id"] for voice in VOICES)
_ROSTER_BY_ID: dict[str, dict[str, Any]] = {
    f"{VOICE_PREFIX}{record['ip']}": record for record in ROSTER
}


def is_ming_voice(voice_id: str) -> bool:
    return voice_id in VOICE_IDS


def roster_record(voice_id: str) -> dict[str, Any] | None:
    return _ROSTER_BY_ID.get(voice_id)


def invocation_name(record: dict[str, Any]) -> str:
    return record["emotions"].get("neutral") or record["ip"]


def ming_language(lang: str | None) -> str | None:
    if not lang:
        return None
    base = lang.lower().split("-")[0]
    base = LANGUAGE_ALIASES.get(base, base)
    return base if base in LANGUAGES else None
