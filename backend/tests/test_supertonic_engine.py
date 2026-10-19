from __future__ import annotations

import asyncio
import concurrent.futures
import threading
from unittest.mock import patch

import numpy as np
import pytest
from fastapi.testclient import TestClient
from supertonic import config as package_config
from supertonic_fakes import FakeSupertonic, mark_installed

from app.main import app
from app.services import supertonic_catalog as catalog
from app.services import supertonic_engine
from app.services.engine_errors import EngineNotInstalledError
from app.services.pronunciation import pronunciations
from app.services.supertonic_engine import SupertonicEngine, clamp_speed, resample
from app.services.supertonic_installer import SupertonicInstaller
from app.services.voices import (
    VoiceSpec,
    is_known_voice,
    is_kokoro_voice,
    resolve_voice,
    voice_spec,
)


@pytest.fixture
def engine():
    SupertonicEngine.unload()
    fake = FakeSupertonic()
    SupertonicEngine._model = fake
    SupertonicEngine._executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
    yield fake
    SupertonicEngine.unload()


async def collect(voice="supertonic:M1", text="Hello there.", speed=1.0, **kwargs):
    return [
        chunk async for chunk in SupertonicEngine.generate(text, voice, speed, **kwargs)
    ]


def test_catalog_pins_match_the_installed_package():
    config = package_config.MODEL_CONFIGS[catalog.MODEL_NAME]
    assert catalog.MODEL_REPO == config["repo"]
    assert catalog.MODEL_REVISION == config["revision"]
    assert list(catalog.LANGUAGES) == package_config.SUPPORTED_LANGUAGES
    assert catalog.UNKNOWN_LANGUAGE == package_config.UNKNOWN_LANGUAGE


def test_voice_ids_are_namespaced():
    assert all(voice_id.startswith("supertonic:") for voice_id in catalog.VOICE_IDS)
    assert len(catalog.VOICE_IDS) == 10
    assert catalog.style_name("supertonic:F3") == "F3"


def test_supertonic_voices_resolve_to_their_engine():
    spec = resolve_voice("supertonic:M1")
    assert spec is not None
    assert spec.engine == "supertonic"
    assert not spec.is_blend
    assert is_known_voice("supertonic:M1")
    assert not is_kokoro_voice("supertonic:M1")


@pytest.mark.parametrize("voice_id", ["M1", "F1", "supertonic:M9", "supertonic:"])
def test_bare_or_unknown_supertonic_ids_cannot_collide_with_kokoro(voice_id):
    assert resolve_voice(voice_id) is None


def test_kokoro_voices_keep_the_kokoro_engine():
    assert voice_spec("af_bella").engine == "kokoro"
    assert is_kokoro_voice("af_bella")


def test_blends_reject_supertonic_components():
    response = TestClient(app).post(
        "/voices/blends",
        json={
            "name": "Mixed",
            "components": [
                {"voice": "supertonic:M1", "weight": 1},
                {"voice": "af_bella", "weight": 1},
            ],
        },
    )
    assert response.status_code == 422


@pytest.mark.parametrize(
    ("lang", "expected"),
    [
        (None, "na"),
        ("", "na"),
        ("en-us", "en"),
        ("en-gb", "en"),
        ("fr-fr", "fr"),
        ("pt-br", "pt"),
        ("es", "es"),
        ("cmn", "na"),
    ],
)
def test_language_codes_map_to_supertonic(lang, expected):
    assert catalog.supertonic_language(lang) == expected


def test_speed_is_clamped_to_the_models_range():
    assert clamp_speed(0.5) == package_config.MIN_SPEED
    assert clamp_speed(4.0) == package_config.MAX_SPEED
    assert clamp_speed(1.2) == 1.2


def test_resample_is_identity_at_the_same_rate():
    audio = np.linspace(-1, 1, 100, dtype=np.float32)
    assert resample(audio, 24000, 24000) is audio


@pytest.mark.parametrize(("source", "target"), [(44100, 24000), (16000, 24000)])
def test_resample_changes_length_and_keeps_pitch(source, target):
    seconds = 0.5
    time = np.arange(int(source * seconds)) / source
    tone = np.sin(2 * np.pi * 440 * time).astype(np.float32)
    out = resample(tone, source, target)
    assert out.dtype == np.float32
    assert len(out) == round(len(tone) * target / source)
    peak_bin = int(np.argmax(np.abs(np.fft.rfft(out))))
    assert peak_bin / (len(out) / target) == pytest.approx(440, abs=3)
    assert np.max(np.abs(out)) == pytest.approx(1.0, abs=0.05)


