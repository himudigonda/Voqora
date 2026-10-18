from __future__ import annotations

from typing import Any

from app.services.engine_manager import EngineManager
from app.services.languages import voice_catalog
from app.services.voices import is_known_voice

MAX_VOICE_ID_CHARS = 64

OPENAI_VOICE_ALIASES: dict[str, str] = {
    "alloy": "af_heart",
    "echo": "am_michael",
    "fable": "bm_fable",
    "onyx": "am_adam",
    "nova": "af_bella",
    "shimmer": "af_nicole",
}


def custom_voices() -> list[dict[str, str]]:
    entries = EngineManager.state().get("blends") or []
    return [_custom_entry(entry) for entry in entries if _has_string_id(entry)]


def voice_list() -> list[dict[str, Any]]:
    builtin = [
        {
            "id": voice["id"],
            "name": voice["name"],
            "gender": voice["gender"],
            "language": voice["lang"],
            "type": "builtin",
        }
        for voice in voice_catalog()
    ]
    return builtin + custom_voices()


def resolve_voice(value: str) -> str | None:
    alias = OPENAI_VOICE_ALIASES.get(value.strip().lower())
    if alias is not None:
        return alias
    # Built-in voices and saved blends, the same check /speak uses.
    if is_known_voice(value):
        return value
    if any(voice["id"] == value for voice in custom_voices()):
        return value
    return None


def require_voice(value: str) -> str:
    resolved = resolve_voice(value)
    if resolved is None:
        raise ValueError("Unknown voice. List voices with GET /v1/voices.")
    return resolved


def _has_string_id(entry: Any) -> bool:
    return isinstance(entry, dict) and isinstance(entry.get("id"), str)


def _custom_entry(entry: dict[str, Any]) -> dict[str, str]:
    name = entry.get("name")
    return {
        "id": entry["id"],
        "name": name if isinstance(name, str) else entry["id"],
        "type": "custom",
    }
