from __future__ import annotations

import json
from collections.abc import Iterator
from pathlib import Path
from unittest.mock import AsyncMock, patch

import numpy as np
import pytest
import soundfile as sf
from fastapi.testclient import TestClient
from ming_fakes import mark_installed, tone_samples, wav_bytes

from app.api.public_app import create_public_app
from app.main import app
from app.services import ming_voices as voice_module
from app.services.delivery import Delivery
from app.services.engine_errors import EngineNotInstalledError, EngineWorkerError
from app.services.engine_manager import EngineManager
from app.services.ming_catalog import CAPABILITIES, NOTICE, PARALINGUISTIC_TAGS
from app.services.ming_engine import MingEngine, Reference
from app.services.ming_voices import (
    MAX_CUSTOM_VOICES,
    VoiceLimitError,
    VoiceValidationError,
    ming_voices,
    prepare_clone_audio,
)
from app.services.public_voices import voice_list
from app.services.speech_relay import speech_relay
from app.services.voices import resolve_voice

client = TestClient(app)
API_KEY = "test-local-api-key-0123456789abcdef"
AUTH = {"Authorization": f"Bearer {API_KEY}"}
SAMPLE_TEXT = "Hello there. This is a short sample of how I sound when I read aloud."


@pytest.fixture(autouse=True)
def clean_relay() -> Iterator[None]:
    speech_relay.close_all()
    yield
    speech_relay.close_all()


@pytest.fixture
def installed():
    mark_installed()


def engine_entry(body, engine_id="ming"):
    return next(entry for entry in body["engines"] if entry["id"] == engine_id)


def clone_files(seconds: float = 4.0, **kwargs):
    return {"file": ("voice.wav", wav_bytes(seconds, **kwargs), "audio/wav")}


def clone_form(**overrides):
    form = {"name": "Narrator", "language": "en", "transcript": "Hello there."}
    form.update(overrides)
    return form


def test_engine_entry_has_the_documented_shape():
    entry = engine_entry(client.get("/engine").json())
    assert set(entry) == {
        "id",
        "name",
        "installed",
        "downloading",
        "progress",
        "size_bytes",
        "license",
        "languages",
        "voices",
        "error",
        "notice",
        "capabilities",
        "tags",
    }
    assert entry["name"] == "Ming"
    assert entry["installed"] is False
    assert entry["license"] == "MIT"
    assert entry["languages"] == ["en", "zh", "ja", "ko", "de", "fr", "es"]
    assert entry["size_bytes"] > 3_600_000_000
    assert entry["notice"] == NOTICE
    assert entry["notice"] == (
        "Renders slower than real time on most Macs. Best for audiobooks and exports."
    )
    assert entry["capabilities"] == list(CAPABILITIES)
    assert entry["capabilities"] == [
        "emotion",
        "style",
        "pace",
        "pitch",
        "dialect",
        "design",
        "clone",
        "tags",
    ]
    assert entry["tags"] == list(PARALINGUISTIC_TAGS)
    assert len(entry["voices"]) == 117
    assert set(entry["voices"][0]) == {
        "id",
        "name",
        "gender",
        "lang",
        "description",
        "emotions",
        "custom",
    }


def test_engine_entry_lists_custom_voices_after_the_builtin_ones(installed):
    voice = ming_voices.create(
        name="Mine",
        language="en",
        kind="cloned",
        description="",
        transcript="Hello.",
        samples=tone_samples(4),
    )
    voices = engine_entry(client.get("/engine").json())["voices"]
    assert voices[-1] == {
        "id": voice.id,
        "name": "Mine",
        "gender": "unknown",
        "lang": "en",
        "description": "",
        "emotions": [],
        "custom": True,
        "kind": "cloned",
    }
    assert [v["custom"] for v in voices[:-1]] == [False] * 117


def test_install_endpoint_starts_the_ming_install():
    from app.services.ming_installer import MingInstaller

    with patch.object(MingInstaller, "start") as start:
        response = client.post("/engine/ming/install")
    assert response.status_code == 202
    assert response.json()["id"] == "ming"
    start.assert_called_once_with()


def test_uninstall_removes_ming_and_stops_the_worker(installed):
    from app.services.ming_installer import MingInstaller

    with patch("app.services.engine_manager.MingEngine.unload") as unload:
        response = client.delete("/engine/ming")
    assert response.status_code == 200
    assert response.json()["installed"] is False
    unload.assert_called_once_with()
    assert not MingInstaller.install_dir().exists()


