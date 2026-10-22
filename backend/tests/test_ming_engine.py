from __future__ import annotations

import asyncio
import logging

import numpy as np
import pytest
import pytest_asyncio
from ming_fakes import mark_installed, use_fake_worker, worker_requests
from pydantic import ValidationError

from app.services import ming_catalog as catalog
from app.services import ming_engine
from app.services.delivery import Delivery, delivery_from_record
from app.services.engine_errors import EngineNotInstalledError, EngineWorkerError
from app.services.engine_manager import EngineManager
from app.services.ming_engine import (
    MingEngine,
    effective_pace,
    select_task,
    speakable_keeping_tags,
)
from app.services.ming_installer import MingInstaller
from app.services.pronunciation import EMPTY_RULES, pronunciations
from app.services.voices import is_known_voice, is_kokoro_voice, resolve_voice

VOICE = "ming:US_James"
SPEECH_SAMPLES_24K = round(0.1 * 24000)


@pytest_asyncio.fixture
async def worker(monkeypatch, tmp_path):
    mark_installed()
    log_path = use_fake_worker(monkeypatch, tmp_path)
    MingEngine._lock = asyncio.Lock()
    MingEngine._reference_lock = asyncio.Lock()
    MingEngine._load_event = asyncio.Event()
    await MingEngine.shutdown()
    yield log_path
    await MingEngine.shutdown()
    MingEngine._last_request_time = 0.0


async def collect(text="Hello there.", voice=VOICE, speed=1.0, **kwargs):
    return [chunk async for chunk in MingEngine.generate(text, voice, speed, **kwargs)]


def synthesize_requests(log_path):
    return [
        request
        for request in worker_requests(log_path)
        if request["op"] == "synthesize"
    ]


def test_catalog_ships_the_full_roster_with_namespaced_ids():
    assert len(catalog.VOICES) == 117
    assert all(voice["id"].startswith("ming:") for voice in catalog.VOICES)
    assert catalog.DEFAULT_VOICE in catalog.VOICE_IDS
    assert len(catalog.VOICE_IDS) == 117


def test_english_voices_drop_their_region_prefix_and_chinese_voices_keep_names():
    by_id = {voice["id"]: voice for voice in catalog.VOICES}
    assert by_id["ming:US_Stella"]["name"] == "Stella"
    assert by_id["ming:UK_George"]["name"] == "George"
    assert by_id["ming:灵小安"]["name"] == "灵小安"
    assert by_id["ming:US_Stella"]["lang"] == "en"
    assert by_id["ming:灵小安"]["lang"] == "zh"


def test_voice_entries_carry_the_fields_the_app_reads():
    voice = next(v for v in catalog.VOICES if v["id"] == "ming:灵信远")
    assert set(voice) == {
        "id",
        "name",
        "gender",
        "lang",
        "description",
        "emotions",
        "custom",
    }
    assert voice["custom"] is False
    assert voice["emotions"] == [
        "neutral",
        "happy",
        "sad",
        "angry",
        "fearful",
        "disgusted",
        "surprised",
    ]
    plain = next(v for v in catalog.VOICES if v["id"] == "ming:灵小安")
    assert plain["emotions"] == []


def test_emotion_voices_are_invoked_by_their_neutral_name():
    record = catalog.roster_record("ming:灵信远")
    assert catalog.invocation_name(record) == "灵信远_中性"
    plain = catalog.roster_record("ming:US_James")
    assert catalog.invocation_name(plain) == "US_James"


def test_control_values_match_the_models_vocabulary():
    assert catalog.EMOTION_CONTROLS == {
        "neutral": "中性",
        "happy": "高兴",
        "sad": "悲伤",
        "angry": "愤怒",
        "fearful": "恐惧",
        "disgusted": "厌恶",
        "surprised": "惊讶",
    }
    assert catalog.PACE_CONTROLS == {"slow": "慢速", "normal": "中速", "fast": "快速"}
    assert catalog.PITCH_CONTROLS == {"low": "低", "normal": "中", "high": "高"}
    assert catalog.DIALECT_CONTROLS == {
        "cantonese": "cantonese",
        "sichuanese": "chuanyu dialect",
    }
    assert len(catalog.PARALINGUISTIC_TAGS) == 14
    assert "[Laughter]" in catalog.PARALINGUISTIC_TAGS


