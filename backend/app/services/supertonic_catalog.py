from __future__ import annotations

import re
from collections import Counter

ENGINE_ID = "supertonic"
ENGINE_NAME = "Supertonic"
VOICE_PREFIX = f"{ENGINE_ID}:"
DEFAULT_VOICE = f"{VOICE_PREFIX}F1"

MODEL_NAME = "supertonic-3"
MODEL_REPO = "Supertone/supertonic-3"
MODEL_REVISION = "724fb5abbf5502583fb520898d45929e62f02c0b"
MODEL_SIZE_BYTES = 401_291_807
MODEL_ALLOW_PATTERNS = ("onnx/*", "voice_styles/*", "LICENSE*")

LICENSE_SUMMARY = "Code MIT, model weights OpenRAIL-M"

LANGUAGES: tuple[str, ...] = (
    "en",
    "ko",
    "ja",
    "ar",
    "bg",
    "cs",
    "da",
    "de",
    "el",
    "es",
    "et",
    "fi",
    "fr",
    "hi",
    "hr",
    "hu",
    "id",
    "it",
    "lt",
    "lv",
    "nl",
    "pl",
    "pt",
    "ro",
    "ru",
    "sk",
    "sl",
    "sv",
    "tr",
    "uk",
    "vi",
)
UNKNOWN_LANGUAGE = "na"

_STYLE_NAMES = ("M1", "M2", "M3", "M4", "M5", "F1", "F2", "F3", "F4", "F5")


def _voice_entry(style: str) -> dict[str, str]:
    gender = "male" if style.startswith("M") else "female"
    return {
        "id": f"{VOICE_PREFIX}{style}",
        "name": f"{gender.capitalize()} {style[1:]}",
        "gender": gender,
        "lang": "multi",
    }


VOICES: tuple[dict[str, str], ...] = tuple(
    _voice_entry(style) for style in _STYLE_NAMES
)
VOICE_IDS: frozenset[str] = frozenset(voice["id"] for voice in VOICES)


def is_supertonic_voice(voice_id: str) -> bool:
    return voice_id in VOICE_IDS


def style_name(voice_id: str) -> str:
    return voice_id.removeprefix(VOICE_PREFIX)


def supertonic_language(lang: str | None) -> str:
    if not lang:
        return UNKNOWN_LANGUAGE
    base = lang.lower().split("-")[0]
    return base if base in LANGUAGES else UNKNOWN_LANGUAGE


_ENGLISH_FUNCTION_WORDS = frozenset(
    "the and of to in is that it for was with as on are this be by at or from "
    "have not you he she they we his her but had has an were will would there".split()
)
_ENGLISH_SHARE = 0.12
_WORD_PATTERN = re.compile(r"[A-Za-z']+")
_SCRIPT_RANGES: tuple[tuple[int, int, str], ...] = (
    (0x1100, 0x11FF, "ko"),
    (0x3130, 0x318F, "ko"),
    (0xAC00, 0xD7AF, "ko"),
    (0x3040, 0x30FF, "ja"),
    (0x0400, 0x04FF, "ru"),
    (0x0600, 0x06FF, "ar"),
    (0x0900, 0x097F, "hi"),
    (0x0370, 0x03FF, "el"),
)
_UKRAINIAN_LETTERS = frozenset("іїєґІЇЄҐ")


def _script_of(char: str) -> str:
    code = ord(char)
    for low, high, script in _SCRIPT_RANGES:
        if low <= code <= high:
            return script
    return "latin" if code < 0x250 else "other"


def _looks_english(text: str) -> bool:
    words = _WORD_PATTERN.findall(text.lower())
    if len(words) < 3:
        return False
    hits = sum(1 for word in words if word in _ENGLISH_FUNCTION_WORDS)
    return hits >= 2 and hits / len(words) >= _ENGLISH_SHARE


def detect_language(text: str) -> str:
    letters = Counter(_script_of(char) for char in text if char.isalpha())
    if not letters:
        return UNKNOWN_LANGUAGE
    script, _ = letters.most_common(1)[0]
    if script == "latin":
        return "en" if _looks_english(text) else UNKNOWN_LANGUAGE
    if letters["ja"] and script in {"ja", "other"}:
        return "ja"
    if script == "other":
        return UNKNOWN_LANGUAGE
    if script == "ru" and any(char in _UKRAINIAN_LETTERS for char in text):
        return "uk"
    return script


def resolve_language(lang: str | None, text: str) -> str:
    return supertonic_language(lang) if lang else detect_language(text)
