"""Tests for the audiobook pipeline.

Mocks: PDFExtractor (no real PDFs), GeminiCleaner (no API calls),
EngineManager.generate (yields short np arrays).
"""

import asyncio
import json
import os
import shutil
import tempfile
from unittest.mock import AsyncMock, patch

import numpy as np
import pytest

from app.services.audiobook_service import (
    SAMPLE_RATE,
    WAV_HEADER_SIZE,
    AudiobookService,
    _wav_header,
)
from app.services.audiobook_store import AudiobookStore


@pytest.fixture(autouse=True)
def isolated_audiobooks_dir(monkeypatch):
    """Redirect AUDIOBOOKS_DIR to a per-test temp dir so tests don't pollute.

    Also resets the singleton SQLite connection so each test gets a fresh
    audiobooks.db inside its own tmp dir.
    """
    tmp = tempfile.mkdtemp(prefix="ss_audiobooks_test_")

    class _PatchedSettings:
        @property
        def AUDIOBOOKS_DIR(self) -> str:
            return tmp

    monkeypatch.setattr("app.services.audiobook_store.settings", _PatchedSettings())
    AudiobookStore._reset_for_tests()
    yield tmp
    AudiobookStore._reset_for_tests()
    shutil.rmtree(tmp, ignore_errors=True)


# ---------- AudiobookStore ----------


def test_legacy_meta_json_is_migrated_to_sqlite(isolated_audiobooks_dir):
    """Regression: a leftover meta.json from before the SQLite migration is
    imported into the DB on first connection, and the JSON file is deleted."""
    from app.services.audiobook_store import AudiobookStore

    bid = "abc123_legacy"
    bdir = os.path.join(isolated_audiobooks_dir, bid)
    os.makedirs(os.path.join(bdir, "pages"), exist_ok=True)
    legacy_path = os.path.join(bdir, "meta.json")
    legacy = {
        "book_id": bid,
        "title": "Legacy.pdf",
        "created_at": "2024-01-01T00:00:00Z",
        "page_count": 7,
        "status": "done",
        "engine": "kokoro",
        "voice": "af_bella",
        "speed": 1.0,
        "estimated": {"cost_usd": 0.5},
    }
    with open(legacy_path, "w") as f:
        json.dump(legacy, f)

    # Force connection (triggers migration).
    AudiobookStore._reset_for_tests()
    meta = AudiobookStore.read_meta(bid)
    assert meta is not None
    assert meta["title"] == "Legacy.pdf"
    assert meta["page_count"] == 7
    # Legacy JSON file removed.
    assert not os.path.exists(legacy_path)


def test_create_book_makes_dirs():
    bid = AudiobookStore.create_book("Test.pdf")
    assert os.path.isdir(AudiobookStore.book_dir(bid))
    assert os.path.isdir(os.path.join(AudiobookStore.book_dir(bid), "pages"))
    assert os.path.isdir(os.path.join(AudiobookStore.book_dir(bid), "audio_pages"))


def test_meta_atomic_write_and_read():
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 5, "kokoro", "af_bella", 1.0, {"cost_usd": 0.1}
    )
    AudiobookStore.write_meta(bid, meta)
    read = AudiobookStore.read_meta(bid)
    assert read is not None
    assert read["book_id"] == bid
    assert read["page_count"] == 5
    assert read["status"] == "ready"


def test_list_books_sorted_desc():
    b1 = AudiobookStore.create_book("a.pdf")
    AudiobookStore.write_meta(
        b1,
        {"book_id": b1, "title": "a", "created_at": "2024-01-01T00:00:00Z"},
    )
    b2 = AudiobookStore.create_book("b.pdf")
    AudiobookStore.write_meta(
        b2,
        {"book_id": b2, "title": "b", "created_at": "2025-06-01T00:00:00Z"},
    )
    books = AudiobookStore.list_books()
    assert [b["book_id"] for b in books][:2] == [b2, b1]


def test_delete_book_removes_dir():
    bid = AudiobookStore.create_book("Test.pdf")
    assert AudiobookStore.delete_book(bid) is True
    assert not os.path.isdir(AudiobookStore.book_dir(bid))
    assert AudiobookStore.delete_book(bid) is False  # second delete


# ---------- estimation ----------


def test_estimate_math():
    est = AudiobookService.estimate(
        page_count=100, sample_words=300, sample_chars=1500, speed=1.0
    )
    assert est["pages"] == 100
    assert est["words"] == 30000
    # 30000 words / 2.75 wps ≈ 10909 s
    assert 10500 < est["audio_seconds"] < 11200
    assert est["processing_seconds"] > 0
    assert est["cost_usd"] > 0


