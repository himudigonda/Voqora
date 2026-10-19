from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch

import numpy as np
import pytest
from fastapi.testclient import TestClient
from supertonic_fakes import mark_installed

from app.api.public_app import create_public_app
from app.main import app
from app.services.audiobook_store import AudiobookStore
from app.services.engine_errors import EngineNotInstalledError
from app.services.engine_manager import EngineManager
from app.services.pronunciation import pronunciations
from app.services.public_voices import require_voice, voice_list
from app.services.speech_stream import open_speech_samples
from app.services.supertonic_engine import SupertonicEngine
from app.services.supertonic_installer import SupertonicInstaller
from app.services.tts import TTSEngine

client = TestClient(app)
SUPERTONIC_VOICE = "supertonic:M1"
API_KEY = "test-local-api-key-0123456789abcdef"


@pytest.fixture(autouse=True)
def isolated_audiobooks_dir(monkeypatch, tmp_path):
    class PatchedSettings:
        AUDIOBOOKS_DIR = str(tmp_path / "audiobooks")

    (tmp_path / "audiobooks").mkdir()
    monkeypatch.setattr("app.services.audiobook_store.settings", PatchedSettings())
    AudiobookStore._reset_for_tests()
    yield
    AudiobookStore._reset_for_tests()


@pytest.fixture
def installed():
    mark_installed(SupertonicInstaller.model_dir())


def stream(tag: str, calls: list):
    async def generate(*args, **kwargs):
        calls.append((tag, args, kwargs))
        yield np.zeros(240, dtype=np.float32)

    return generate


async def drain(voice: str, **kwargs) -> list:
    return [
        chunk async for chunk in EngineManager.generate("Hello.", voice, 1.0, **kwargs)
    ]


@pytest.mark.asyncio
async def test_generate_dispatches_by_voice_engine():
    calls: list = []
    with (
        patch.object(TTSEngine, "generate", side_effect=stream("kokoro", calls)),
        patch.object(
            SupertonicEngine, "generate", side_effect=stream("supertonic", calls)
        ),
    ):
        await drain("af_bella")
        await drain(SUPERTONIC_VOICE)
    assert [tag for tag, _, _ in calls] == ["kokoro", "supertonic"]
    assert calls[0][1][3] == "en-us"
    assert calls[1][1][1].id == SUPERTONIC_VOICE


