"""Tests for the language + voice catalog (app.services.languages).

Two layers:
  1. Pure-logic tests (no model, no espeak) — mapping, catalog integrity,
     backward-compat guarantees.
  2. Phonemizer regression guards — use the standalone kokoro_onnx Tokenizer
     (espeak only, no 326MB ONNX model) to lock in the empirical finding that
     espeak handles es/fr/it/pt/hi/cmn cleanly but mangles Japanese kanji.
     These skip automatically if espeak-ng isn't importable.
"""

from __future__ import annotations

import re

import pytest

from app.services.languages import (
    DEFAULT_VOICE,
    LANGUAGES,
    VOICE_IDS,
    VOICES,
    espeak_lang_for_voice,
    is_valid_voice,
    language_catalog,
    voice_catalog,
)

# ---------- voice → espeak lang mapping ----------


@pytest.mark.parametrize(
    "voice,expected",
    [
        ("af_bella", "en-us"),
        ("am_adam", "en-us"),
        ("bf_emma", "en-gb"),
        ("bm_george", "en-gb"),
        ("ef_dora", "es"),
        ("em_alex", "es"),
        ("ff_siwis", "fr-fr"),
        ("if_sara", "it"),
        ("im_nicola", "it"),
        ("pf_dora", "pt-br"),
        ("hf_alpha", "hi"),
        ("hm_psi", "hi"),
        ("zf_xiaoxiao", "cmn"),
        ("zm_yunyang", "cmn"),
    ],
)
def test_espeak_lang_for_voice(voice: str, expected: str) -> None:
    assert espeak_lang_for_voice(voice) == expected


def test_unknown_voice_falls_back_to_en_us() -> None:
    assert espeak_lang_for_voice("qx_unknown") == "en-us"
    assert espeak_lang_for_voice("") == "en-us"
    assert espeak_lang_for_voice("x") == "en-us"


def test_japanese_prefix_is_not_mapped() -> None:
    """Japanese ('j') must NOT resolve to a real JA code — espeak can't do kanji.

    It falls back to en-us rather than emitting broken 'ja' phonemes.
    """
    assert espeak_lang_for_voice("jf_alpha") == "en-us"
    # And no Japanese voice is exposed in the catalog at all.
    assert not any(v["id"].startswith("j") for v in VOICES)


# ---------- catalog integrity ----------


def test_every_voice_has_required_fields() -> None:
    for v in VOICES:
        assert set(v.keys()) >= {"id", "name", "gender"}
        assert v["gender"] in ("female", "male")
        assert v["id"] and v["name"]


def test_voice_ids_are_unique() -> None:
    assert len(VOICE_IDS) == len(set(VOICE_IDS))


def test_default_voice_is_valid() -> None:
    assert DEFAULT_VOICE in VOICE_IDS
    assert is_valid_voice(DEFAULT_VOICE)


def test_is_valid_voice() -> None:
    assert is_valid_voice("af_bella")
    assert not is_valid_voice("jf_alpha")  # excluded
    assert not is_valid_voice("nope")


def test_voice_catalog_enriches_with_lang() -> None:
    cat = voice_catalog()
    assert len(cat) == len(VOICES)
    for entry in cat:
        assert entry["lang"] == espeak_lang_for_voice(entry["id"])


def test_language_catalog_groups_all_voices_exactly_once() -> None:
    langs = language_catalog()
    grouped = [vid for lang in langs for vid in lang["voices"]]
    # Every catalog voice appears under exactly one language.
    assert sorted(grouped) == sorted(VOICE_IDS)
    assert len(grouped) == len(set(grouped))


def test_language_catalog_codes_match_voice_prefixes() -> None:
    for lang in language_catalog():
        for vid in lang["voices"]:
            assert espeak_lang_for_voice(vid) == lang["code"]


def test_mandarin_is_beta_others_are_not() -> None:
    by_code = {lang["code"]: lang for lang in LANGUAGES}
    assert by_code["cmn"]["beta"] is True
    for code in ("en-us", "en-gb", "es", "fr-fr", "it", "pt-br", "hi"):
        assert by_code[code]["beta"] is False


def test_every_language_has_at_least_one_voice() -> None:
    for lang in language_catalog():
        assert lang["voices"], f"language {lang['code']} has no voices"


# ---------- backward compatibility ----------

LEGACY_VOICES = [
    "af_bella",
    "af_sarah",
    "am_adam",
    "am_michael",
    "bf_emma",
    "bf_isabella",
    "bm_george",
    "bm_lewis",
]


def test_all_legacy_voices_still_present() -> None:
    """Audiobooks persist a voice ID; the original 8 must never disappear."""
    for v in LEGACY_VOICES:
        assert v in VOICE_IDS, f"legacy voice {v} dropped — breaks stored audiobooks"


# ---------- phonemizer regression guards (espeak only, no ONNX model) ----------


@pytest.fixture(scope="module")
def tokenizer():
    try:
        from kokoro_onnx.tokenizer import Tokenizer
    except Exception as e:  # pragma: no cover - env without espeak
        pytest.skip(f"kokoro_onnx tokenizer unavailable: {e}")
    try:
        return Tokenizer()
    except Exception as e:  # pragma: no cover
        pytest.skip(f"espeak-ng unavailable: {e}")


# espeak emits language-switch markers like "(en)...(ja)..." when it gives up.
_LANG_SWITCH = re.compile(r"\((en|[a-z]{2})\)")


@pytest.mark.parametrize(
    "lang,text",
    [
        ("en-us", "The quick brown fox."),
        ("es", "El zorro marrón rápido."),
        ("fr-fr", "Le renard brun rapide."),
        ("it", "La rapida volpe marrone."),
        ("pt-br", "A rápida raposa marrom."),
        ("hi", "तेज़ भूरी लोमड़ी।"),
        ("cmn", "敏捷的狐狸。"),
    ],
)
def test_shippable_languages_phonemize_cleanly(tokenizer, lang: str, text: str) -> None:
    phon = tokenizer.phonemize(text, lang)
    assert phon, f"{lang} produced no phonemes"
    assert not _LANG_SWITCH.search(phon), f"{lang} leaked lang-switch markers: {phon!r}"


def test_japanese_kanji_is_garbage_via_espeak(tokenizer) -> None:
    """Documents WHY Japanese is excluded: espeak mangles kanji.

    A kanji-bearing sentence triggers espeak's English-transliteration loop
    (lang-switch markers + absurd phoneme expansion). If a future espeak/misaki
    upgrade ever fixes this, THIS test will fail — a signal to re-enable JA.
    """
    phon = tokenizer.phonemize("今日はいい天気ですね。", "ja")
    assert _LANG_SWITCH.search(phon), (
        "Japanese kanji now phonemizes cleanly — re-evaluate enabling JA voices. "
        f"phonemes={phon!r}"
    )