def test_uninstall_conflicts_while_the_worker_is_busy(installed):
    with patch.object(MingEngine, "is_busy", return_value=True):
        response = client.delete("/engine/ming")
    assert response.status_code == 409


def test_select_engine_requires_ming_to_be_installed(installed):
    assert client.post("/engine", json={"engine": "ming"}).status_code == 200


def test_select_engine_reports_ming_missing():
    response = client.post("/engine", json={"engine": "ming"})
    assert response.status_code == 409
    assert "not installed" in response.json()["detail"]


def test_manager_voices_and_defaults_for_ming(installed):
    assert EngineManager.default_voice("ming") == "ming:US_Stella"
    voices = EngineManager.voices("ming")
    assert "ming:US_James" in voices
    assert len(voices) == 117
    assert EngineManager.is_installed("ming")


def test_voice_endpoints_conflict_when_ming_is_not_installed():
    design = client.post(
        "/engine/ming/voices/design",
        json={"name": "A", "description": "x", "language": "en"},
    )
    clone = client.post(
        "/engine/ming/voices/clone", data=clone_form(), files=clone_files()
    )
    responses = [
        client.get("/engine/ming/voices"),
        design,
        clone,
        client.delete("/engine/ming/voices/ming:custom:" + "a" * 32),
        client.get("/engine/ming/voices/ming:US_James/sample"),
    ]
    assert [response.status_code for response in responses] == [409] * 5
    assert all(
        "Ming is not installed" in response.json()["detail"] for response in responses
    )


def test_list_voices_returns_builtin_and_custom_entries(installed):
    body = client.get("/engine/ming/voices").json()
    assert len(body["voices"]) == 117
    assert body["voices"][0]["id"].startswith("ming:")


def test_design_creates_a_custom_voice_from_the_generated_sample(installed):
    design = AsyncMock(return_value=tone_samples(2.0))
    with patch.object(MingEngine, "design_sample", design):
        response = client.post(
            "/engine/ming/voices/design",
            json={
                "name": "Grandma",
                "description": "a warm older woman",
                "language": "en",
            },
        )
    assert response.status_code == 201
    body = response.json()
    assert body["id"].startswith("ming:custom:")
    assert body["name"] == "Grandma"
    assert body["custom"] is True
    assert body["kind"] == "designed"
    design.assert_awaited_once_with("a warm older woman", "en", SAMPLE_TEXT)
    stored = ming_voices.get(body["id"])
    assert stored.transcript == SAMPLE_TEXT
    info = sf.info(str(ming_voices.wav_path(body["id"])))
    assert info.samplerate == 44100
    assert info.channels == 1
    spec = resolve_voice(body["id"])
    assert spec.engine == "ming"
    assert spec.lang == "en"


def test_design_uses_the_supplied_sample_text(installed):
    design = AsyncMock(return_value=tone_samples(2.0))
    with patch.object(MingEngine, "design_sample", design):
        response = client.post(
            "/engine/ming/voices/design",
            json={
                "name": "Chinese",
                "description": "a calm man",
                "language": "zh",
                "sample_text": "你好，世界。",
            },
        )
    assert response.status_code == 201
    design.assert_awaited_once_with("a calm man", "zh", "你好，世界。")
    assert ming_voices.get(response.json()["id"]).transcript == "你好，世界。"


@pytest.mark.parametrize(
    "payload",
    [
        {"name": "", "description": "x", "language": "en"},
        {"name": "A", "description": "", "language": "en"},
        {"name": "A", "description": "x" * 301, "language": "en"},
        {"name": "A", "description": "x", "language": "xx"},
        {"name": "A", "description": "x", "language": "en", "sample_text": "y" * 501},
        {"name": "A\x00B", "description": "x", "language": "en"},
    ],
)
def test_design_rejects_invalid_requests(installed, payload):
    design = AsyncMock(return_value=tone_samples(2.0))
    with patch.object(MingEngine, "design_sample", design):
        response = client.post("/engine/ming/voices/design", json=payload)
    assert response.status_code == 422
    design.assert_not_awaited()


