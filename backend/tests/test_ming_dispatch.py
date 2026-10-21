from __future__ import annotations

import json
import os
from unittest.mock import AsyncMock, patch

import numpy as np
import pytest
from fastapi.testclient import TestClient
from ming_fakes import mark_installed

from app.main import app
from app.services.audiobook_service import AudiobookService
from app.services.audiobook_store import AudiobookStore
from app.services.delivery import Delivery
from app.services.engine_errors import EngineNotInstalledError
from app.services.engine_manager import EngineManager
from app.services.ming_engine import MingEngine
from app.services.tts import TTSEngine

client = TestClient(app)
MING_VOICE = "ming:US_James"
UPLOAD = {"file": ("notes.txt", b"A short document", "text/plain")}


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
    mark_installed()


def stream(tag: str, calls: list):
    async def generate(*args, **kwargs):
        calls.append((tag, args, kwargs))
        yield np.zeros(240, dtype=np.float32)

    return generate


@pytest.mark.asyncio
async def test_generate_dispatches_ming_voices_to_the_ming_engine():
    calls: list = []
    with (
        patch.object(TTSEngine, "generate", side_effect=stream("kokoro", calls)),
        patch.object(MingEngine, "generate", side_effect=stream("ming", calls)),
    ):
        async for _ in EngineManager.generate("Hello.", "af_bella", 1.0):
            pass
        async for _ in EngineManager.generate(
            "Hello.", MING_VOICE, 1.0, delivery=Delivery(emotion="sad")
        ):
            pass
    assert [tag for tag, _, _ in calls] == ["kokoro", "ming"]
    assert calls[1][1][1].id == MING_VOICE
    assert calls[1][2]["delivery"] == Delivery(emotion="sad")
    assert "delivery" not in calls[0][2]


@pytest.mark.asyncio
async def test_ensure_loaded_and_touch_dispatch_to_ming(installed):
    with (
        patch.object(MingEngine, "ensure_loaded", new=AsyncMock()) as loaded,
        patch.object(MingEngine, "touch") as touched,
    ):
        await EngineManager.ensure_loaded("ming")
        EngineManager.touch("ming")
    loaded.assert_awaited_once()
    touched.assert_called_once()


@pytest.mark.asyncio
async def test_ensure_loaded_refuses_ming_when_not_installed():
    with pytest.raises(EngineNotInstalledError, match="Ming is not installed"):
        await EngineManager.ensure_loaded("ming")


@pytest.mark.asyncio
async def test_prewarm_skips_ming_voices(installed):
    with patch.object(TTSEngine, "prewarm_with_lookahead", new=AsyncMock()) as warm:
        await EngineManager.prewarm_with_lookahead("Hello.", MING_VOICE, 1.0)
    warm.assert_not_awaited()


@pytest.mark.asyncio
async def test_prewarm_never_loads_the_ming_worker(installed):
    from app.api.tts import PrewarmRequest, _do_prewarm

    request = PrewarmRequest(text="Hello.", voice=MING_VOICE, speed=1.0)
    with patch.object(EngineManager, "ensure_loaded", new=AsyncMock()) as loaded:
        await _do_prewarm(request)
    loaded.assert_not_awaited()


def test_speak_with_a_ming_voice_conflicts_when_not_installed():
    response = client.post("/speak", json={"text": "Hello.", "voice": MING_VOICE})
    assert response.status_code == 409
    assert "Ming is not installed" in response.json()["detail"]


def test_speak_with_a_ming_voice_streams_with_delivery(installed):
    calls: list = []
    with (
        patch.object(EngineManager, "ensure_loaded", new=AsyncMock()) as loaded,
        patch.object(EngineManager, "generate", side_effect=stream("x", calls)),
    ):
        response = client.post(
            "/speak",
            json={
                "text": "Hello.",
                "voice": MING_VOICE,
                "delivery": {"emotion": "happy"},
            },
        )
        body = b"".join(response.iter_bytes())
    assert response.status_code == 200
    assert body.startswith(b"RIFF")
    loaded.assert_awaited_once_with("ming")
    assert calls[0][2]["delivery"] == Delivery(emotion="happy")