def test_catalog_pins_and_sizes():
    assert catalog.CODE_REVISION == "e999c39fa676722aaa9ea29b5aa19a90525b271f"
    assert catalog.MODEL_REVISION == "e5bd8da31ecf1b9276cdbdda821fa891068f1368"
    assert catalog.MODEL_SIZE_BYTES == 3_003_320_700
    assert catalog.SIZE_BYTES == (
        catalog.MODEL_SIZE_BYTES + catalog.RUNTIME_SIZE_BYTES + catalog.CODE_SIZE_BYTES
    )
    assert catalog.CODE_TARBALL_URL.endswith(f"/tar.gz/{catalog.CODE_REVISION}")
    assert (
        catalog.RUNTIME_PROGRESS_WEIGHT
        + catalog.CODE_PROGRESS_WEIGHT
        + catalog.MODEL_PROGRESS_WEIGHT
    ) == pytest.approx(1.0)


@pytest.mark.parametrize(
    ("lang", "expected"),
    [
        (None, None),
        ("", None),
        ("en-us", "en"),
        ("fr-fr", "fr"),
        ("cmn", "zh"),
        ("ja", "ja"),
        ("it", None),
        ("pt-br", None),
    ],
)
def test_language_codes_map_to_ming(lang, expected):
    assert catalog.ming_language(lang) == expected


def test_ming_voices_resolve_to_their_engine_and_language():
    spec = resolve_voice(VOICE)
    assert spec is not None
    assert (spec.engine, spec.lang, spec.is_blend) == ("ming", "en", False)
    assert resolve_voice("ming:灵小安").lang == "zh"
    assert is_known_voice(VOICE)
    assert not is_kokoro_voice(VOICE)


@pytest.mark.parametrize(
    "voice_id", ["US_James", "ming:", "ming:Nobody", "ming:custom:", "ming:custom:zz"]
)
def test_unknown_ming_ids_do_not_resolve(voice_id):
    assert resolve_voice(voice_id) is None


@pytest.mark.parametrize(
    ("delivery", "speed", "expected"),
    [
        (None, 1.0, ("TTS", None, None)),
        (Delivery(), 1.0, ("TTS", None, None)),
        (Delivery(emotion="neutral"), 1.0, ("TTS", None, None)),
        (None, 0.85, ("BASIC", {"speed": "慢速"}, None)),
        (None, 1.2, ("BASIC", {"speed": "快速"}, None)),
        (None, 1.1, ("TTS", None, None)),
        (Delivery(pace="normal"), 0.8, ("BASIC", {"speed": "中速"}, None)),
        (Delivery(pace="fast"), 0.8, ("BASIC", {"speed": "快速"}, None)),
        (
            Delivery(pitch="high"),
            1.0,
            ("BASIC", {"pitch": "高"}, None),
        ),
        (
            Delivery(pitch="low", pace="slow"),
            1.0,
            ("BASIC", {"speed": "慢速", "pitch": "低"}, None),
        ),
        (
            Delivery(pitch="low"),
            1.5,
            ("BASIC", {"speed": "快速", "pitch": "低"}, None),
        ),
        (
            Delivery(emotion="happy"),
            1.0,
            ("EMOTION", {"emotion": "高兴"}, None),
        ),
        (
            Delivery(emotion="sad", pace="fast", pitch="low"),
            1.0,
            (
                "FREEFORM",
                None,
                "Speak in a sad tone. Speak at a fast pace. Use a low pitch.",
            ),
        ),
        (
            Delivery(emotion="happy", pace="slow"),
            1.0,
            ("FREEFORM", None, "Speak in a happy tone. Speak at a slow pace."),
        ),
        (
            Delivery(emotion="angry", pitch="high"),
            1.0,
            ("FREEFORM", None, "Speak in an angry tone. Use a high pitch."),
        ),
        (
            Delivery(emotion="surprised"),
            0.8,
            ("FREEFORM", None, "Speak in a surprised tone. Speak at a slow pace."),
        ),
        (
            Delivery(emotion="happy", pace="normal", pitch="normal"),
            1.0,
            ("EMOTION", {"emotion": "高兴"}, None),
        ),
        (
            Delivery(emotion="neutral", pace="fast"),
            1.0,
            ("BASIC", {"speed": "快速"}, None),
        ),
        (
            Delivery(emotion="happy", style="warm"),
            1.0,
            ("FREEFORM", None, "Speak in a happy tone. warm"),
        ),
        (
            Delivery(style="warm", pace="normal", pitch="low"),
            1.0,
            ("FREEFORM", None, "Use a low pitch. warm"),
        ),
        (
            Delivery(dialect="sichuanese"),
            1.0,
            ("DIALECT", {"dialect": "chuanyu dialect"}, None),
        ),
        (
            Delivery(dialect="cantonese", pace="fast", pitch="high"),
            1.0,
            ("DIALECT", {"dialect": "cantonese"}, None),
        ),
        (
            Delivery(emotion="angry", dialect="cantonese"),
            1.0,
            ("DIALECT", {"dialect": "cantonese"}, None),
        ),
        (
            Delivery(style="whisper", dialect="sichuanese"),
            1.0,
            ("DIALECT", {"dialect": "chuanyu dialect"}, None),
        ),
        (
            Delivery(style="calm bedtime narrator"),
            1.0,
            ("FREEFORM", None, "calm bedtime narrator"),
        ),
        (
            Delivery(style="whisper", emotion="happy", pace="fast", pitch="high"),
            1.0,
            (
                "FREEFORM",
                None,
                "Speak in a happy tone. Speak at a fast pace. "
                "Use a high pitch. whisper",
            ),
        ),
    ],
)
def test_task_selection_follows_the_priority_order(delivery, speed, expected):
    choice = select_task(delivery, speed)
    assert (choice.task, choice.controls, choice.instruction) == expected