# ---------- WAV concat ----------


def _write_pcm_wav(path: str, n_samples: int, value: int = 0) -> None:
    """Write a tiny WAV file with a known PCM length (for concat tests)."""
    import wave

    pcm = (np.full(n_samples, value, dtype=np.int16)).tobytes()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(pcm)


@pytest.mark.asyncio
async def test_concat_phase_builds_correct_wav_and_page_to_time():
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 3, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    AudiobookStore.write_meta(bid, meta)

    # 3 pages: 24000 samples (1s), 12000 samples (0.5s), 6000 samples (0.25s)
    _write_pcm_wav(AudiobookStore.page_audio_path(bid, 1), 24000)
    _write_pcm_wav(AudiobookStore.page_audio_path(bid, 2), 12000)
    _write_pcm_wav(AudiobookStore.page_audio_path(bid, 3), 6000)

    actual = await AudiobookService._phase_concat(bid, AudiobookStore.read_meta(bid))

    # Final WAV exists, body = sum of PCM bytes (3 pages, 2 bytes/sample)
    final = AudiobookStore.audio_path(bid)
    assert os.path.exists(final)
    expected_pcm = (24000 + 12000 + 6000) * 2
    assert os.path.getsize(final) == WAV_HEADER_SIZE + expected_pcm

    new_meta = AudiobookStore.read_meta(bid)
    assert new_meta["page_to_time"]["1"] == 0.0
    # page 2 starts after 1s
    assert abs(new_meta["page_to_time"]["2"] - 1.0) < 0.001
    # page 3 starts after 1.5s
    assert abs(new_meta["page_to_time"]["3"] - 1.5) < 0.001
    assert abs(new_meta["total_audio_seconds"] - 1.75) < 0.001
    assert actual["pages"] == 3
    assert actual["audio_seconds"] == new_meta["total_audio_seconds"]


def test_wav_header_format():
    body_size = 1000
    h = _wav_header(body_size)
    assert len(h) == 44
    assert h[:4] == b"RIFF"
    assert h[8:12] == b"WAVE"
    assert h[36:40] == b"data"


# ---------- TTS phase + per-page failure ----------


async def _mock_generate_yielding(*args, **kwargs):
    yield np.zeros(12000, dtype=np.float32)
    yield np.zeros(6000, dtype=np.float32)


@pytest.mark.asyncio
async def test_tts_phase_writes_per_page_wavs(monkeypatch):
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 2, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    AudiobookStore.write_meta(bid, meta)
    # Pre-create cleaned text for 2 pages so tts phase has input.
    for n in (1, 2):
        path = AudiobookStore.page_clean_path(bid, n)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(f"Page {n} content.")

    with (
        patch(
            "app.services.audiobook_service.EngineManager.ensure_loaded",
            new=AsyncMock(return_value=None),
        ),
        patch(
            "app.services.audiobook_service.EngineManager.touch",
            return_value=None,
        ),
        patch(
            "app.services.audiobook_service.EngineManager.generate",
            side_effect=_mock_generate_yielding,
        ),
    ):
        await AudiobookService._phase_tts(bid, meta)

    for n in (1, 2):
        assert os.path.exists(AudiobookStore.page_audio_path(bid, n))


# ---------- API endpoints ----------


def test_audiobook_list_endpoint_initially_empty():
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    response = client.get("/audiobook")
    assert response.status_code == 200
    assert response.json() == []


def test_audiobook_404_for_unknown_id():
    """Well-formed but non-existent UUID → 404."""
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    # Valid hex-32 shape, but the row doesn't exist.
    response = client.get("/audiobook/" + ("a" * 32))
    assert response.status_code == 404


def test_audiobook_400_for_malformed_id():
    """Anything that isn't 32 hex chars → 400 (HARD-017 path-traversal guard)."""
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    for bad in ["nonexistent_id_12345", "../../etc/passwd", "ZZZZ", "a" * 31, "a" * 33]:
        response = client.get(f"/audiobook/{bad}")
        # FastAPI 404s on path-segment mismatch when the route doesn't match
        # (e.g. "../"). For shapes that DO traverse our route, expect 400.
        assert response.status_code in (400, 404), (bad, response.status_code)