def test_resample_handles_empty_audio():
    assert resample(np.zeros(0, dtype=np.float32), 44100, 24000).size == 0


@pytest.mark.asyncio
async def test_generate_emits_24khz_float32_with_pause(engine):
    chunks = await collect(text="Hello there.")
    assert len(chunks) == 1
    assert chunks[0].dtype == np.float32
    assert chunks[0].ndim == 1
    speech = round(0.1 * 24000)
    pause = round(0.35 * 24000)
    assert len(chunks[0]) == pytest.approx(speech + pause, abs=2)
    assert engine.calls[0]["style"] == "style-M1"


@pytest.mark.asyncio
async def test_generate_scales_pause_and_clamps_speed(engine):
    chunks = await collect(text="Hello there.", speed=0.5, pause_scale=2.0)
    assert engine.calls[0]["speed"] == package_config.MIN_SPEED
    pause = round(0.35 * 2.0 / package_config.MIN_SPEED * 24000)
    assert len(chunks[0]) == pytest.approx(2400 + pause, abs=2)


@pytest.mark.asyncio
async def test_generate_passes_the_mapped_language(engine):
    await collect(text="Bonjour.", lang="fr-fr")
    await collect(text="Hello.")
    assert [call["lang"] for call in engine.calls] == ["fr", "na"]


@pytest.mark.asyncio
async def test_generate_detects_the_language_when_none_is_given(engine):
    await collect(text="The cat and the dog went to the park.")
    await collect(text="안녕하세요 여러분 반갑습니다.")
    await collect(text="Le chat et le chien vont au parc.")
    assert [call["lang"] for call in engine.calls] == ["en", "ko", "na"]


@pytest.mark.asyncio
async def test_an_explicit_language_beats_detection(engine):
    await collect(text="The cat and the dog went to the park.", lang="fr-fr")
    assert [call["lang"] for call in engine.calls] == ["fr"]


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("The weather is nice and we are going to the beach.", "en"),
        ("Hola, esto es una prueba de voz.", "na"),
        ("今日はいい天気ですね。", "ja"),
        ("漢字漢字", "na"),
        ("Привет, как дела у вас сегодня?", "ru"),
        ("Привіт, як справи сьогодні, друже?", "uk"),
        ("مرحبا بكم في هذا الاختبار", "ar"),
        ("नमस्ते दोस्तों आप कैसे हैं", "hi"),
        ("Γειά σου κόσμε, τι κάνεις", "el"),
        ("12345 !!!", "na"),
        ("", "na"),
    ],
)
def test_detect_language_reads_the_dominant_script(text, expected):
    assert catalog.detect_language(text) == expected


@pytest.mark.asyncio
async def test_generate_survives_an_unload_mid_run(engine):
    chunks = []
    async for chunk in SupertonicEngine.generate(
        "One sentence here. Two sentences here. Three sentences here.",
        "supertonic:M1",
        1.0,
    ):
        chunks.append(chunk)
        if len(chunks) == 1:
            SupertonicEngine._model = None
            SupertonicEngine._executor = None
    assert len(chunks) == 3


@pytest.mark.asyncio
async def test_engine_is_busy_only_while_generating(engine):
    assert not SupertonicEngine.is_busy()
    stream = SupertonicEngine.generate("One here. Two here.", "supertonic:M1", 1.0)
    await anext(stream)
    assert SupertonicEngine.is_busy()
    await stream.aclose()
    assert not SupertonicEngine.is_busy()


@pytest.mark.asyncio
async def test_engine_is_busy_while_loading(monkeypatch):
    SupertonicEngine.unload()
    release = threading.Event()
    started = asyncio.Event()
    loop = asyncio.get_running_loop()

    def slow_initialize():
        loop.call_soon_threadsafe(started.set)
        release.wait(5)

    monkeypatch.setattr(SupertonicEngine, "initialize", slow_initialize)
    task = asyncio.create_task(SupertonicEngine.ensure_loaded())
    await started.wait()
    assert SupertonicEngine.is_busy()
    release.set()
    await task
    assert not SupertonicEngine.is_busy()