def test_only_the_dialect_task_omits_the_language():
    assert select_task(Delivery(dialect="cantonese"), 1.0).sends_language is False
    assert select_task(Delivery(emotion="happy"), 1.0).sends_language is True
    assert select_task(None, 1.0).sends_language is True


@pytest.mark.parametrize(
    ("speed", "expected"),
    [(0.5, "slow"), (0.85, "slow"), (0.86, None), (1.0, None), (1.19, None)]
    + [(1.2, "fast"), (2.0, "fast")],
)
def test_speed_maps_to_pace_only_at_the_extremes(speed, expected):
    assert effective_pace(None, speed) == expected


def test_an_explicit_pace_beats_the_speed_mapping():
    assert effective_pace(Delivery(pace="normal"), 0.5) == "normal"
    assert effective_pace(Delivery(pitch="low"), 0.5) == "slow"


@pytest.mark.parametrize(
    "payload",
    [
        {"emotion": "ecstatic"},
        {"pace": "ludicrous"},
        {"pitch": "shrill"},
        {"dialect": "klingon"},
        {"style": "x" * 301},
        {"style": "line\x00break"},
        {"unknown": "field"},
    ],
)
def test_delivery_rejects_invalid_values(payload):
    with pytest.raises(ValidationError):
        Delivery(**payload)


def test_delivery_accepts_the_documented_values_and_trims_style():
    delivery = Delivery(
        emotion="surprised",
        style="  warm and slow  ",
        pace="slow",
        pitch="high",
        dialect="sichuanese",
    )
    assert delivery.style == "warm and slow"
    assert delivery.to_record() == {
        "emotion": "surprised",
        "style": "warm and slow",
        "pace": "slow",
        "pitch": "high",
        "dialect": "sichuanese",
    }
    assert Delivery(style="x" * 300).style == "x" * 300


def test_blank_delivery_is_empty():
    assert Delivery(style="   ").is_empty
    assert Delivery().to_record() == {}
    assert delivery_from_record({"style": " "}) is None
    assert delivery_from_record({"emotion": "bogus"}) is None
    assert delivery_from_record("nope") is None
    assert delivery_from_record({"pace": "fast"}) == Delivery(pace="fast")


def test_pronunciation_rules_leave_paralinguistic_tags_alone():
    pronunciations.create(
        match="Laughter",
        replacement="haha",
        case_sensitive=False,
        whole_word=True,
        scope="global",
    )
    rules = pronunciations.rules_for(None)
    assert speakable_keeping_tags(rules, "Laughter is fun [Laughter] truly.") == (
        "haha is fun [Laughter] truly."
    )
    assert speakable_keeping_tags(EMPTY_RULES, "[Sigh]") == "[Sigh]"


