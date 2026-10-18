import concurrent.futures
import os
import shutil
import tempfile
from unittest.mock import AsyncMock, patch

import numpy as np
import pytest
from fastapi.testclient import TestClient

from app.core.config import settings
from app.main import app
from app.services.audiobook_service import AudiobookService, _book_pause_scale
from app.services.audiobook_store import AudiobookStore
from app.services.engine_manager import EngineManager
from app.services.tts import SEGMENT_PAUSE_SECONDS, TTSEngine

client = TestClient(app)
SPEECH_SAMPLES = 2400


class SilentKokoro:
    voices = {"af_bella": np.zeros((4, 1, 2), dtype=np.float32)}

    def __init__(self):
        self.calls = 0

    def create(self, text, voice, speed, lang):
        self.calls += 1
        return np.ones(SPEECH_SAMPLES, dtype=np.float32), 24000


@pytest.fixture
def model():
    fake = SilentKokoro()
    previous_model, previous_executor = TTSEngine._model, TTSEngine._executor
    TTSEngine._model = fake
    TTSEngine._executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
    TTSEngine._lookahead_cache.clear()
    yield fake
    TTSEngine._executor.shutdown(wait=True)
    TTSEngine._model, TTSEngine._executor = previous_model, previous_executor
    TTSEngine._lookahead_cache.clear()


@pytest.fixture
def isolated_books(monkeypatch):
    tmp = tempfile.mkdtemp(prefix="voqora_pause_books_")

    class _PatchedSettings:
        @property
        def AUDIOBOOKS_DIR(self) -> str:
            return tmp

    monkeypatch.setattr("app.services.audiobook_store.settings", _PatchedSettings())
    AudiobookStore._reset_for_tests()
    yield tmp
    AudiobookStore._reset_for_tests()
    shutil.rmtree(tmp, ignore_errors=True)


async def _silence_samples(text, speed, pause_scale):
    chunks = [
        chunk
        async for chunk in TTSEngine.generate(
            text, "af_bella", speed, pause_scale=pause_scale
        )
    ]
    return [len(chunk) - SPEECH_SAMPLES for chunk in chunks]


@pytest.mark.asyncio
@pytest.mark.parametrize("pause_scale", [0.5, 1.0, 1.5, 2.0])
async def test_segment_pauses_scale_linearly(model, pause_scale):
    silences = await _silence_samples("Hello there. How are you?", 1.0, pause_scale)
    expected = int(
        SEGMENT_PAUSE_SECONDS["."] * pause_scale * settings.AUDIO_SAMPLE_RATE
    )
    assert silences == [expected, expected]


@pytest.mark.asyncio
async def test_pause_scale_combines_with_speed(model):
    silences = await _silence_samples("Hello there.", 2.0, 2.0)
    assert silences == [int(SEGMENT_PAUSE_SECONDS["."] * settings.AUDIO_SAMPLE_RATE)]


@pytest.mark.asyncio
async def test_lookahead_key_includes_pause_scale(model):
    await EngineManager.prewarm_with_lookahead("Hello there.", "af_bella", 1.0)
    async for _ in EngineManager.generate(
        "Hello there.", "af_bella", 1.0, pause_scale=1.5
    ):
        pass
    assert model.calls == 2
    await EngineManager.prewarm_with_lookahead(
        "Hello there.", "af_bella", 1.0, pause_scale=1.5
    )
    async for _ in EngineManager.generate(
        "Hello there.", "af_bella", 1.0, pause_scale=1.5
    ):
        pass
    assert model.calls == 3


@pytest.mark.parametrize("value", [0.49, 2.01, "nan", None])
def test_speak_rejects_out_of_range_pause_scale(value):
    response = client.post("/speak", json={"text": "Hi.", "pause_scale": value})
    assert response.status_code == 422


@patch.object(EngineManager, "ensure_loaded")
@pytest.mark.parametrize("value", [0.5, 2.0])
def test_speak_passes_pause_scale_through(_ensure, value):
    seen = []

    async def fake_generate(*args, **kwargs):
        seen.append(kwargs["pause_scale"])
        yield np.zeros(10, dtype=np.float32)

    with patch.object(EngineManager, "generate", side_effect=fake_generate):
        response = client.post("/speak", json={"text": "Hi.", "pause_scale": value})
        b"".join(response.iter_bytes())
    assert response.status_code == 200
    assert seen == [value]