def test_design_failure_is_a_clean_500(installed):
    failing = AsyncMock(side_effect=EngineWorkerError("Try describing it differently."))
    with patch.object(MingEngine, "design_sample", failing):
        response = client.post(
            "/engine/ming/voices/design",
            json={"name": "A", "description": "x", "language": "en"},
        )
    assert response.status_code == 500
    assert response.json()["detail"] == "Try describing it differently."
    assert ming_voices.list() == []


def test_clone_stores_a_resampled_mono_clip(installed):
    response = client.post(
        "/engine/ming/voices/clone",
        data=clone_form(),
        files=clone_files(4.0, rate=22050, channels=2),
    )
    assert response.status_code == 201
    body = response.json()
    assert body["kind"] == "cloned"
    assert body["name"] == "Narrator"
    info = sf.info(str(ming_voices.wav_path(body["id"])))
    assert (info.samplerate, info.channels) == (44100, 1)
    assert info.duration == pytest.approx(4.0, abs=0.05)
    assert ming_voices.get(body["id"]).transcript == "Hello there."


@pytest.mark.parametrize(
    ("form", "files"),
    [
        (clone_form(), clone_files(2.0)),
        (clone_form(), clone_files(31.0)),
        (clone_form(transcript=""), clone_files()),
        (clone_form(transcript="x" * 501), clone_files()),
        (clone_form(language="xx"), clone_files()),
        (clone_form(name=""), clone_files()),
        (clone_form(), {"file": ("voice.wav", b"not audio at all", "audio/wav")}),
    ],
)
def test_clone_rejects_invalid_uploads(installed, form, files):
    response = client.post("/engine/ming/voices/clone", data=form, files=files)
    assert response.status_code == 422
    assert ming_voices.list() == []


def test_clone_requires_a_file_and_a_transcript(installed):
    missing_file = client.post("/engine/ming/voices/clone", data=clone_form())
    assert missing_file.status_code == 422
    missing_transcript = client.post(
        "/engine/ming/voices/clone",
        data={"name": "A", "language": "en"},
        files=clone_files(),
    )
    assert missing_transcript.status_code == 422


def test_delete_removes_the_voice_and_its_clip(installed):
    created = client.post(
        "/engine/ming/voices/clone", data=clone_form(), files=clone_files()
    ).json()
    path = ming_voices.wav_path(created["id"])
    assert path.is_file()
    response = client.delete(f"/engine/ming/voices/{created['id']}")
    assert response.status_code == 200
    assert response.json() == {"status": "deleted", "id": created["id"]}
    assert not path.exists()
    assert ming_voices.get(created["id"]) is None
    assert client.delete(f"/engine/ming/voices/{created['id']}").status_code == 404


def test_delete_rejects_builtin_and_malformed_ids(installed):
    assert client.delete("/engine/ming/voices/ming:US_James").status_code == 400
    assert client.delete("/engine/ming/voices/nonsense").status_code == 400


def test_sample_streams_a_custom_voices_clip(installed):
    created = client.post(
        "/engine/ming/voices/clone", data=clone_form(), files=clone_files()
    ).json()
    response = client.get(f"/engine/ming/voices/{created['id']}/sample")
    assert response.status_code == 200
    assert response.headers["content-type"] == "audio/wav"
    assert response.content[:4] == b"RIFF"


def test_sample_of_a_builtin_voice_uses_its_reference(installed, tmp_path):
    clip = tmp_path / "reference.wav"
    sf.write(str(clip), tone_samples(1.0), 44100)
    prepare = AsyncMock(return_value=Reference(clip, "Hello there."))
    with patch.object(MingEngine, "prepare_reference", prepare):
        response = client.get("/engine/ming/voices/ming:US_James/sample")
    assert response.status_code == 200
    assert response.content[:4] == b"RIFF"
    assert prepare.await_args.args[0].id == "ming:US_James"


def test_sample_conflicts_when_ming_is_removed_mid_request(installed):
    gone = AsyncMock(side_effect=EngineNotInstalledError("ming"))
    with patch.object(MingEngine, "prepare_reference", gone):
        response = client.get("/engine/ming/voices/ming:US_James/sample")
    assert response.status_code == 409
    assert "Ming is not installed" in response.json()["detail"]


@pytest.mark.parametrize("seconds", [2.0, 31.0])
def test_clone_checks_the_duration_before_decoding(installed, seconds):
    with patch.object(voice_module.sf, "read", side_effect=AssertionError("decoded")):
        response = client.post(
            "/engine/ming/voices/clone",
            data=clone_form(),
            files=clone_files(seconds),
        )
    assert response.status_code == 422
    assert "between 3 and 30 seconds" in response.json()["detail"]