@pytest.mark.asyncio
async def test_audiobook_page_language_is_detected_once_for_supertonic_voices():
    from app.services.audiobook_service import AudiobookService

    calls: list = []
    page = "The cat sat on the mat and the dog was in the yard. Bonjour."
    with (
        patch.object(EngineManager, "generate", side_effect=stream("manager", calls)),
        patch("app.services.audiobook_service.asyncio.sleep", new=AsyncMock()),
    ):
        await AudiobookService._generate_full_page("book", page, SUPERTONIC_VOICE, 1.0)
        await AudiobookService._generate_full_page("book", page, "af_bella", 1.0)
    languages = [call[1][3] for call in calls]
    assert set(languages[: len(languages) // 2]) == {"en"}
    assert set(languages[len(languages) // 2 :]) == {None}


@pytest.mark.asyncio
async def test_generate_applies_book_scoped_rules_to_supertonic():
    book_id = "a" * 32
    pronunciations.create(
        match="GIF",
        replacement="jif",
        case_sensitive=False,
        whole_word=True,
        scope=book_id,
    )
    calls: list = []
    with patch.object(
        SupertonicEngine, "generate", side_effect=stream("supertonic", calls)
    ):
        await drain(SUPERTONIC_VOICE, book_id=book_id)
        await drain(SUPERTONIC_VOICE)
    scoped, unscoped = (call[2]["pronunciation"] for call in calls)
    assert scoped.speakable("GIF")[0] == "jif"
    assert unscoped.speakable("GIF")[0] == "GIF"


@pytest.mark.asyncio
async def test_ensure_loaded_and_touch_dispatch_by_engine(installed):
    with (
        patch.object(TTSEngine, "ensure_loaded", new=AsyncMock()) as kokoro,
        patch.object(SupertonicEngine, "ensure_loaded", new=AsyncMock()) as other,
        patch.object(TTSEngine, "touch") as kokoro_touch,
        patch.object(SupertonicEngine, "touch") as other_touch,
    ):
        await EngineManager.ensure_loaded()
        await EngineManager.ensure_loaded("supertonic")
        EngineManager.touch()
        EngineManager.touch("supertonic")
    kokoro.assert_awaited_once()
    other.assert_awaited_once()
    kokoro_touch.assert_called_once()
    other_touch.assert_called_once()


@pytest.mark.asyncio
async def test_ensure_loaded_refuses_an_uninstalled_engine():
    with pytest.raises(EngineNotInstalledError, match="not installed"):
        await EngineManager.ensure_loaded("supertonic")


@pytest.mark.asyncio
async def test_prewarm_skips_the_kokoro_cache_for_supertonic_voices():
    with patch.object(TTSEngine, "prewarm_with_lookahead", new=AsyncMock()) as warm:
        await EngineManager.prewarm_with_lookahead("Hello.", SUPERTONIC_VOICE, 1.0)
        await EngineManager.prewarm_with_lookahead("Hello.", "af_bella", 1.0)
    warm.assert_awaited_once()


@pytest.mark.asyncio
async def test_prewarm_loads_the_voices_engine_and_ignores_missing_ones(installed):
    from app.api.tts import PrewarmRequest, _do_prewarm

    request = PrewarmRequest(text="Hello.", voice=SUPERTONIC_VOICE, speed=1.0)
    with patch.object(EngineManager, "ensure_loaded", new=AsyncMock()) as loaded:
        await _do_prewarm(request)
    loaded.assert_awaited_once_with("supertonic")

    SupertonicInstaller.uninstall()
    await _do_prewarm(request)


@pytest.mark.asyncio
async def test_open_speech_samples_checks_installation_before_taking_the_lock():
    with pytest.raises(EngineNotInstalledError):
        await open_speech_samples("hi", SUPERTONIC_VOICE, 1.0)
    from app.services.tts import interactive_tts_lock

    assert not interactive_tts_lock.locked()


@pytest.mark.asyncio
async def test_open_speech_samples_loads_the_voices_engine(installed):
    loaded = AsyncMock()
    with (
        patch.object(EngineManager, "ensure_loaded", new=loaded),
        patch.object(EngineManager, "generate", side_effect=stream("x", [])),
    ):
        samples = await open_speech_samples("hi", SUPERTONIC_VOICE, 1.0)
        await samples.aclose()
    loaded.assert_awaited_once_with("supertonic")


def test_speak_with_supertonic_voice_conflicts_when_not_installed():
    response = client.post("/speak", json={"text": "Hello.", "voice": SUPERTONIC_VOICE})
    assert response.status_code == 409
    assert "not installed" in response.json()["detail"]


def test_speak_with_supertonic_voice_streams_when_installed(installed):
    calls: list = []
    with (
        patch.object(EngineManager, "ensure_loaded", new=AsyncMock()),
        patch.object(EngineManager, "generate", side_effect=stream("x", calls)),
    ):
        response = client.post(
            "/speak", json={"text": "Hello.", "voice": SUPERTONIC_VOICE}
        )
        body = b"".join(response.iter_bytes())
    assert response.status_code == 200
    assert body.startswith(b"RIFF")
    assert calls[0][1][1] == SUPERTONIC_VOICE


def test_speak_passes_book_id_to_the_engine():
    book_id = "b" * 32
    calls: list = []
    with (
        patch.object(EngineManager, "ensure_loaded", new=AsyncMock()),
        patch.object(EngineManager, "generate", side_effect=stream("x", calls)),
    ):
        response = client.post(
            "/speak", json={"text": "Hello.", "voice": "af_bella", "book_id": book_id}
        )
        b"".join(response.iter_bytes())
    assert response.status_code == 200
    assert calls[0][2]["book_id"] == book_id


@pytest.mark.parametrize("book_id", ["../x", "global", "abc", "G" * 32])
def test_speak_rejects_a_malformed_book_id(book_id):
    response = client.post(
        "/speak", json={"text": "Hello.", "voice": "af_bella", "book_id": book_id}
    )
    assert response.status_code == 422


def test_speak_without_book_id_uses_only_global_rules():
    calls: list = []
    with (
        patch.object(EngineManager, "ensure_loaded", new=AsyncMock()),
        patch.object(EngineManager, "generate", side_effect=stream("x", calls)),
    ):
        b"".join(
            client.post(
                "/speak", json={"text": "Hello.", "voice": "af_bella"}
            ).iter_bytes()
        )
    assert calls[0][2]["book_id"] is None


def test_book_scoped_speak_applies_the_books_rules():
    book_id = "c" * 32
    pronunciations.create(
        match="GIF",
        replacement="jif",
        case_sensitive=False,
        whole_word=True,
        scope=book_id,
    )
    model = MagicMock()
    model.create.return_value = (np.zeros(240, dtype=np.float32), 24000)
    from concurrent.futures import ThreadPoolExecutor

    with (
        patch.object(TTSEngine, "_model", model),
        patch.object(TTSEngine, "_executor", ThreadPoolExecutor(max_workers=1)),
        patch.object(TTSEngine, "ensure_loaded", new=AsyncMock()),
        patch.object(TTSEngine, "_has_voices", return_value=True),
    ):
        b"".join(
            client.post(
                "/speak",
                json={"text": "A GIF.", "voice": "af_bella", "book_id": book_id},
            ).iter_bytes()
        )
        b"".join(
            client.post(
                "/speak", json={"text": "A GIF.", "voice": "af_bella"}
            ).iter_bytes()
        )
    spoken = [call.args[0] for call in model.create.call_args_list]
    assert spoken == ["A jif.", "A GIF."]


UPLOAD = {"file": ("notes.txt", b"A short document", "text/plain")}


def test_upload_rejects_supertonic_when_not_installed():
    response = client.post(
        "/audiobook",
        files=UPLOAD,
        data={"voice": SUPERTONIC_VOICE, "engine": "supertonic"},
    )
    assert response.status_code == 409
    assert "not installed" in response.json()["detail"]


def test_upload_derives_the_engine_from_the_voice():
    response = client.post("/audiobook", files=UPLOAD, data={"voice": SUPERTONIC_VOICE})
    assert response.status_code == 409


def test_upload_rejects_engine_without_a_voice_when_not_installed():
    response = client.post("/audiobook", files=UPLOAD, data={"engine": "supertonic"})
    assert response.status_code == 409


def test_upload_rejects_a_voice_from_another_engine():
    response = client.post(
        "/audiobook",
        files=UPLOAD,
        data={"voice": SUPERTONIC_VOICE, "engine": "kokoro"},
    )
    assert response.status_code == 422
    assert "different narration engine" in response.json()["detail"]
    response = client.post(
        "/audiobook", files=UPLOAD, data={"voice": "af_bella", "engine": "supertonic"}
    )
    assert response.status_code == 422


def test_upload_rejects_blends_with_supertonic(installed):
    blend = client.post(
        "/voices/blends",
        json={
            "name": "Warm",
            "components": [
                {"voice": "af_bella", "weight": 1},
                {"voice": "am_adam", "weight": 1},
            ],
        },
    ).json()
    response = client.post(
        "/audiobook", files=UPLOAD, data={"voice": blend["id"], "engine": "supertonic"}
    )
    assert response.status_code == 422
    assert response.json()["detail"] == "Voice blends work with Kokoro only."


def test_upload_accepts_supertonic_when_installed(installed):
    response = client.post(
        "/audiobook",
        files=UPLOAD,
        data={"voice": SUPERTONIC_VOICE, "engine": "supertonic"},
    )
    assert response.status_code == 200, response.text
    meta = AudiobookStore.read_meta(response.json()["book_id"])
    assert meta["engine"] == "supertonic"
    assert meta["voice"] == SUPERTONIC_VOICE


def test_upload_with_only_engine_picks_that_engines_default_voice(installed):
    response = client.post("/audiobook", files=UPLOAD, data={"engine": "supertonic"})
    assert response.status_code == 200, response.text
    meta = AudiobookStore.read_meta(response.json()["book_id"])
    assert meta["voice"] == "supertonic:F1"


def test_start_and_retry_conflict_once_the_engine_was_removed(installed):
    book_id = client.post(
        "/audiobook", files=UPLOAD, data={"voice": SUPERTONIC_VOICE}
    ).json()["book_id"]
    SupertonicInstaller.uninstall()
    start = client.post(f"/audiobook/{book_id}/start")
    retry = client.post(f"/audiobook/{book_id}/retry")
    assert start.status_code == 409
    assert retry.status_code == 409
    assert "not installed" in start.json()["detail"]


def test_podcast_script_rejects_supertonic_hosts(installed):
    response = client.post(
        "/podcast/script",
        json={
            "source": {"text": "Tides are caused by the moon."},
            "style": "deep_dive",
            "minutes": 5,
            "language": "en-us",
            "hosts": [
                {"name": "Ava", "voice": SUPERTONIC_VOICE},
                {"name": "Sam", "voice": "am_adam"},
            ],
        },
    )
    assert response.status_code == 422
    assert "Kokoro voices only" in response.text


def test_public_voice_list_shows_supertonic_only_when_installed(installed):
    assert any(voice["id"] == SUPERTONIC_VOICE for voice in voice_list())
    SupertonicInstaller.uninstall()
    assert not any(voice["id"].startswith("supertonic:") for voice in voice_list())


def test_public_api_requires_the_engine_to_be_installed():
    with pytest.raises(ValueError, match="not installed"):
        require_voice(SUPERTONIC_VOICE)


def test_public_api_speech_with_supertonic_voice_is_rejected_cleanly():
    public = TestClient(
        create_public_app(API_KEY), headers={"Authorization": f"Bearer {API_KEY}"}
    )
    response = public.post(
        "/v1/audio/speech",
        json={"model": "tts-1", "input": "Hello.", "voice": SUPERTONIC_VOICE},
    )
    assert response.status_code == 400
    assert "not installed" in response.text


def test_public_api_accepts_supertonic_voice_when_installed(installed):
    assert require_voice(SUPERTONIC_VOICE) == SUPERTONIC_VOICE