def test_pronunciation_that_erases_a_segment_skips_it():
    pronunciations.create(
        match="Um",
        replacement="",
        case_sensitive=False,
        whole_word=True,
        scope="global",
    )
    assert speakable_keeping_tags(pronunciations.rules_for(None), "Um.") is None


@pytest.mark.asyncio
async def test_generate_starts_the_worker_when_it_is_not_loaded(worker):
    assert not MingEngine.is_loaded()
    assert len(await collect()) == 1
    assert MingEngine.is_loaded()


@pytest.mark.asyncio
async def test_generate_without_an_install_raises_not_installed():
    with pytest.raises(EngineNotInstalledError):
        await collect()


@pytest.mark.asyncio
async def test_initialize_refuses_when_not_installed():
    with pytest.raises(EngineNotInstalledError):
        await MingEngine.initialize()
    assert not MingEngine.is_loaded()


@pytest.mark.asyncio
async def test_generate_emits_24khz_float32_with_the_supertonic_pause(worker):
    await MingEngine.ensure_loaded()
    chunks = await collect(text="Hello there.")
    assert len(chunks) == 1
    assert chunks[0].dtype == np.float32
    assert chunks[0].ndim == 1
    pause = round(0.35 * 24000)
    assert len(chunks[0]) == pytest.approx(SPEECH_SAMPLES_24K + pause, abs=2)


@pytest.mark.asyncio
async def test_builtin_reference_is_generated_once_and_cached(worker):
    await MingEngine.ensure_loaded()
    await collect(text="First sentence here.")
    await collect(text="Second sentence here.")
    requests = worker_requests(worker)
    references = [r for r in requests if r["op"] == "ip_reference"]
    assert len(references) == 1
    assert references[0]["ip"] == "US_James"
    assert references[0]["language"] == "en"
    assert references[0]["seed"] == 1234
    assert references[0]["text"].startswith("Hello there. This is a short sample")
    directory = MingInstaller.references_dir()
    assert len(list(directory.glob("*.wav"))) == 1
    assert len(list(directory.glob("*.txt"))) == 1
    synth = synthesize_requests(worker)
    assert len(synth) == 2
    assert synth[0]["reference_wav"].startswith(str(directory))
    assert synth[0]["reference_text"] == references[0]["text"]
    assert synth[0]["task"] == "TTS"
    assert synth[0]["language"] == "en"
    assert synth[0]["seed"] == 1234


@pytest.mark.asyncio
async def test_missing_reference_files_are_regenerated(worker):
    await MingEngine.ensure_loaded()
    await collect(text="First sentence here.")
    for path in MingInstaller.references_dir().iterdir():
        path.unlink()
    await collect(text="Second sentence here.")
    references = [r for r in worker_requests(worker) if r["op"] == "ip_reference"]
    assert len(references) == 2


@pytest.mark.asyncio
async def test_emotion_voices_build_their_reference_from_the_neutral_name(worker):
    await MingEngine.ensure_loaded()
    await collect(text="你好。", voice="ming:灵信远")
    reference = next(r for r in worker_requests(worker) if r["op"] == "ip_reference")
    assert reference["ip"] == "灵信远_中性"
    assert reference["language"] == "zh"
    assert reference["text"] == catalog.REFERENCE_TEXTS["zh"]
    assert synthesize_requests(worker)[0]["language"] == "zh"


@pytest.mark.asyncio
async def test_delivery_picks_the_task_and_controls(worker):
    await MingEngine.ensure_loaded()
    await collect(text="Happy news today.", delivery=Delivery(emotion="happy"))
    await collect(text="Plain news today.", speed=0.8)
    await collect(text="Styled news today.", delivery=Delivery(style="gruff pirate"))
    await collect(text="Dialect news today.", delivery=Delivery(dialect="cantonese"))
    emotion, basic, style, dialect = synthesize_requests(worker)
    assert (emotion["task"], emotion["controls"]) == ("EMOTION", {"emotion": "高兴"})
    assert (basic["task"], basic["controls"]) == ("BASIC", {"speed": "慢速"})
    assert (style["task"], style["instruction"]) == ("FREEFORM", "gruff pirate")
    assert style["reference_wav"]
    assert dialect["task"] == "DIALECT"
    assert dialect["language"] is None