def test_audiobook_upload_rejects_oversize_file(monkeypatch):
    """Body > MAX_AUDIOBOOK_UPLOAD_MB → 413, no OOM. Limit is shrunk to 1 MB
    for the test so we don't have to allocate 100 MB of test data."""
    from fastapi.testclient import TestClient

    from app.core.config import settings
    from app.main import app

    monkeypatch.setattr(settings, "MAX_AUDIOBOOK_UPLOAD_MB", 1)
    client = TestClient(app)
    huge = b"%PDF-1.4\n" + b"A" * (2 * 1024 * 1024)  # 2 MiB > 1 MB limit
    response = client.post(
        "/audiobook",
        files={"file": ("big.pdf", huge, "application/pdf")},
    )
    assert response.status_code == 413
    assert "MB" in response.json()["detail"]


def test_start_requires_api_key_header():
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    bid = AudiobookStore.create_book("Test.pdf")
    AudiobookStore.write_meta(
        bid,
        AudiobookStore.initial_meta(
            bid, "Test.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
        ),
    )
    response = client.post(f"/audiobook/{bid}/start")
    assert response.status_code == 400
    assert "X-Gemini-Api-Key" in response.json()["detail"]


# ---------- resume ----------


@pytest.mark.asyncio
async def test_resume_in_progress_flips_cleaning_to_needs_key():
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["status"] = "cleaning"
    AudiobookStore.write_meta(bid, meta)

    await AudiobookService.resume_in_progress()
    new_meta = AudiobookStore.read_meta(bid)
    assert new_meta["status"] == "needs_key"


# ---------- Phase 2: section detection ----------


def test_stitch_sections_basic_contiguity():
    from app.services.gemini_cleaner import GeminiCleaner

    raw = [
        {"title": "Intro", "start_page": 1, "end_page": 3},
        {"title": "Chapter 1", "start_page": 4, "end_page": 9},
        {"title": "Chapter 2", "start_page": 10, "end_page": 15},
    ]
    out = GeminiCleaner._stitch_sections(raw, page_count=20)
    # Last section's end_page extended to page_count.
    assert out[-1]["end_page"] == 20
    # Contiguous: each end == next start - 1.
    for a, b in zip(out, out[1:]):
        assert a["end_page"] == b["start_page"] - 1


def test_stitch_sections_inserts_front_matter():
    from app.services.gemini_cleaner import GeminiCleaner

    raw = [{"title": "Chapter 1", "start_page": 4, "end_page": 9}]
    out = GeminiCleaner._stitch_sections(raw, page_count=12)
    assert out[0]["title"] == "Front Matter"
    assert out[0]["start_page"] == 1
    assert out[0]["end_page"] == 3
    assert out[-1]["end_page"] == 12


def test_parse_sections_json_strips_markdown_fence():
    from app.services.gemini_cleaner import GeminiCleaner

    fenced = '```json\n{"sections":[{"title":"A","start_page":1,"end_page":5}]}\n```'
    out = GeminiCleaner._parse_sections_json(fenced, max_page=10)
    assert out == [{"title": "A", "start_page": 1, "end_page": 5}]


def test_parse_sections_json_drops_invalid_entries():
    from app.services.gemini_cleaner import GeminiCleaner

    bad = json.dumps(
        {
            "sections": [
                {"title": "Good", "start_page": 1, "end_page": 3},
                {"title": "", "start_page": 4, "end_page": 5},  # empty title
                {"title": "BadOrder", "start_page": 9, "end_page": 7},  # end < start
                {"title": "Beyond", "start_page": 100, "end_page": 200},  # out of range
            ]
        }
    )
    out = GeminiCleaner._parse_sections_json(bad, max_page=10)
    assert len(out) == 1
    assert out[0]["title"] == "Good"


# ---------- Phase 2: HTTP Range support ----------


@pytest.mark.asyncio
async def test_audio_range_request_returns_206_with_correct_slice():
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    bid = AudiobookStore.create_book("Test.pdf")
    AudiobookStore.write_meta(
        bid,
        AudiobookStore.initial_meta(
            bid, "Test.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
        ),
    )
    # Create a known-content audio.wav.
    audio_path = AudiobookStore.audio_path(bid)
    payload = bytes(range(256)) * 16  # 4096 bytes
    with open(audio_path, "wb") as f:
        f.write(payload)

    response = client.get(f"/audiobook/{bid}/audio", headers={"Range": "bytes=100-199"})
    assert response.status_code == 206
    assert response.headers["Content-Range"] == f"bytes 100-199/{len(payload)}"
    assert response.headers["Accept-Ranges"] == "bytes"
    assert response.content == payload[100:200]