def test_sample_rejects_unknown_voices(installed):
    response = client.get("/engine/ming/voices/ming:Nobody/sample")
    assert response.status_code == 404


def test_sample_failure_is_a_clean_500(installed):
    failing = AsyncMock(
        side_effect=EngineWorkerError("Ming stopped before it finished.")
    )
    with patch.object(MingEngine, "prepare_reference", failing):
        response = client.get("/engine/ming/voices/ming:US_James/sample")
    assert response.status_code == 500


def test_the_voice_library_is_capped(installed, monkeypatch):
    monkeypatch.setattr(voice_module, "MAX_CUSTOM_VOICES", 1)
    first = client.post(
        "/engine/ming/voices/clone", data=clone_form(), files=clone_files()
    )
    assert first.status_code == 201
    second = client.post(
        "/engine/ming/voices/clone", data=clone_form(), files=clone_files()
    )
    assert second.status_code == 409
    assert MAX_CUSTOM_VOICES == 50


def test_store_survives_a_restart_and_drops_voices_with_missing_clips(installed):
    kept = ming_voices.create(
        name="Kept",
        language="en",
        kind="cloned",
        description="",
        transcript="Hi.",
        samples=tone_samples(4),
    )
    lost = ming_voices.create(
        name="Lost",
        language="zh",
        kind="designed",
        description="deep",
        transcript="你好。",
        samples=tone_samples(4),
    )
    ming_voices.wav_path(lost.id).unlink()
    ming_voices.reset()
    assert [voice.id for voice in ming_voices.list()] == [kept.id]
    assert ming_voices.get(kept.id).created_at


def test_store_ignores_corrupt_records(installed):
    ming_voices.create(
        name="Good",
        language="en",
        kind="cloned",
        description="",
        transcript="Hi.",
        samples=tone_samples(4),
    )
    from app.core.config import settings

    path = Path(settings.MING_VOICES_PATH)
    document = json.loads(path.read_text())
    document["voices"].append({"id": "ming:custom:short", "name": "Bad"})
    document["voices"].append("junk")
    path.write_text(json.dumps(document))
    ming_voices.reset()
    assert len(ming_voices.list()) == 1


def test_store_raises_when_full(installed, monkeypatch):
    monkeypatch.setattr(voice_module, "MAX_CUSTOM_VOICES", 0)
    with pytest.raises(VoiceLimitError):
        ming_voices.create(
            name="A",
            language="en",
            kind="cloned",
            description="",
            transcript="Hi.",
            samples=tone_samples(4),
        )


def test_clone_audio_validation_bounds():
    assert prepare_clone_audio(wav_bytes(3.0)).size == pytest.approx(3 * 44100, abs=2)
    assert prepare_clone_audio(wav_bytes(30.0)).size == pytest.approx(30 * 44100, abs=2)
    with pytest.raises(VoiceValidationError):
        prepare_clone_audio(wav_bytes(2.9))
    with pytest.raises(VoiceValidationError):
        prepare_clone_audio(wav_bytes(30.5))
    with pytest.raises(VoiceValidationError, match="silent"):
        import io

        buffer = io.BytesIO()
        sf.write(buffer, np.zeros(4 * 44100, dtype=np.float32), 44100, format="WAV")
        prepare_clone_audio(buffer.getvalue())
    with pytest.raises(VoiceValidationError, match="Could not read"):
        prepare_clone_audio(b"garbage")


def test_clone_audio_accepts_flac_and_aiff():
    import io

    for fmt in ("FLAC", "AIFF"):
        buffer = io.BytesIO()
        sf.write(buffer, tone_samples(4.0, 16000), 16000, format=fmt)
        assert prepare_clone_audio(buffer.getvalue()).size == pytest.approx(
            4 * 44100, abs=2
        )


@pytest.mark.parametrize(
    ("language", "seconds", "plausible"),
    [
        ("en", 0.4, False),
        ("en", 0.5, True),
        ("en", 13.0, True),
        ("en", 14.0, False),
        ("zh", 3.0, True),
        ("zh", 13.5, False),
    ],
)
def test_design_plausibility_uses_expected_speaking_rate(language, seconds, plausible):
    text = (
        SAMPLE_TEXT
        if language == "en"
        else "你好，这是我朗读时的声音样本，希望你喜欢。"
    )
    samples = np.zeros(int(seconds * 44100), dtype=np.float32)
    assert voice_module.is_plausible_design(samples, text, language) is plausible