@pytest.mark.asyncio
async def test_expressive_delivery_sends_the_speaker_only_and_plain_keeps_the_text(
    worker,
):
    await MingEngine.ensure_loaded()
    await collect(text="Plain news today.")
    await collect(text="Happy news today.", delivery=Delivery(emotion="happy"))
    await collect(text="Styled news today.", delivery=Delivery(style="gruff"))
    await collect(text="Slow news today.", speed=0.8)
    await collect(text="Dialect news today.", delivery=Delivery(dialect="cantonese"))
    plain, happy, styled, slow, dialect = synthesize_requests(worker)
    reference = next(r for r in worker_requests(worker) if r["op"] == "ip_reference")
    assert plain["reference_text"] == reference["text"]
    assert plain["reference_wav"]
    for expressive in (happy, styled, slow, dialect):
        assert expressive["reference_text"] is None
        assert expressive["reference_wav"] == plain["reference_wav"]


@pytest.mark.asyncio
async def test_a_combined_delivery_becomes_one_composed_instruction(worker):
    await MingEngine.ensure_loaded()
    await collect(
        text="Combined news today.",
        delivery=Delivery(emotion="happy", pace="slow", style="like a game show host"),
    )
    request = synthesize_requests(worker)[0]
    assert request["task"] == "FREEFORM"
    assert request["controls"] is None
    assert request["instruction"] == (
        "Speak in a happy tone. Speak at a slow pace. like a game show host"
    )
    assert request["language"] == "en"


@pytest.mark.asyncio
async def test_a_runaway_segment_is_retried_once_with_the_next_seed_and_full_reference(
    worker,
):
    await MingEngine.ensure_loaded()
    chunks = await collect(
        text="A runaway segment.", delivery=Delivery(emotion="happy")
    )
    first, second = synthesize_requests(worker)
    reference = next(r for r in worker_requests(worker) if r["op"] == "ip_reference")
    assert (first["seed"], first["reference_text"]) == (1234, None)
    assert (second["seed"], second["reference_text"]) == (1235, reference["text"])
    assert second["task"] == first["task"] == "EMOTION"
    seconds = len(chunks[0]) / 24000
    assert seconds < 1.0


@pytest.mark.asyncio
async def test_a_segment_that_stays_runaway_is_truncated_to_the_limit(worker, caplog):
    caplog.set_level(logging.WARNING, logger="app.services.ming_engine")
    await MingEngine.ensure_loaded()
    chunks = await collect(text="An endless segment.")
    assert len(synthesize_requests(worker)) == 2
    limit = ming_engine.runaway_limit_seconds("An endless segment.", "en")
    assert limit == 4.0
    speech = len(chunks[0]) - round(0.35 * 24000)
    assert speech == pytest.approx(limit * 24000, abs=2)
    assert any(r.getMessage() == "ming.runaway_segment" for r in caplog.records)


@pytest.mark.parametrize(
    ("text", "language", "expected"),
    [
        ("Hi.", "en", 4.0),
        ("x" * 150, "en", 30.0),
        ("你" * 10, "zh", 6.0),
        ("你" * 5, "ja", 4.0),
        ("あ" * 20, "ja", 12.0),
        ("한" * 40, "ko", 24.0),
    ],
)
def test_the_runaway_limit_is_three_times_the_expected_duration_with_a_floor(
    text, language, expected
):
    assert ming_engine.runaway_limit_seconds(text, language) == pytest.approx(expected)


@pytest.mark.asyncio
async def test_language_is_explicit_when_supported_else_the_voices(worker):
    await MingEngine.ensure_loaded()
    await collect(text="Bonjour tout le monde.", lang="fr-fr")
    await collect(text="Ciao a tutti quanti.", lang="it")
    await collect(text="Hello again friends.", lang=None)
    languages = [r["language"] for r in synthesize_requests(worker)]
    assert languages == ["fr", "en", "en"]