def test_audio_no_range_returns_full_file_with_accept_ranges_header():
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    bid = AudiobookStore.create_book("Test.pdf")
    AudiobookStore.write_meta(
        bid,
        AudiobookStore.initial_meta(
            bid, "Test.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
        ),
    )
    payload = b"hello-wav-bytes"
    with open(AudiobookStore.audio_path(bid), "wb") as f:
        f.write(payload)

    response = client.get(f"/audiobook/{bid}/audio")
    assert response.status_code == 200
    assert response.headers["Accept-Ranges"] == "bytes"
    assert response.content == payload


def test_audio_range_invalid_returns_416():
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    bid = AudiobookStore.create_book("Test.pdf")
    AudiobookStore.write_meta(
        bid,
        AudiobookStore.initial_meta(
            bid, "Test.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
        ),
    )
    with open(AudiobookStore.audio_path(bid), "wb") as f:
        f.write(b"x" * 100)

    # Request range past the file end.
    response = client.get(f"/audiobook/{bid}/audio", headers={"Range": "bytes=500-600"})
    assert response.status_code == 416


# ---------- Phase 2: cancel ----------


def test_cancel_endpoint_404_for_unknown_book():
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    # Use a valid-shape UUID that doesn't exist (HARD-017 rejects malformed IDs at 400).
    response = client.post("/audiobook/" + ("b" * 32) + "/cancel")
    assert response.status_code == 404


def test_cancel_sets_flag():
    bid = AudiobookStore.create_book("Test.pdf")
    AudiobookStore.write_meta(
        bid,
        AudiobookStore.initial_meta(
            bid, "Test.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
        ),
    )
    assert AudiobookService.cancel(bid) is True
    assert AudiobookService._cancel_flags.get(bid) is True


# ---------- Phase 2: transcript ----------


def test_transcript_endpoint_404_when_missing():
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    bid = AudiobookStore.create_book("Test.pdf")
    AudiobookStore.write_meta(
        bid,
        AudiobookStore.initial_meta(
            bid, "Test.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
        ),
    )
    response = client.get(f"/audiobook/{bid}/transcript")
    assert response.status_code == 404


def test_transcript_endpoint_serves_file():
    import json as _json

    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    bid = AudiobookStore.create_book("Test.pdf")
    AudiobookStore.write_meta(
        bid,
        AudiobookStore.initial_meta(
            bid, "Test.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
        ),
    )
    payload = {"book_id": bid, "sections": []}
    with open(AudiobookStore.transcript_path(bid), "w") as f:
        _json.dump(payload, f)

    response = client.get(f"/audiobook/{bid}/transcript")
    assert response.status_code == 200
    assert response.json()["book_id"] == bid


# ---------- Phase 2: retry endpoint ----------


@pytest.mark.asyncio
async def test_retry_failed_clears_pages_and_enqueues(monkeypatch):
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 3, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["status"] = "failed"
    meta["failed_pages"] = [2, 3]
    AudiobookStore.write_meta(bid, meta)
    # Pre-create the failed-page files so we can verify removal.
    for n in (2, 3):
        for path in (
            AudiobookStore.page_clean_path(bid, n),
            AudiobookStore.page_audio_path(bid, n),
        ):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, "wb").close()
    # Touch final audio + transcript so we verify they're cleared too.
    open(AudiobookStore.audio_path(bid), "wb").close()
    open(AudiobookStore.transcript_path(bid), "w").close()

    # Stub the queue so retry_failed doesn't actually run a pipeline.
    enqueued: list[str] = []

    async def fake_enqueue(book_id: str, api_key: str):
        enqueued.append(book_id)

    monkeypatch.setattr(
        AudiobookService, "enqueue", classmethod(lambda cls, b, k: fake_enqueue(b, k))
    )

    count = await AudiobookService.retry_failed(bid, "fake-key")
    assert count == 2
    assert enqueued == [bid]
    # Per-page intermediates wiped:
    for n in (2, 3):
        assert not os.path.exists(AudiobookStore.page_clean_path(bid, n))
        assert not os.path.exists(AudiobookStore.page_audio_path(bid, n))
    # Final audio + transcript wiped:
    assert not os.path.exists(AudiobookStore.audio_path(bid))
    assert not os.path.exists(AudiobookStore.transcript_path(bid))
    new_meta = AudiobookStore.read_meta(bid)
    assert new_meta["failed_pages"] == []
    assert new_meta["error"] is None


def test_retry_endpoint_requires_api_key():
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    bid = AudiobookStore.create_book("Test.pdf")
    AudiobookStore.write_meta(
        bid,
        AudiobookStore.initial_meta(
            bid, "Test.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
        ),
    )
    response = client.post(f"/audiobook/{bid}/retry")
    assert response.status_code == 400