@pytest.mark.asyncio
async def test_generate_applies_pronunciation_rules(engine):
    pronunciations.create(
        match="GIF",
        replacement="jif",
        case_sensitive=False,
        whole_word=True,
        scope="global",
    )
    await collect(text="A GIF is fun.", pronunciation=pronunciations.rules_for(None))
    assert engine.calls[0]["text"] == "A jif is fun."


@pytest.mark.asyncio
async def test_generate_drops_characters_the_model_cannot_read(engine):
    SupertonicEngine._model.model.text_processor.unsupported = "~"
    await collect(text="Hello~ there.")
    assert engine.calls[0]["text"] == "Hello there."


@pytest.mark.asyncio
async def test_generate_skips_segments_with_nothing_readable(engine):
    SupertonicEngine._model.model.text_processor.unsupported = "~"
    failed: list[str] = []
    chunks = await collect(text="~~~", failed_segments=failed)
    assert chunks == []
    assert failed == []


@pytest.mark.asyncio
async def test_generate_reports_failed_segments_and_continues(engine):
    engine.fail_on = "bad"
    failed: list[str] = []
    chunks = await collect(text="This is bad. This is fine.", failed_segments=failed)
    assert failed == ["This is bad."]
    assert len(chunks) == 1


@pytest.mark.asyncio
async def test_generate_requires_a_loaded_model():
    SupertonicEngine.unload()
    with pytest.raises(RuntimeError):
        await collect()


def test_native_rate_is_resampled_to_the_pipeline_rate(engine):
    out = SupertonicEngine._synthesize(engine, "Hello.", "supertonic:M1", 1.0, "en")
    assert len(out) == pytest.approx(2400, abs=2)


def test_voice_styles_are_cached(engine):
    first = SupertonicEngine._style(engine, "supertonic:M1")
    assert SupertonicEngine._style(engine, "supertonic:M1") is first
    for voice_id in sorted(catalog.VOICE_IDS):
        SupertonicEngine._style(engine, voice_id)
    assert len(SupertonicEngine._styles) <= SupertonicEngine._MAX_STYLES


def test_initialize_refuses_when_not_installed():
    SupertonicEngine.unload()
    with pytest.raises(EngineNotInstalledError):
        SupertonicEngine.initialize()
    assert not SupertonicEngine.is_loaded()


@pytest.mark.asyncio
async def test_ensure_loaded_builds_the_model_from_the_installed_directory():
    SupertonicEngine.unload()
    mark_installed(SupertonicInstaller.model_dir())
    built = {}

    def fake_tts(**kwargs):
        built.update(kwargs)
        return FakeSupertonic()

    with patch.object(supertonic_engine, "TTS", side_effect=fake_tts):
        await asyncio.gather(
            SupertonicEngine.ensure_loaded(), SupertonicEngine.ensure_loaded()
        )
    try:
        assert SupertonicEngine.is_loaded()
        assert built["model_dir"] == SupertonicInstaller.model_dir()
        assert built["auto_download"] is False
        assert built["model"] == catalog.MODEL_NAME
    finally:
        SupertonicEngine.unload()


def test_unload_drops_the_model_and_styles(engine):
    SupertonicEngine._style(engine, "supertonic:M1")
    SupertonicEngine.unload()
    assert not SupertonicEngine.is_loaded()
    assert SupertonicEngine._executor is None
    assert not SupertonicEngine._styles


@pytest.mark.asyncio
async def test_idle_watcher_unloads_after_the_idle_timeout(engine, monkeypatch):
    SupertonicEngine._last_request_time = 1.0
    sleeps = []

    async def fast_sleep(seconds):
        sleeps.append(seconds)
        if len(sleeps) > 1:
            raise asyncio.CancelledError

    monkeypatch.setattr(supertonic_engine.asyncio, "sleep", fast_sleep)
    with pytest.raises(asyncio.CancelledError):
        await SupertonicEngine.idle_watcher()
    assert not SupertonicEngine.is_loaded()


def test_voice_spec_is_hashable_with_engine():
    spec = VoiceSpec(
        "supertonic:M1", "", (("supertonic:M1", 1.0),), engine="supertonic"
    )
    assert hash(spec) == hash(voice_spec("supertonic:M1"))