@pytest.mark.asyncio
async def test_tags_survive_segmenting_and_reach_the_worker(worker):
    await MingEngine.ensure_loaded()
    await collect(text="That was funny [Laughter] truly. [Sigh] Anyway we go on.")
    texts = [r["text"] for r in synthesize_requests(worker)]
    assert "".join(texts).count("[Laughter]") == 1
    assert "".join(texts).count("[Sigh]") == 1


@pytest.mark.asyncio
async def test_generate_scales_pause_by_speed(worker):
    await MingEngine.ensure_loaded()
    chunks = await collect(text="Hello there.", speed=0.5, pause_scale=2.0)
    pause = round(0.35 * 2.0 / 0.5 * 24000)
    assert len(chunks[0]) == pytest.approx(SPEECH_SAMPLES_24K + pause, abs=2)


@pytest.mark.asyncio
async def test_a_failing_segment_is_reported_and_the_rest_continue(worker):
    await MingEngine.ensure_loaded()
    failed: list[str] = []
    chunks = await collect(
        text="This is bad news. This is fine now.", failed_segments=failed
    )
    assert failed == ["This is bad news."]
    assert len(chunks) == 1
    assert MingEngine.is_loaded()


@pytest.mark.asyncio
async def test_a_worker_crash_fails_the_segment_and_the_next_one_restarts_it(worker):
    await MingEngine.ensure_loaded()
    first = MingEngine._process
    failed: list[str] = []
    chunks = await collect(
        text="This will crash now. This one is fine.", failed_segments=failed
    )
    assert failed == ["This will crash now."]
    assert len(chunks) == 1
    assert MingEngine.is_loaded()
    assert MingEngine._process is not first
    assert first.returncode is not None


@pytest.mark.asyncio
async def test_worker_errors_never_reach_callers_as_text(worker):
    await MingEngine.ensure_loaded()
    with pytest.raises(EngineWorkerError) as raised:
        await MingEngine._render({"op": "synthesize", "text": "bad"})
    assert "/private/path" not in str(raised.value)


@pytest.mark.asyncio
async def test_stderr_is_drained_so_a_noisy_worker_never_blocks(worker, caplog):
    caplog.set_level(logging.DEBUG, logger="app.services.ming_engine")
    await MingEngine.ensure_loaded()
    chunks = await asyncio.wait_for(collect(text="Lots of noise here."), timeout=30)
    assert len(chunks) == 1
    await asyncio.sleep(0.2)
    assert any(r.getMessage() == "ming.worker_output" for r in caplog.records)


@pytest.mark.asyncio
async def test_ensure_loaded_is_shared_between_concurrent_callers(worker):
    await asyncio.gather(MingEngine.ensure_loaded(), MingEngine.ensure_loaded())
    assert MingEngine.is_loaded()
    assert not MingEngine.is_busy()


@pytest.mark.asyncio
async def test_a_worker_that_never_becomes_ready_fails_the_load(worker, monkeypatch):
    monkeypatch.setenv("FAKE_MING_FAIL_START", "1")
    with pytest.raises(EngineWorkerError):
        await MingEngine.ensure_loaded()
    assert not MingEngine.is_loaded()
    assert not MingEngine.is_busy()


@pytest.mark.asyncio
async def test_unload_kills_the_worker(worker):
    await MingEngine.ensure_loaded()
    process = MingEngine._process
    MingEngine.unload()
    assert not MingEngine.is_loaded()
    await process.wait()
    assert process.returncode is not None


@pytest.mark.asyncio
async def test_shutdown_reaps_the_worker(worker):
    await MingEngine.ensure_loaded()
    process = MingEngine._process
    await MingEngine.shutdown()
    assert process.returncode is not None
    assert not MingEngine.is_loaded()


@pytest.mark.asyncio
async def test_idle_watcher_unloads_after_the_idle_timeout(worker, monkeypatch):
    await MingEngine.ensure_loaded()
    process = MingEngine._process
    MingEngine._last_request_time = 1.0
    sleeps = []

    async def fast_sleep(seconds):
        sleeps.append(seconds)
        if len(sleeps) > 1:
            raise asyncio.CancelledError

    monkeypatch.setattr(ming_engine.asyncio, "sleep", fast_sleep)
    monkeypatch.setattr(
        ming_engine.time, "monotonic", lambda: 1.0 + MingEngine._IDLE_TIMEOUT + 1
    )
    with pytest.raises(asyncio.CancelledError):
        await MingEngine.idle_watcher()
    monkeypatch.undo()
    assert not MingEngine.is_loaded()
    await process.wait()