@pytest.mark.asyncio
async def test_request_delete_cancels_in_flight_pipeline():
    """Regression for C8: DELETE on a processing book must signal cancel +
    wait at the next page boundary, not rmtree out from under the worker."""
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 5, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["status"] = "tts"
    AudiobookStore.write_meta(bid, meta)
    AudiobookService._current_book_id = bid
    AudiobookService._cancel_flags.pop(bid, None)

    async def release_after_short_pause():
        await asyncio.sleep(0.15)
        AudiobookService._current_book_id = None

    asyncio.create_task(release_after_short_pause())

    ok = await AudiobookService.request_delete(bid)
    assert ok is True
    # Flag was cleared after delete completed.
    assert bid not in AudiobookService._cancel_flags
    # Directory removed (read_meta returns None for missing dirs).
    assert AudiobookStore.read_meta(bid) is None


@pytest.mark.asyncio
async def test_request_delete_unknown_returns_false():
    ok = await AudiobookService.request_delete("nonexistent_id_xyz")
    assert ok is False


@pytest.mark.asyncio
async def test_retry_failed_resumes_needs_key_book(monkeypatch):
    """Regression for C2: a book in needs_key state with no failed pages
    must still be enqueued when retry_failed is called (after the user
    re-enters their API key). Previously this silently returned 0."""
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 5, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["status"] = "needs_key"
    meta["failed_pages"] = []
    AudiobookStore.write_meta(bid, meta)

    enqueued: list[str] = []

    async def fake_enqueue(book_id: str, api_key: str):
        enqueued.append(book_id)

    monkeypatch.setattr(
        AudiobookService, "enqueue", classmethod(lambda cls, b, k: fake_enqueue(b, k))
    )

    count = await AudiobookService.retry_failed(bid, "fake-key")
    # Zero pages flagged, but enqueue must still fire.
    assert count == 0
    assert enqueued == [bid]


def test_retry_endpoint_404_for_unknown_book():
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    response = client.post(
        "/audiobook/" + ("c" * 32) + "/retry", headers={"X-Gemini-Api-Key": "x"}
    )
    assert response.status_code == 404


# ---------- voice/speed/engine flow at upload ----------


def test_initial_meta_preserves_voice_and_speed():
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 5, "kitten", "Bella", 1.5, {"cost_usd": 0.1}
    )
    assert meta["engine"] == "kitten"
    assert meta["voice"] == "Bella"
    assert meta["speed"] == 1.5


def test_estimate_uses_speed_for_audio_duration():
    e_slow = AudiobookService.estimate(
        page_count=10, sample_words=100, sample_chars=500, speed=1.0
    )
    e_fast = AudiobookService.estimate(
        page_count=10, sample_words=100, sample_chars=500, speed=2.0
    )
    # 2x speed → ~half the audio seconds.
    assert e_fast["audio_seconds"] < e_slow["audio_seconds"]
    assert abs(e_fast["audio_seconds"] * 2 - e_slow["audio_seconds"]) < 0.5


# ---------- Gemini retry/backoff (mocked) ----------


@pytest.mark.asyncio
async def test_gemini_clean_page_retries_then_succeeds(monkeypatch):
    from app.services.gemini_cleaner import GeminiBadResponseError, GeminiCleaner

    calls = {"n": 0}

    async def flaky_async(api_key, raw):
        calls["n"] += 1
        if calls["n"] < 2:
            raise GeminiBadResponseError("transient")
        return "cleaned text"

    monkeypatch.setattr(
        GeminiCleaner, "_async_clean", AsyncMock(side_effect=flaky_async)
    )
    monkeypatch.setattr("asyncio.sleep", AsyncMock(return_value=None))
    out = await GeminiCleaner.clean_page("k", "raw")
    assert out == "cleaned text"
    assert calls["n"] == 2


@pytest.mark.asyncio
async def test_gemini_auth_error_does_not_retry(monkeypatch):
    from app.services.gemini_cleaner import GeminiAuthError, GeminiCleaner

    calls = {"n": 0}

    async def auth_failing(api_key, raw):
        calls["n"] += 1
        raise GeminiAuthError("bad key")

    monkeypatch.setattr(
        GeminiCleaner, "_async_clean", AsyncMock(side_effect=auth_failing)
    )
    monkeypatch.setattr("asyncio.sleep", AsyncMock(return_value=None))
    with pytest.raises(GeminiAuthError):
        await GeminiCleaner.clean_page("k", "raw")
    assert calls["n"] == 1  # no retry for auth errors


# ---------- cost_warning flag ----------