def test_upload_rejects_ming_when_not_installed():
    response = client.post(
        "/audiobook", files=UPLOAD, data={"voice": MING_VOICE, "engine": "ming"}
    )
    assert response.status_code == 409
    assert "not installed" in response.json()["detail"]


def test_upload_rejects_a_ming_voice_under_another_engine(installed):
    response = client.post(
        "/audiobook", files=UPLOAD, data={"voice": MING_VOICE, "engine": "kokoro"}
    )
    assert response.status_code == 422


def test_upload_snapshots_the_ming_delivery_into_the_book(installed):
    response = client.post(
        "/audiobook",
        files=UPLOAD,
        data={
            "voice": MING_VOICE,
            "engine": "ming",
            "delivery": json.dumps({"emotion": "happy", "pace": "slow"}),
        },
    )
    assert response.status_code == 200
    meta = AudiobookStore.read_meta(response.json()["book_id"])
    assert meta["engine"] == "ming"
    assert meta["voice"] == MING_VOICE
    assert meta["delivery"] == {"emotion": "happy", "pace": "slow"}


def test_upload_without_delivery_stores_none(installed):
    response = client.post(
        "/audiobook", files=UPLOAD, data={"voice": MING_VOICE, "engine": "ming"}
    )
    assert "delivery" not in AudiobookStore.read_meta(response.json()["book_id"])


@pytest.mark.parametrize("raw", ["not json", '{"emotion": "bogus"}', '["happy"]'])
def test_upload_rejects_invalid_delivery(installed, raw):
    response = client.post(
        "/audiobook",
        files=UPLOAD,
        data={"voice": MING_VOICE, "engine": "ming", "delivery": raw},
    )
    assert response.status_code == 422


def test_url_import_accepts_delivery(installed):
    from app.api.audiobook import AudiobookURLRequest

    request = AudiobookURLRequest(
        url="https://example.com/a", delivery={"style": "calm narrator"}
    )
    assert request.delivery == Delivery(style="calm narrator")


@pytest.mark.asyncio
async def test_the_audiobook_pipeline_hands_the_books_delivery_to_the_engine(installed):
    seen: list = []

    async def fake_generate(text, voice, speed, lang=None, **kwargs):
        seen.append(kwargs.get("delivery"))
        yield np.zeros(240, dtype=np.float32)

    with (
        patch.object(EngineManager, "generate", side_effect=fake_generate),
        patch("app.services.audiobook_service.asyncio.sleep", new=AsyncMock()),
    ):
        await AudiobookService._generate_full_page(
            "book",
            "Hello there friend.",
            MING_VOICE,
            1.0,
            delivery=Delivery(pitch="low"),
        )
        await AudiobookService._generate_full_page(
            "book", "Hello there friend.", MING_VOICE, 1.0
        )
    assert seen == [Delivery(pitch="low"), None]


@pytest.mark.asyncio
async def test_the_tts_phase_reads_the_delivery_saved_with_the_book(installed):
    book_id = AudiobookStore.create_book("Delivery.txt")
    meta = AudiobookStore.initial_meta(
        book_id, "Delivery.txt", 1, "ming", MING_VOICE, 1.0, {"cost_usd": 0.0}
    )
    meta["delivery"] = {"emotion": "happy", "pace": "fast"}
    AudiobookStore.write_meta(book_id, meta)
    path = AudiobookStore.page_clean_path(book_id, 1)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("One sentence.")
    seen: list = []

    async def fake_generate(*args, **kwargs):
        seen.append(kwargs.get("delivery"))
        yield np.zeros(240, dtype=np.float32)

    with (
        patch(
            "app.services.audiobook_service.EngineManager.ensure_loaded",
            new=AsyncMock(return_value=None),
        ),
        patch("app.services.audiobook_service.EngineManager.touch"),
        patch(
            "app.services.audiobook_service.EngineManager.generate",
            side_effect=fake_generate,
        ),
        patch("app.services.audiobook_service.asyncio.sleep", new=AsyncMock()),
    ):
        await AudiobookService._phase_tts(book_id, AudiobookStore.read_meta(book_id))
    assert seen == [Delivery(emotion="happy", pace="fast")]
