"""Language + voice catalog for Kokoro-82M (single source of truth).

Kokoro-82M v1.0 ships 54 voice styles across 9 locales in `voices-v1.0.bin`.
Voqora phonemizes through `kokoro-onnx` → espeak-ng, so a locale is shippable
only if espeak-ng has a real grapheme-to-phoneme backend for it.

Empirically validated (see journal.md "Empirical per-language audio validation"):
  - English (US/GB), Spanish, French, Italian, Brazilian Portuguese, Hindi:
    espeak produces clean, correct phonemes → fully supported.
  - Mandarin: espeak `cmn` produces correct pinyin-IPA → shipped as BETA
    (segmental phonemes correct; tone fidelity pending human audio QA).
  - Japanese: espeak has NO kanji G2P (transliterates kanji as English "Chinese
    letter" and loops) → EXCLUDED until a misaki/pyopenjtalk phonemizer is bundled.

Design invariant: the *first character* of a voice ID is its language prefix, so
the espeak lang code is derived from the voice alone — the client never sends a
language, it just sends a voice ID (HARD-compatible: no protocol change).
"""

from __future__ import annotations

# Voice language-prefix → espeak-ng language code.
# Japanese ("j") is intentionally absent — see module docstring.
_PREFIX_TO_ESPEAK: dict[str, str] = {
    "a": "en-us",  # American English
    "b": "en-gb",  # British English
    "e": "es",  # Spanish
    "f": "fr-fr",  # French
    "h": "hi",  # Hindi
    "i": "it",  # Italian
    "p": "pt-br",  # Brazilian Portuguese
    "z": "cmn",  # Mandarin Chinese (Beta)
}

_DEFAULT_ESPEAK = "en-us"


def espeak_lang_for_voice(voice: str) -> str:
    """Map a Kokoro voice ID to its espeak-ng language code.

    Falls back to en-us for unknown/malformed voices so a bad voice ID degrades
    to English narration rather than raising mid-stream.
    """
    if not voice:
        return _DEFAULT_ESPEAK
    return _PREFIX_TO_ESPEAK.get(voice[0], _DEFAULT_ESPEAK)


# ---------------------------------------------------------------------------
# Curated voice catalog. Each language groups quality-graded voices (HuggingFace
# VOICES.md grades). Legacy English voices are kept first for backward-compat
# with audiobooks that stored them. `name` is the display label; `gender` drives
# the UI icon. Order here is the order voices appear in the picker.
# ---------------------------------------------------------------------------

# (code, display, native_name, flag, beta)
LANGUAGES: list[dict] = [
    {
        "code": "en-us",
        "name": "English (US)",
        "native": "English",
        "flag": "🇺🇸",
        "beta": False,
    },
    {
        "code": "en-gb",
        "name": "English (UK)",
        "native": "English",
        "flag": "🇬🇧",
        "beta": False,
    },
    {"code": "es", "name": "Spanish", "native": "Español", "flag": "🇪🇸", "beta": False},
    {
        "code": "fr-fr",
        "name": "French",
        "native": "Français",
        "flag": "🇫🇷",
        "beta": False,
    },
    {
        "code": "it",
        "name": "Italian",
        "native": "Italiano",
        "flag": "🇮🇹",
        "beta": False,
    },
    {
        "code": "pt-br",
        "name": "Portuguese",
        "native": "Português",
        "flag": "🇧🇷",
        "beta": False,
    },
    {"code": "hi", "name": "Hindi", "native": "हिन्दी", "flag": "🇮🇳", "beta": False},
    {"code": "cmn", "name": "Mandarin", "native": "中文", "flag": "🇨🇳", "beta": True},
]

# voice_id -> {name, gender, lang (espeak code)}
# Only voices that render cleanly under espeak are listed. Grades from VOICES.md.
VOICES: list[dict] = [
    # --- American English (legacy 4 kept first for audiobook back-compat) ---
    {"id": "af_bella", "name": "Bella", "gender": "female"},
    {"id": "af_sarah", "name": "Sarah", "gender": "female"},
    {"id": "am_adam", "name": "Adam", "gender": "male"},
    {"id": "am_michael", "name": "Michael", "gender": "male"},
    {"id": "af_heart", "name": "Heart", "gender": "female"},  # grade A
    {"id": "af_nicole", "name": "Nicole", "gender": "female"},  # grade B-
    {"id": "af_aoede", "name": "Aoede", "gender": "female"},
    {"id": "af_kore", "name": "Kore", "gender": "female"},
    {"id": "am_fenrir", "name": "Fenrir", "gender": "male"},
    {"id": "am_puck", "name": "Puck", "gender": "male"},
    # --- British English (legacy 4 kept) ---
    {"id": "bf_emma", "name": "Emma", "gender": "female"},  # grade B-
    {"id": "bf_isabella", "name": "Isabella", "gender": "female"},
    {"id": "bm_george", "name": "George", "gender": "male"},
    {"id": "bm_lewis", "name": "Lewis", "gender": "male"},
    {"id": "bm_fable", "name": "Fable", "gender": "male"},  # grade C
    # --- Spanish ---
    {"id": "ef_dora", "name": "Dora", "gender": "female"},
    {"id": "em_alex", "name": "Alex", "gender": "male"},
    # --- French ---
    {"id": "ff_siwis", "name": "Siwis", "gender": "female"},  # grade B-
    # --- Italian ---
    {"id": "if_sara", "name": "Sara", "gender": "female"},
    {"id": "im_nicola", "name": "Nicola", "gender": "male"},
    # --- Brazilian Portuguese ---
    {"id": "pf_dora", "name": "Dora", "gender": "female"},
    {"id": "pm_alex", "name": "Alex", "gender": "male"},
    # --- Hindi ---
    {"id": "hf_alpha", "name": "Aanya", "gender": "female"},
    {"id": "hf_beta", "name": "Diya", "gender": "female"},
    {"id": "hm_omega", "name": "Arjun", "gender": "male"},
    {"id": "hm_psi", "name": "Kabir", "gender": "male"},
    # --- Mandarin (Beta) ---
    {"id": "zf_xiaoxiao", "name": "Xiaoxiao", "gender": "female"},
    {"id": "zm_yunyang", "name": "Yunyang", "gender": "male"},
]

# Fast membership/lookup structures derived once at import.
VOICE_IDS: list[str] = [v["id"] for v in VOICES]
_VOICE_SET: set[str] = set(VOICE_IDS)

DEFAULT_VOICE = "af_bella"


def is_valid_voice(voice: str) -> bool:
    return voice in _VOICE_SET


def voice_catalog() -> list[dict]:
    """Full voice catalog enriched with the espeak lang each voice renders in."""
    return [{**v, "lang": espeak_lang_for_voice(v["id"])} for v in VOICES]


def language_catalog() -> list[dict]:
    """Languages with their voice IDs grouped under each, in catalog order."""
    out: list[dict] = []
    for lang in LANGUAGES:
        voices = [
            v["id"] for v in VOICES if espeak_lang_for_voice(v["id"]) == lang["code"]
        ]
        out.append({**lang, "voices": voices})
    return out