@pytest.mark.asyncio
async def test_idle_watcher_leaves_a_busy_worker_alone(worker, monkeypatch):
    await MingEngine.ensure_loaded()
    MingEngine._last_request_time = 1.0
    MingEngine._active_generations = 1
    sleeps = []

    async def fast_sleep(seconds):
        sleeps.append(seconds)
        if len(sleeps) > 1:
            raise asyncio.CancelledError

    monkeypatch.setattr(ming_engine.asyncio, "sleep", fast_sleep)
    monkeypatch.setattr(
        ming_engine.time, "monotonic", lambda: 1.0 + MingEngine._IDLE_TIMEOUT + 1
    )
    try:
        with pytest.raises(asyncio.CancelledError):
            await MingEngine.idle_watcher()
        assert MingEngine.is_loaded()
    finally:
        MingEngine._active_generations = 0


@pytest.mark.asyncio
async def test_engine_is_busy_only_while_generating(worker):
    await MingEngine.ensure_loaded()
    assert not MingEngine.is_busy()
    stream = MingEngine.generate("One here. Two here.", VOICE, 1.0)
    await anext(stream)
    assert MingEngine.is_busy()
    await stream.aclose()
    assert not MingEngine.is_busy()


@pytest.mark.asyncio
async def test_cancelling_a_request_keeps_the_worker_and_discards_the_late_reply(
    worker, monkeypatch
):
    monkeypatch.setenv("FAKE_MING_SLOW_SECONDS", "1.0")
    await MingEngine.shutdown()
    await MingEngine.ensure_loaded()
    process = MingEngine._process
    task = asyncio.create_task(MingEngine._render({"op": "synthesize", "text": "slow"}))
    await asyncio.sleep(0.4)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert MingEngine.is_loaded()
    assert MingEngine._process is process
    audio = await MingEngine._render({"op": "synthesize", "text": "fresh"})
    assert audio.size == round(0.1 * 44100)
    assert MingEngine._process is process
    assert MingEngine._unanswered == {}
    assert process.returncode is None


@pytest.mark.asyncio
async def test_a_request_that_times_out_kills_the_worker(worker, monkeypatch):
    monkeypatch.setattr(ming_engine, "REQUEST_TIMEOUT_SECONDS", 0.3)
    await MingEngine.ensure_loaded()
    process = MingEngine._process
    with pytest.raises(EngineWorkerError):
        await MingEngine._render({"op": "synthesize", "text": "slow"})
    assert not MingEngine.is_loaded()
    await process.wait()


@pytest.mark.asyncio
async def test_a_reply_nobody_asked_for_is_a_protocol_error(worker):
    await MingEngine.ensure_loaded()
    process = MingEngine._process
    with pytest.raises(EngineWorkerError):
        await MingEngine._render({"op": "synthesize", "text": "rogue"})
    assert not MingEngine.is_loaded()
    await process.wait()


@pytest.mark.asyncio
async def test_an_unexpected_read_failure_unloads_the_worker(worker, monkeypatch):
    await MingEngine.ensure_loaded()
    process = MingEngine._process

    async def broken_read(*arguments):
        raise ConnectionResetError("pipe vanished")

    monkeypatch.setattr(process.stdout, "readline", broken_read)
    with pytest.raises(EngineWorkerError):
        await MingEngine._render({"op": "synthesize", "text": "hello"})
    assert not MingEngine.is_loaded()


@pytest.mark.asyncio
async def test_every_request_carries_an_id_the_worker_echoes(worker):
    await MingEngine.ensure_loaded()
    await MingEngine._render({"op": "synthesize", "text": "one"})
    await MingEngine._render({"op": "synthesize", "text": "two"})
    ids = [r["id"] for r in worker_requests(worker)]
    assert len(ids) == 2
    assert ids[0] != ids[1]