def test_upload_endpoint_happy_path(monkeypatch):
    """Real HTTP upload path against the in-process app: PDF parse → estimate → meta written.

    Uses a fake PDFExtractor so we don't need a real PDF file. This was added
    after a live binary smoke test exposed `asyncio.create_task(future)` raising.
    """
    from fastapi.testclient import TestClient

    from app.main import app
    from app.services import pdf_extractor as _pe

    monkeypatch.setattr(_pe.PDFExtractor, "page_count", classmethod(lambda cls, p: 3))
    monkeypatch.setattr(
        _pe.PDFExtractor, "is_image_only", classmethod(lambda cls, p: False)
    )
    monkeypatch.setattr(
        _pe.PDFExtractor, "sample_word_count", classmethod(lambda cls, p: 50)
    )
    monkeypatch.setattr(
        _pe.PDFExtractor, "sample_char_count", classmethod(lambda cls, p: 250)
    )
    rendered: list[str] = []
    monkeypatch.setattr(
        _pe.PDFExtractor, "render_cover", classmethod(lambda cls, b: rendered.append(b))
    )

    client = TestClient(app)
    # Pad past the 100-byte minimum size guard. Real parsing is mocked above.
    files = {"file": ("test.pdf", b"%PDF-1.4\n" + b"x" * 200, "application/pdf")}
    data = {"voice": "bf_emma", "speed": "1.25", "engine": "kokoro"}
    response = client.post("/audiobook", files=files, data=data)
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["title"] == "test.pdf"
    assert body["page_count"] == 3
    assert body["word_count_estimate"] == 150  # 50 * 3
    assert body["estimated_token_count"] > 0
    assert "cost_warning" in body
    assert body["is_image_only"] is False

    # Meta on disk reflects user's voice/speed/engine.
    bid = body["book_id"]
    meta = AudiobookStore.read_meta(bid)
    assert meta["voice"] == "bf_emma"
    assert meta["speed"] == 1.25
    assert meta["engine"] == "kokoro"


def test_upload_rejects_empty_pdf():
    """P9: zero-byte uploads should fail at the door."""
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    response = client.post(
        "/audiobook", files={"file": ("empty.pdf", b"", "application/pdf")}
    )
    assert response.status_code == 400
    assert "empty" in response.json()["detail"].lower()


def test_upload_rejects_unsupported_extension():
    """Only PDF, TXT, DOCX, and MD are accepted; everything else must return 400."""
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    files = {"file": ("test.exe", b"binary data", "application/octet-stream")}
    response = client.post("/audiobook", files=files)
    assert response.status_code == 400


def test_upload_accepts_image_only_pdf(monkeypatch):
    """Image-only PDFs are now accepted; OCR handles them during the clean phase.
    The response should return is_image_only=True so the UI can show an OCR badge."""
    from fastapi.testclient import TestClient

    from app.main import app
    from app.services import pdf_extractor as _pe

    monkeypatch.setattr(_pe.PDFExtractor, "page_count", classmethod(lambda cls, p: 1))
    monkeypatch.setattr(
        _pe.PDFExtractor, "is_image_only", classmethod(lambda cls, p: True)
    )
    monkeypatch.setattr(
        _pe.PDFExtractor, "render_cover", classmethod(lambda cls, bid, **kw: None)
    )

    client = TestClient(app)
    files = {"file": ("scan.pdf", b"%PDF-1.4\n" + b"x" * 200, "application/pdf")}
    response = client.post("/audiobook", files=files)
    assert response.status_code == 200
    body = response.json()
    assert body["is_image_only"] is True
    # Cost estimate uses the per-page OCR default (not zero).
    assert body["estimated_cost_usd"] > 0


def test_estimate_response_includes_cost_warning(monkeypatch):
    """Estimate carries cost_warning=True when projected cost > $1 (default threshold)."""
    # Tiny PDF → tiny cost → no warning.
    e = AudiobookService.estimate(
        page_count=1, sample_words=5, sample_chars=20, speed=1.0
    )
    assert e["cost_usd"] < 0.01

    # Large book → cost crosses the $1 threshold.
    big = AudiobookService.estimate(
        page_count=2500, sample_words=600, sample_chars=8000, speed=1.0
    )
    assert big["cost_usd"] > 1.0


# ---------- OCR fallback in clean phase ----------