@patch.object(EngineManager, "ensure_loaded")
def test_speak_defaults_pause_scale_to_one(_ensure):
    seen = []

    async def fake_generate(*args, **kwargs):
        seen.append(kwargs["pause_scale"])
        yield np.zeros(10, dtype=np.float32)

    with patch.object(EngineManager, "generate", side_effect=fake_generate):
        b"".join(client.post("/speak", json={"text": "Hi."}).iter_bytes())
    assert seen == [1.0]


def test_prewarm_rejects_out_of_range_pause_scale():
    assert client.post("/prewarm", json={"pause_scale": 3}).status_code == 422


def _mock_text_extraction(monkeypatch):
    from app.services import text_extractor as _te

    monkeypatch.setattr(_te.TextExtractor, "page_count", classmethod(lambda cls, _: 1))
    monkeypatch.setattr(
        _te.TextExtractor, "read_text", classmethod(lambda cls, _: "document content")
    )
    monkeypatch.setattr(
        _te.TextExtractor, "sample_word_count", classmethod(lambda cls, _: 10)
    )
    monkeypatch.setattr(
        _te.TextExtractor, "sample_char_count", classmethod(lambda cls, _: 50)
    )
    monkeypatch.setattr(
        _te.TextExtractor, "render_cover", classmethod(lambda cls, _: None)
    )


def _upload(**data):
    return client.post(
        "/audiobook",
        files={"file": ("notes.txt", b"document content", "text/plain")},
        data=data,
    )


@pytest.mark.parametrize("value", ["0.4", "2.5", "nan", "inf"])
def test_audiobook_upload_rejects_bad_pause_scale(isolated_books, value):
    response = _upload(pause_scale=value)
    assert response.status_code == 422
    assert response.json()["detail"] == "Pause length must be between 0.5 and 2.0."
    assert AudiobookStore.list_books() == []


def test_audiobook_upload_stores_pause_scale(monkeypatch, isolated_books):
    _mock_text_extraction(monkeypatch)
    response = _upload(pause_scale="1.5")
    assert response.status_code == 200, response.text
    meta = AudiobookStore.read_meta(response.json()["book_id"])
    assert meta["pause_scale"] == 1.5
    assert meta["voice_fallback"] == "af_bella"


def test_audiobook_upload_defaults_pause_scale(monkeypatch, isolated_books):
    _mock_text_extraction(monkeypatch)
    response = _upload()
    assert AudiobookStore.read_meta(response.json()["book_id"])["pause_scale"] == 1.0


@pytest.mark.parametrize(
    ("meta", "expected"),
    [
        ({}, 1.0),
        ({"pause_scale": 1.25}, 1.25),
        ({"pause_scale": 9}, 2.0),
        ({"pause_scale": 0.1}, 0.5),
        ({"pause_scale": "junk"}, 1.0),
        ({"pause_scale": float("nan")}, 1.0),
    ],
)
def test_book_pause_scale_is_clamped(meta, expected):
    assert _book_pause_scale(meta) == expected


@pytest.mark.asyncio
async def test_tts_phase_uses_book_pause_scale(isolated_books):
    book_id = AudiobookStore.create_book("Pause.txt")
    meta = AudiobookStore.initial_meta(
        book_id, "Pause.txt", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["pause_scale"] = 1.75
    AudiobookStore.write_meta(book_id, meta)
    path = AudiobookStore.page_clean_path(book_id, 1)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write("One sentence.")
    seen = []

    async def fake_generate(*args, **kwargs):
        seen.append(kwargs["pause_scale"])
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
    assert seen == [1.75]


def test_alignment_expects_scaled_pauses():
    from app.services.audiobook_service import SAMPLE_RATE, _aligned_page_lines

    pause = int(SEGMENT_PAUSE_SECONDS["."] * 2.0 * SAMPLE_RATE)
    speech = np.ones(SAMPLE_RATE, dtype=np.int16)
    samples = np.concatenate([speech, np.zeros(pause, dtype=np.int16), speech])
    lines = _aligned_page_lines(
        "First sentence is here. Second one follows.", samples, 1.0, 2.0
    )
    assert [line["text"] for line in lines] == [
        "First sentence is here.",
        "Second one follows.",
    ]
    assert lines[1]["start"] == pytest.approx((SAMPLE_RATE + pause) / SAMPLE_RATE)