@pytest.mark.asyncio
async def test_a_cold_start_is_not_loaded_until_the_worker_is_ready(
    worker, monkeypatch
):
    monkeypatch.setenv("FAKE_MING_LOAD_DELAY", "1.0")
    first = asyncio.create_task(MingEngine.ensure_loaded())
    await asyncio.sleep(0.4)
    assert MingEngine.is_busy()
    assert not MingEngine.is_loaded()
    assert MingEngine._process is None
    second = asyncio.create_task(
        MingEngine._render({"op": "synthesize", "text": "early"})
    )
    waiter = asyncio.create_task(MingEngine.ensure_loaded())
    await asyncio.sleep(0.1)
    assert not waiter.done()
    await asyncio.gather(first, waiter)
    assert MingEngine.is_loaded()
    with pytest.raises(EngineWorkerError):
        await second


@pytest.mark.asyncio
async def test_concurrent_callers_during_a_cold_start_all_succeed(worker, monkeypatch):
    monkeypatch.setenv("FAKE_MING_LOAD_DELAY", "0.8")
    lock = MingEngine._lock

    async def call(text):
        await MingEngine.ensure_loaded()
        return await MingEngine._render({"op": "synthesize", "text": text})

    first = asyncio.create_task(call("first"))
    await asyncio.sleep(0.3)
    second = await call("second")
    assert second.size == (await first).size
    assert MingEngine._lock is lock


@pytest.mark.asyncio
async def test_cancelling_the_load_kills_the_starting_worker_and_allows_a_retry(
    worker, monkeypatch
):
    monkeypatch.setenv("FAKE_MING_LOAD_DELAY", "1.0")
    task = asyncio.create_task(MingEngine.ensure_loaded())
    await asyncio.sleep(0.4)
    starting = MingEngine._starting
    assert starting is not None
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert not MingEngine.is_loaded()
    assert not MingEngine.is_busy()
    assert MingEngine._starting is None
    await starting.wait()
    monkeypatch.setenv("FAKE_MING_LOAD_DELAY", "0")
    await MingEngine.ensure_loaded()
    audio = await MingEngine._render({"op": "synthesize", "text": "after"})
    assert audio.size > 0


@pytest.mark.asyncio
async def test_design_retries_seeds_until_the_audio_is_plausible(worker, monkeypatch):
    monkeypatch.setenv("FAKE_MING_GOOD_SEED", "1236")
    await MingEngine.shutdown()
    samples = await MingEngine.design_sample(
        "a warm older woman", "en", "Hello there. This is a short sample."
    )
    assert samples.size == 88200
    seeds = [r["seed"] for r in worker_requests(worker) if r["op"] == "design"]
    assert seeds == [1234, 1235, 1236]
    design = next(r for r in worker_requests(worker) if r["op"] == "design")
    assert design["description"] == "a warm older woman"
    assert design["language"] == "en"
    assert not MingEngine.is_busy()


@pytest.mark.asyncio
async def test_design_fails_after_three_implausible_attempts(worker, monkeypatch):
    monkeypatch.setenv("FAKE_MING_GOOD_SEED", "9999")
    await MingEngine.shutdown()
    with pytest.raises(EngineWorkerError) as raised:
        await MingEngine.design_sample("anything", "en", "Hello there friend.")
    assert str(raised.value) == ming_engine.DESIGN_FAILED_MESSAGE
    seeds = [r["seed"] for r in worker_requests(worker) if r["op"] == "design"]
    assert seeds == [1234, 1235, 1236]


@pytest.mark.asyncio
async def test_manager_dispatches_ming_voices_with_delivery(worker):
    await EngineManager.ensure_loaded("ming")
    chunks = [
        chunk
        async for chunk in EngineManager.generate(
            "Hello there.", VOICE, 1.0, delivery=Delivery(emotion="happy")
        )
    ]
    assert len(chunks) == 1
    assert synthesize_requests(worker)[0]["task"] == "EMOTION"


@pytest.mark.asyncio
async def test_other_engines_ignore_delivery():
    from unittest.mock import patch

    from app.services.tts import TTSEngine

    seen = {}

    async def fake_generate(*args, **kwargs):
        seen.update(kwargs)
        yield np.zeros(10, dtype=np.float32)

    with patch.object(TTSEngine, "generate", side_effect=fake_generate):
        [
            chunk
            async for chunk in EngineManager.generate(
                "Hello.", "af_bella", 1.0, delivery=Delivery(emotion="happy")
            )
        ]
    assert "delivery" not in seen