def test_public_voice_list_includes_ming_only_when_installed():
    assert not [v for v in voice_list() if v["id"].startswith("ming:")]
    mark_installed()
    ming = [v for v in voice_list() if v["id"].startswith("ming:")]
    assert len(ming) == 117
    assert ming[0]["type"] == "builtin"


def test_speak_passes_delivery_to_the_speech_stream(installed):
    opened = AsyncMock(side_effect=RuntimeError("stop here"))
    with patch("app.api.tts.open_speech_samples", opened):
        client.post(
            "/speak",
            json={
                "text": "Hello there friend.",
                "voice": "ming:US_James",
                "delivery": {"emotion": "happy", "pace": "fast"},
            },
        )
    delivery = opened.await_args.kwargs["delivery"]
    assert delivery == Delivery(emotion="happy", pace="fast")


def test_speak_without_delivery_passes_none(installed):
    opened = AsyncMock(side_effect=RuntimeError("stop here"))
    with patch("app.api.tts.open_speech_samples", opened):
        client.post("/speak", json={"text": "Hello there friend."})
    assert opened.await_args.kwargs["delivery"] is None


@pytest.mark.parametrize("lang", ["zh", "ja", "ko", "de"])
def test_speak_accepts_ming_languages_for_ming_voices(installed, lang):
    opened = AsyncMock(side_effect=RuntimeError("stop here"))
    with patch("app.api.tts.open_speech_samples", opened):
        response = client.post(
            "/speak",
            json={"text": "Hello there friend.", "voice": "ming:灵小雅", "lang": lang},
        )
    assert response.status_code != 422
    assert opened.await_args.args[3] == lang


def test_speak_rejects_unknown_language_for_ming_voices(installed):
    opened = AsyncMock(side_effect=RuntimeError("stop here"))
    with patch("app.api.tts.open_speech_samples", opened):
        response = client.post(
            "/speak",
            json={"text": "Hello there friend.", "voice": "ming:灵小雅", "lang": "xx"},
        )
    assert response.status_code == 422
    opened.assert_not_awaited()


def test_speak_rejects_ming_only_language_for_other_engines_voices(installed):
    opened = AsyncMock(side_effect=RuntimeError("stop here"))
    with patch("app.api.tts.open_speech_samples", opened):
        rejected = client.post(
            "/speak",
            json={"text": "Hello there friend.", "voice": "af_heart", "lang": "ja"},
        )
        accepted = client.post(
            "/speak",
            json={
                "text": "Hello there friend.",
                "voice": "ming:US_James",
                "lang": "ja",
            },
        )
    assert rejected.status_code == 422
    assert "unsupported language" in rejected.text
    assert accepted.status_code != 422
    assert opened.await_count == 1


@pytest.mark.parametrize(
    "delivery",
    [
        {"emotion": "ecstatic"},
        {"style": "x" * 301},
        {"pace": "warp"},
        {"surprise": "field"},
    ],
)
def test_speak_rejects_invalid_delivery(delivery):
    response = client.post(
        "/speak", json={"text": "Hello there friend.", "delivery": delivery}
    )
    assert response.status_code == 422


def test_openai_instructions_become_the_delivery_style(installed):
    public = TestClient(create_public_app(API_KEY), headers=AUTH)
    opened = AsyncMock(side_effect=RuntimeError("stop here"))
    with patch("app.api.openai_compat.open_speech_samples", opened):
        public.post(
            "/v1/audio/speech",
            json={
                "model": "tts-1",
                "input": "Hello from the local API.",
                "voice": "ming:US_James",
                "instructions": "  Speak like a sleepy cat.  ",
                "delivery": {"emotion": "sad"},
            },
        )
    assert opened.await_args.kwargs["delivery"] == Delivery(
        emotion="sad", style="Speak like a sleepy cat."
    )


def test_openai_without_instructions_has_no_delivery(installed):
    public = TestClient(create_public_app(API_KEY), headers=AUTH)
    opened = AsyncMock(side_effect=RuntimeError("stop here"))
    with patch("app.api.openai_compat.open_speech_samples", opened):
        public.post(
            "/v1/audio/speech",
            json={"model": "tts-1", "input": "Hello.", "voice": "alloy"},
        )
    assert "delivery" not in opened.await_args.kwargs or (
        opened.await_args.kwargs["delivery"] is None
    )