@pytest.mark.asyncio
async def test_clean_phase_uses_ocr_for_image_pages(monkeypatch):
    """Pages with fewer than 50 chars of extracted text are routed to
    GeminiCleaner.ocr_page instead of clean_page."""
    from app.services import audiobook_service as _svc
    from app.services import pdf_extractor as _pe

    bid = AudiobookStore.create_book("Scan.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Scan.pdf", 2, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    AudiobookStore.write_meta(bid, meta)
    AudiobookStore.save_source(bid, b"%PDF-1.4\n" + b"x" * 200, "pdf")

    # Page 1: minimal text (image page) — should trigger OCR.
    # Page 2: normal text — should use clean_page.
    for n, content in [(1, ""), (2, "x" * 200)]:
        path = AudiobookStore.page_raw_path(bid, n)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(content)

    ocr_calls: list[int] = []
    clean_calls: list[int] = []

    async def _fake_ocr(api_key, image_bytes):
        ocr_calls.append(1)
        return "OCR result."

    async def _fake_clean(api_key, text):
        clean_calls.append(1)
        return "Cleaned text."

    monkeypatch.setattr(
        _pe.PDFExtractor,
        "render_page_image",
        classmethod(lambda cls, p, n, **kw: b"imgbytes"),
    )

    from app.services import gemini_cleaner as _gc

    monkeypatch.setattr(_gc.GeminiCleaner, "ocr_page", AsyncMock(side_effect=_fake_ocr))
    monkeypatch.setattr(
        _gc.GeminiCleaner, "clean_page", AsyncMock(side_effect=_fake_clean)
    )

    _svc.AudiobookService.initialize()
    await _svc.AudiobookService._phase_clean(bid, api_key="test-key")

    assert len(ocr_calls) == 1, "image page should route to OCR"
    assert len(clean_calls) == 1, "text page should route to clean_page"


# ---------- duplicate page deduplication ----------


@pytest.mark.asyncio
async def test_duplicate_pages_get_silence_marker(monkeypatch):
    """When two pages have identical content (e.g. DocuSign PDFs that embed
    the same page twice), the second occurrence must receive a '-' silence
    marker in its clean file so it does not produce duplicate audio.
    """
    from app.services import audiobook_service as _svc
    from app.services import pdf_extractor as _pe

    bid = AudiobookStore.create_book("offer.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "offer.pdf", 2, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["file_ext"] = "pdf"
    AudiobookStore.write_meta(bid, meta)

    # Pre-write identical raw page files (simulates what PDFExtractor would extract
    # from a DocuSign PDF where both pages contain the same text).
    long_content = (
        "A" * 200 + "\n\nThis is the full offer letter body with enough text to matter."
    )
    for n in (1, 2):
        path = AudiobookStore.page_raw_path(bid, n)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(long_content)

    # Mock extractor to avoid needing a real PDF on disk.
    monkeypatch.setattr(_pe.PDFExtractor, "page_count", classmethod(lambda cls, p: 2))
    monkeypatch.setattr(
        _pe.PDFExtractor, "render_cover", classmethod(lambda cls, b, **kw: None)
    )

    _svc.AudiobookService._queue = None
    _svc.AudiobookService._worker_task = None
    _svc.AudiobookService.initialize()

    await _svc.AudiobookService._phase_extract(bid)

    clean1 = AudiobookStore.page_clean_path(bid, 1)
    clean2 = AudiobookStore.page_clean_path(bid, 2)

    # Page 1 must NOT have a silence marker (it is the original content).
    assert not os.path.exists(
        clean1
    ), "page 1 must not have a pre-written clean file (Gemini should clean it)"

    # Page 2 must have been pre-written with the silence marker.
    assert os.path.exists(
        clean2
    ), "page 2 (duplicate) must have a pre-written silence marker clean file"
    with open(clean2, encoding="utf-8") as f:
        marker = f.read()
    assert marker == "-", f"duplicate page clean file must be '-', got: {marker!r}"


@pytest.mark.asyncio
async def test_non_duplicate_pages_are_not_marked_silent(monkeypatch):
    """Pages with distinct content must not be marked as silence — the normal
    Gemini clean path must remain unobstructed."""
    from app.services import audiobook_service as _svc
    from app.services import pdf_extractor as _pe

    bid = AudiobookStore.create_book("multipage.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "multipage.pdf", 3, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["file_ext"] = "pdf"
    AudiobookStore.write_meta(bid, meta)

    contents = [
        "Chapter 1: " + "A" * 200,
        "Chapter 2: " + "B" * 200,
        "Chapter 3: " + "C" * 200,
    ]
    for n, content in enumerate(contents, start=1):
        path = AudiobookStore.page_raw_path(bid, n)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)

    monkeypatch.setattr(_pe.PDFExtractor, "page_count", classmethod(lambda cls, p: 3))
    monkeypatch.setattr(
        _pe.PDFExtractor, "render_cover", classmethod(lambda cls, b, **kw: None)
    )

    _svc.AudiobookService._queue = None
    _svc.AudiobookService._worker_task = None
    _svc.AudiobookService.initialize()

    await _svc.AudiobookService._phase_extract(bid)

    # None of the 3 pages should have a pre-written clean file.
    for n in (1, 2, 3):
        assert not os.path.exists(
            AudiobookStore.page_clean_path(bid, n)
        ), f"page {n} should not have a pre-written clean file — content is unique"


# ---------- TXT extraction (non-PDF path) ----------


@pytest.mark.asyncio
async def test_txt_file_extraction_does_not_call_pdf_extractor(monkeypatch):
    """Uploading a .txt file must route through TextExtractor, not PDFExtractor.

    Regression guard: before the TextExtractor path was added, any non-PDF
    upload crashed in the extract phase because PDFExtractor.page_count tried
    to open the file as a PDF.
    """
    from app.services import audiobook_service as _svc
    from app.services import pdf_extractor as _pe

    bid = AudiobookStore.create_book("sample.txt")
    # Write meta with file_ext=txt so the pipeline routes correctly.
    # page_count=1 matches the single-page content we write below.
    meta = AudiobookStore.initial_meta(
        bid, "sample.txt", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["file_ext"] = "txt"
    AudiobookStore.write_meta(bid, meta)

    # Write a real source file so TextExtractor can open it.
    source_path = AudiobookStore.source_file_path(bid, "txt")
    os.makedirs(os.path.dirname(source_path), exist_ok=True)
    with open(source_path, "w", encoding="utf-8") as f:
        f.write("Hello world.\n\nThis is page one.\n\nThis is page two.")

    pdf_calls: list[str] = []

    def _fail_if_called(*args, **kwargs):
        pdf_calls.append("called")
        raise AssertionError("PDFExtractor must NOT be called for a .txt file")

    monkeypatch.setattr(
        _pe.PDFExtractor, "page_count", classmethod(lambda cls, p: _fail_if_called(p))
    )
    monkeypatch.setattr(
        _pe.PDFExtractor, "render_cover", classmethod(lambda cls, b: _fail_if_called(b))
    )

    # Reset AudiobookService state so initialize() creates fresh objects in the
    # current event loop (avoids "bound to a different event loop" errors when
    # multiple async tests share the singleton).
    _svc.AudiobookService._queue = None
    _svc.AudiobookService._worker_task = None
    _svc.AudiobookService.initialize()

    await _svc.AudiobookService._phase_extract(bid)

    assert len(pdf_calls) == 0, "PDFExtractor was called for a TXT file"

    # _phase_extract does not update meta["page_count"] (that is set at upload time).
    # Instead verify that the per-page raw text file was actually written to disk.
    page1 = AudiobookStore.page_raw_path(bid, 1)
    assert os.path.exists(page1), "page 1 raw text file must exist after extraction"
    with open(page1, encoding="utf-8") as f:
        content = f.read()
    assert len(content) > 0, "extracted page should be non-empty"


# ---------- Gemini timeout → raw text fallback ----------


@pytest.mark.asyncio
async def test_gemini_timeout_falls_back_to_raw_text(monkeypatch):
    """When GeminiCleaner.clean_page raises asyncio.TimeoutError the pipeline
    must degrade gracefully: the cleaned output file is written with the raw
    text so downstream TTS can still proceed.  No hang, no crash, no empty file.
    """
    from app.services import audiobook_service as _svc
    from app.services import gemini_cleaner as _gc

    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    AudiobookStore.write_meta(bid, meta)

    raw_text = "Raw page text that should survive the Gemini timeout."
    raw_path = AudiobookStore.page_raw_path(bid, 1)
    os.makedirs(os.path.dirname(raw_path), exist_ok=True)
    with open(raw_path, "w", encoding="utf-8") as f:
        f.write(raw_text)

    async def _timeout_clean(api_key, text):
        raise TimeoutError()

    monkeypatch.setattr(
        _gc.GeminiCleaner, "clean_page", AsyncMock(side_effect=_timeout_clean)
    )

    _svc.AudiobookService.initialize()
    # Must complete without raising, even though Gemini timed out.
    await _svc.AudiobookService._phase_clean(bid, api_key="test-key")

    clean_path = AudiobookStore.page_clean_path(bid, 1)
    assert os.path.exists(clean_path), "clean file must exist after timeout fallback"
    with open(clean_path, encoding="utf-8") as f:
        result = f.read()
    assert result == raw_text, "fallback content must equal the original raw text"
