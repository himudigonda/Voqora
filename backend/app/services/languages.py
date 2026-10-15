from __future__ import annotations

# Japanese ("j") is absent: espeak-ng has no kanji grapheme-to-phoneme backend.
_PREFIX_TO_ESPEAK: dict[str, str] = {
    "a": "en-us",
    "b": "en-gb",
    "e": "es",
    "f": "fr-fr",
    "h": "hi",
    "i": "it",
    "p": "pt-br",
    "z": "cmn",
}

_DEFAULT_ESPEAK = "en-us"


def espeak_lang_for_voice(voice: str) -> str:
    if not voice:
        return _DEFAULT_ESPEAK
    return _PREFIX_TO_ESPEAK.get(voice[0], _DEFAULT_ESPEAK)


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

VOICES: list[dict] = [
    {"id": "af_bella", "name": "Bella", "gender": "female"},
    {"id": "af_sarah", "name": "Sarah", "gender": "female"},
    {"id": "am_adam", "name": "Adam", "gender": "male"},
    {"id": "am_michael", "name": "Michael", "gender": "male"},
    {"id": "af_heart", "name": "Heart", "gender": "female"},
    {"id": "af_nicole", "name": "Nicole", "gender": "female"},
    {"id": "af_aoede", "name": "Aoede", "gender": "female"},
    {"id": "af_kore", "name": "Kore", "gender": "female"},
    {"id": "am_fenrir", "name": "Fenrir", "gender": "male"},
    {"id": "am_puck", "name": "Puck", "gender": "male"},
    {"id": "bf_emma", "name": "Emma", "gender": "female"},
    {"id": "bf_isabella", "name": "Isabella", "gender": "female"},
    {"id": "bm_george", "name": "George", "gender": "male"},
    {"id": "bm_lewis", "name": "Lewis", "gender": "male"},
    {"id": "bm_fable", "name": "Fable", "gender": "male"},
    {"id": "ef_dora", "name": "Dora", "gender": "female"},
    {"id": "em_alex", "name": "Alex", "gender": "male"},
    {"id": "ff_siwis", "name": "Siwis", "gender": "female"},
    {"id": "if_sara", "name": "Sara", "gender": "female"},
    {"id": "im_nicola", "name": "Nicola", "gender": "male"},
    {"id": "pf_dora", "name": "Dora", "gender": "female"},
    {"id": "pm_alex", "name": "Alex", "gender": "male"},
    {"id": "hf_alpha", "name": "Aanya", "gender": "female"},
    {"id": "hf_beta", "name": "Diya", "gender": "female"},
    {"id": "hm_omega", "name": "Arjun", "gender": "male"},
    {"id": "hm_psi", "name": "Kabir", "gender": "male"},
    {"id": "zf_xiaoxiao", "name": "Xiaoxiao", "gender": "female"},
    {"id": "zm_yunyang", "name": "Yunyang", "gender": "male"},
]

VOICE_IDS: list[str] = [v["id"] for v in VOICES]
_VOICE_SET: set[str] = set(VOICE_IDS)

DEFAULT_VOICE = "af_bella"


def is_valid_voice(voice: str) -> bool:
    return voice in _VOICE_SET


def voice_catalog() -> list[dict]:
    return [{**v, "lang": espeak_lang_for_voice(v["id"])} for v in VOICES]


def language_catalog() -> list[dict]:
    out: list[dict] = []
    for lang in LANGUAGES:
        voices = [
            v["id"] for v in VOICES if espeak_lang_for_voice(v["id"]) == lang["code"]
        ]
        out.append({**lang, "voices": voices})
    return out