async def silent_samples(*arguments, **keywords):
    async def chunks():
        yield np.zeros(2400, dtype=np.float32)

    return chunks()


@pytest.mark.parametrize(
    "instructions",
    [
        "Speak warmly.\nThen slowly.\r\n\tAnd end softly.",
        "x" * 1000,
        "bad\x00style\u200b\u202e",
        "   \n\t  ",
        "",
    ],
)
def test_openai_accepts_any_instructions_and_ignores_them_for_other_engines(
    instructions,
):
    public = TestClient(create_public_app(API_KEY), headers=AUTH)
    opened = AsyncMock(side_effect=silent_samples)
    with patch("app.api.openai_compat.open_speech_samples", opened):
        response = public.post(
            "/v1/audio/speech",
            json={
                "model": "tts-1",
                "input": "Hello.",
                "voice": "af_heart",
                "instructions": instructions,
            },
        )
    assert response.status_code == 200
    assert opened.await_args.kwargs["delivery"] is None


@pytest.mark.parametrize(
    ("instructions", "style"),
    [
        (
            "Speak warmly.\nThen slowly.\r\n\tAnd  end.",
            "Speak warmly. Then slowly. And end.",
        ),
        ("x" * 1000, "x" * 300),
        ("bad\x00style\u200b\u202ehere", "bad style here"),
        ("e\u0301" * 400, "\u00e9" * 300),
        ("a" * 299 + " b", "a" * 299),
        ("   \n\t  ", None),
    ],
)
def test_openai_instructions_are_cleaned_into_a_ming_style(
    installed, instructions, style
):
    public = TestClient(create_public_app(API_KEY), headers=AUTH)
    opened = AsyncMock(side_effect=silent_samples)
    with patch("app.api.openai_compat.open_speech_samples", opened):
        response = public.post(
            "/v1/audio/speech",
            json={
                "model": "tts-1",
                "input": "Hello.",
                "voice": "ming:US_James",
                "instructions": instructions,
            },
        )
    assert response.status_code == 200
    expected = None if style is None else Delivery(style=style)
    assert opened.await_args.kwargs["delivery"] == expected


def test_relay_forwards_delivery_to_the_app():
    public = TestClient(create_public_app(API_KEY), headers=AUTH)
    queue = speech_relay.subscribe()
    response = public.post(
        "/v1/voqora/speak",
        json={"text": "Hi there", "delivery": {"emotion": "happy", "style": " warm "}},
    )
    assert response.status_code == 202
    event = queue.get_nowait()
    assert event["delivery"] == {"emotion": "happy", "style": "warm"}


def test_relay_events_without_delivery_are_unchanged():
    public = TestClient(create_public_app(API_KEY), headers=AUTH)
    queue = speech_relay.subscribe()
    public.post("/v1/voqora/speak", json={"text": "Hi there"})
    assert "delivery" not in queue.get_nowait()


def test_mcp_speak_tool_forwards_delivery():
    public = TestClient(
        create_public_app(API_KEY),
        headers={**AUTH, "Accept": "application/json, text/event-stream"},
    )
    queue = speech_relay.subscribe()
    response = public.post(
        "/mcp",
        json={
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "speak",
                "arguments": {"text": "Hello", "delivery": {"pitch": "low"}},
            },
        },
    )
    assert response.json()["result"]["isError"] is False
    assert queue.get_nowait()["delivery"] == {"pitch": "low"}


@pytest.mark.asyncio
async def test_open_speech_samples_hands_delivery_to_the_manager(installed):
    from app.services.speech_stream import open_speech_samples

    seen = {}

    async def fake_generate(*args, **kwargs):
        seen.update(kwargs)
        yield np.zeros(10, dtype=np.float32)

    with (
        patch.object(EngineManager, "ensure_loaded", new=AsyncMock()),
        patch.object(EngineManager, "generate", side_effect=fake_generate),
    ):
        samples = await open_speech_samples(
            "hi", "ming:US_James", 1.0, delivery=Delivery(emotion="angry")
        )
        [chunk async for chunk in samples]
    assert seen["delivery"] == Delivery(emotion="angry")
