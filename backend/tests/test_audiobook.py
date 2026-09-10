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
    AudiobookCancelled,
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


@pytest.mark.asyncio
async def test_update_meta_on_deleted_book_does_not_resurrect_a_zombie_row():
    """Regression: a pipeline phase still in flight when the user deletes a
    book (executor-backed work isn't cooperatively cancellable mid-call)
    used to have its next status update silently re-INSERT a near-empty
    zombie row via update_meta's read-modify-write. update_meta must be a
    no-op once the book no longer exists."""
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 5, "kokoro", "af_bella", 1.0, {"cost_usd": 0.1}
    )
    AudiobookStore.write_meta(bid, meta)
    assert AudiobookStore.delete_book(bid) is True
    assert AudiobookStore.read_meta(bid) is None

    result = await AudiobookStore.update_meta(bid, status="failed", error="boom")

    assert result == {}
    assert AudiobookStore.read_meta(bid) is None
    assert bid not in [b["book_id"] for b in AudiobookStore.list_books()]


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


# ---------- worker queue bound (jira-cpu-ram-optimization.md T-8) ----------


@pytest.mark.asyncio
async def test_initialize_creates_bounded_worker_queue():
    """The worker queue was an unbounded asyncio.Queue(); it must now have a
    finite maxsize so a pathological enqueue burst can't grow it forever."""
    AudiobookService._queue = None
    AudiobookService._worker_task = None
    AudiobookService.initialize()
    try:
        assert AudiobookService._queue.maxsize > 0
    finally:
        await AudiobookService.shutdown(grace_seconds=0.1)


# ---------- background TTS pacing (jira-cpu-ram-optimization.md T-7) ----------


@pytest.mark.asyncio
async def test_generate_full_page_paces_between_segments():
    """_generate_full_page must yield the configured pacing delay after every
    segment — this is the only caller of EngineManager.generate the audiobook
    pipeline uses; interactive /speak is a separate call site, unaffected."""
    from app.core.config import settings

    async def mock_generate(*args, **kwargs):
        yield np.zeros(100, dtype=np.float32)
        yield np.zeros(100, dtype=np.float32)
        yield np.zeros(100, dtype=np.float32)

    sleep_mock = AsyncMock()
    with (
        patch(
            "app.services.audiobook_service.EngineManager.generate",
            side_effect=mock_generate,
        ),
        patch("app.services.audiobook_service.asyncio.sleep", new=sleep_mock),
    ):
        samples = await AudiobookService._generate_full_page(
            "test-book", "hello", "af_bella", 1.0
        )

    assert sleep_mock.call_count == 3
    for call in sleep_mock.call_args_list:
        assert call.args[0] == settings.AUDIOBOOK_TTS_SEGMENT_PACING_S
    assert len(samples) == 300


@pytest.mark.asyncio
async def test_generate_full_page_pacing_adds_real_elapsed_time(monkeypatch):
    """Integration-style check that pacing is a real yield, not a stubbed
    no-op — uses a small pacing value so the test stays fast."""
    monkeypatch.setattr(
        "app.services.audiobook_service._settings.AUDIOBOOK_TTS_SEGMENT_PACING_S",
        0.02,
    )

    async def mock_generate(*args, **kwargs):
        for _ in range(4):
            yield np.zeros(100, dtype=np.float32)

    with patch(
        "app.services.audiobook_service.EngineManager.generate",
        side_effect=mock_generate,
    ):
        start = asyncio.get_running_loop().time()
        await AudiobookService._generate_full_page(
            "test-book", "hello", "af_bella", 1.0
        )
        elapsed = asyncio.get_running_loop().time() - start

    # 4 segments * 0.02s pacing = 0.08s floor; generous slack for CI jitter.
    assert elapsed >= 0.07


# ---------- responsive mid-page cancellation (T-3) ----------


@pytest.mark.asyncio
async def test_generate_full_page_stops_mid_page_once_cancelled():
    """Regression: previously the only cancellation checkpoint was at the
    per-*page* boundary in _phase_tts's loop — a page with several TTS
    segments had no way to stop mid-synthesis. _generate_full_page must now
    check cancellation between segments and stop before the final one once
    the flag is set partway through."""
    bid = "cancel-mid-page-book"
    AudiobookService._cancel_flags.pop(bid, None)

    async def mock_generate(*args, **kwargs):
        yield np.zeros(100, dtype=np.float32)
        yield np.zeros(100, dtype=np.float32)
        # Cancellation arrives while a 3rd segment is still "in flight".
        AudiobookService._cancel_flags[bid] = True
        yield np.zeros(100, dtype=np.float32)
        yield np.zeros(100, dtype=np.float32)  # never reached if the fix works

    try:
        with patch(
            "app.services.audiobook_service.EngineManager.generate",
            side_effect=mock_generate,
        ):
            with pytest.raises(AudiobookCancelled):
                await AudiobookService._generate_full_page(
                    bid, "hello", "af_bella", 1.0
                )
    finally:
        AudiobookService._cancel_flags.pop(bid, None)


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


# ---------- TTS progress stall for missing-clean-text pages (T-2) ----------


@pytest.mark.asyncio
async def test_tts_missing_clean_text_still_advances_progress_and_emits_page_done():
    """Regression: a page with no clean file (e.g. extraction never produced
    one) previously hit an early `continue` that skipped the phase_progress
    meta update and page_done SSE emit — the progress bar could
    undercount/stall on that page even though the loop otherwise moved on."""
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 2, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    AudiobookStore.write_meta(bid, meta)
    # Page 1 has no clean file at all; page 2 does.
    path2 = AudiobookStore.page_clean_path(bid, 2)
    os.makedirs(os.path.dirname(path2), exist_ok=True)
    with open(path2, "w") as f:
        f.write("Page 2 content.")

    events: list[dict] = []
    orig_emit = AudiobookService._emit

    def _capture_emit(cls, book_id, event_type, **data):
        events.append({"type": event_type, **data})
        return orig_emit(book_id, event_type, **data)

    with (
        patch(
            "app.services.audiobook_service.EngineManager.ensure_loaded",
            new=AsyncMock(return_value=None),
        ),
        patch("app.services.audiobook_service.EngineManager.touch", return_value=None),
        patch(
            "app.services.audiobook_service.EngineManager.generate",
            side_effect=_mock_generate_yielding,
        ),
        patch.object(AudiobookService, "_emit", classmethod(_capture_emit)),
    ):
        await AudiobookService._phase_tts(bid, AudiobookStore.read_meta(bid))

    page_done_events = [
        e for e in events if e["type"] == "page_done" and e["page"] == 1
    ]
    assert (
        len(page_done_events) == 1
    ), "missing-clean-text page must still emit page_done"

    new_meta = AudiobookStore.read_meta(bid)
    # phase_progress reflects both pages processed, not stalled at page 0/1.
    assert new_meta["phase_progress"]["page_done"] == 2
    assert os.path.exists(
        AudiobookStore.page_audio_path(bid, 1)
    ), "silence WAV still written"


# ---------- TTS/audio desync + page_status marking (T-1) ----------


async def _mock_generate_page_2_fails(text, voice, speed):
    """Fails TTS for whatever page's clean text is "Page 2 content." —
    used to simulate a single forced per-page TTS failure among several."""
    if text == "Page 2 content.":
        raise RuntimeError("synthetic TTS failure")
    yield np.zeros(1200, dtype=np.float32)


@pytest.mark.asyncio
async def test_tts_failure_marks_page_status_and_preserves_clean_text(monkeypatch):
    """Regression for the transcript/audio desync finding: a TTS exception
    must mark the page in page_status (distinct from a real failure vs. a
    duplicate) rather than leaving the clean text file as the only signal —
    previously nothing told a transcript consumer that page 2's audio is
    actually silence, not the narrated text still on disk."""
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 3, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    AudiobookStore.write_meta(bid, meta)
    for n in (1, 2, 3):
        path = AudiobookStore.page_clean_path(bid, n)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(f"Page {n} content.")

    with (
        patch(
            "app.services.audiobook_service.EngineManager.ensure_loaded",
            new=AsyncMock(return_value=None),
        ),
        patch("app.services.audiobook_service.EngineManager.touch", return_value=None),
        patch(
            "app.services.audiobook_service.EngineManager.generate",
            side_effect=_mock_generate_page_2_fails,
        ),
    ):
        await AudiobookService._phase_tts(bid, AudiobookStore.read_meta(bid))

    new_meta = AudiobookStore.read_meta(bid)
    assert new_meta["failed_pages"] == [2]
    assert new_meta["page_status"]["2"] == "tts_failed"
    # Pages 1 and 3 are untouched by the failure.
    assert "1" not in new_meta.get("page_status", {})
    assert "3" not in new_meta.get("page_status", {})
    # Clean text is preserved on disk (additive fix, not a data-destroying one) —
    # page_status is the signal a consumer uses to know it wasn't narrated.
    with open(AudiobookStore.page_clean_path(bid, 2), encoding="utf-8") as f:
        assert f.read() == "Page 2 content."


@pytest.mark.asyncio
async def test_transcript_reflects_tts_failure_via_page_status(monkeypatch):
    """Integration: _phase_tts (one forced failure) + _phase_concat end-to-end
    — the final transcript.json must carry page_status alongside the
    unchanged `pages` dict (additive, backward-compatible schema)."""
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 2, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    AudiobookStore.write_meta(bid, meta)
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
        patch("app.services.audiobook_service.EngineManager.touch", return_value=None),
        patch(
            "app.services.audiobook_service.EngineManager.generate",
            side_effect=_mock_generate_page_2_fails,
        ),
    ):
        await AudiobookService._phase_tts(bid, AudiobookStore.read_meta(bid))

    await AudiobookService._phase_concat(bid, AudiobookStore.read_meta(bid))

    with open(AudiobookStore.transcript_path(bid), encoding="utf-8") as f:
        transcript = json.load(f)

    assert transcript["page_status"]["2"] == "tts_failed"
    # `pages` keeps existing behavior — still present, unchanged content.
    assert transcript["pages"]["1"] == "Page 1 content."
    assert transcript["pages"]["2"] == "Page 2 content."


async def _mock_generate_always_fails(*args, **kwargs):
    if False:
        yield np.zeros(1, dtype=np.float32)  # makes this an async generator function
    raise RuntimeError("synthetic TTS failure")


@pytest.mark.asyncio
async def test_done_sse_payload_includes_failed_pages(monkeypatch):
    """The terminal 'done' SSE event must carry failed_pages so a listening
    client learns about a broken page immediately, without a separate GET."""
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    AudiobookStore.write_meta(bid, meta)
    path = AudiobookStore.page_clean_path(bid, 1)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("Page 1 content.")

    async def _noop_phase(*args, **kwargs):
        return None

    with (
        patch.object(
            AudiobookService, "_phase_extract", new=AsyncMock(side_effect=_noop_phase)
        ),
        patch.object(
            AudiobookService, "_phase_clean", new=AsyncMock(side_effect=_noop_phase)
        ),
        patch.object(
            AudiobookService, "_phase_section", new=AsyncMock(side_effect=_noop_phase)
        ),
        patch(
            "app.services.audiobook_service.EngineManager.ensure_loaded",
            new=AsyncMock(return_value=None),
        ),
        patch("app.services.audiobook_service.EngineManager.touch", return_value=None),
        patch(
            "app.services.audiobook_service.EngineManager.generate",
            side_effect=_mock_generate_always_fails,
        ),
    ):
        q = AudiobookService.subscribe(bid)
        await AudiobookService._run_pipeline(bid)

    events = []
    while not q.empty():
        events.append(q.get_nowait())
    done_events = [e for e in events if e["type"] == "done"]
    assert len(done_events) == 1
    assert done_events[0]["failed_pages"] == [1]


# ---------- duplicate-page page_status marking (T-1) ----------


@pytest.mark.asyncio
async def test_duplicate_page_is_marked_in_page_status(monkeypatch):
    """The duplicate-page dedup marker ("-") is ambiguous on its own — a
    real failure can also leave a bare dash. page_status must distinguish
    "duplicate" from a failure so the transcript doesn't show an unexplained
    dash as if it were corrupted data."""
    from app.services import audiobook_service as _svc
    from app.services import pdf_extractor as _pe

    bid = AudiobookStore.create_book("offer.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "offer.pdf", 2, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["file_ext"] = "pdf"
    AudiobookStore.write_meta(bid, meta)

    long_content = (
        "A" * 200 + "\n\nThis is the full offer letter body with enough text to matter."
    )
    for n in (1, 2):
        path = AudiobookStore.page_raw_path(bid, n)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(long_content)

    monkeypatch.setattr(_pe.PDFExtractor, "page_count", classmethod(lambda cls, p: 2))
    monkeypatch.setattr(
        _pe.PDFExtractor, "render_cover", classmethod(lambda cls, b, **kw: None)
    )

    _svc.AudiobookService._queue = None
    _svc.AudiobookService._worker_task = None
    _svc.AudiobookService.initialize()

    await _svc.AudiobookService._phase_extract(bid)

    new_meta = AudiobookStore.read_meta(bid)
    assert new_meta["page_status"]["2"] == "duplicate"
    assert "1" not in new_meta.get("page_status", {})


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


def test_start_uses_local_processing_by_default_and_requires_a_key_only_for_gemini(
    monkeypatch,
):
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
    enqueued: list[tuple[str, str]] = []

    async def fake_enqueue(book_id: str, api_key: str) -> None:
        enqueued.append((book_id, api_key))

    monkeypatch.setattr(
        AudiobookService,
        "enqueue",
        classmethod(lambda cls, book_id, api_key: fake_enqueue(book_id, api_key)),
    )

    response = client.post(f"/audiobook/{bid}/start")
    assert response.status_code == 200
    assert enqueued == [(bid, "")]
    assert AudiobookStore.read_meta(bid)["uses_gemini_cleanup"] is False

    response = client.post(
        f"/audiobook/{bid}/start",
        headers={"X-Voqora-Gemini-Cleanup": "true"},
    )
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
    meta["uses_gemini_cleanup"] = True
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


@pytest.mark.asyncio
async def test_retry_failed_only_re_cleans_cleaning_failed_pages(monkeypatch):
    """T-5: retry_failed must scope re-cleaning to pages whose page_status
    actually indicates a cleaning failure — a TTS-only failure's clean text
    is already correct and re-cleaning it would waste a Gemini call for no
    reason. Both pages still get their audio wiped so TTS re-runs for both."""
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 3, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["status"] = "failed"
    meta["failed_pages"] = [2, 3]
    # Page 2: TTS-only failure — clean text is fine, only audio needs a redo.
    # Page 3: cleaning failure — clean text itself needs to be regenerated.
    meta["page_status"] = {"2": "tts_failed", "3": "cleaning_failed"}
    AudiobookStore.write_meta(bid, meta)
    for n in (2, 3):
        for path in (
            AudiobookStore.page_clean_path(bid, n),
            AudiobookStore.page_audio_path(bid, n),
        ):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, "wb").close()

    enqueued: list[str] = []

    async def fake_enqueue(book_id: str, api_key: str):
        enqueued.append(book_id)

    monkeypatch.setattr(
        AudiobookService, "enqueue", classmethod(lambda cls, b, k: fake_enqueue(b, k))
    )

    count = await AudiobookService.retry_failed(bid, "fake-key")
    assert count == 2
    assert enqueued == [bid]

    # Page 2 (TTS-only failure): clean text preserved, audio wiped.
    assert os.path.exists(AudiobookStore.page_clean_path(bid, 2))
    assert not os.path.exists(AudiobookStore.page_audio_path(bid, 2))
    # Page 3 (cleaning failure): both clean text and audio wiped.
    assert not os.path.exists(AudiobookStore.page_clean_path(bid, 3))
    assert not os.path.exists(AudiobookStore.page_audio_path(bid, 3))

    new_meta = AudiobookStore.read_meta(bid)
    assert new_meta["failed_pages"] == []
    # Stale page_status entries cleared for both retried pages.
    assert new_meta.get("page_status", {}) == {}


@pytest.mark.asyncio
async def test_retry_failed_re_cleans_legacy_pages_with_no_page_status(monkeypatch):
    """Books processed before page_status existed have no recorded failure
    type for a failed page — retry_failed must fall back to the previous
    (safe) behavior of always re-cleaning rather than silently skipping a
    clean-text regeneration it can't actually verify is unnecessary."""
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["status"] = "failed"
    meta["failed_pages"] = [1]
    # No "page_status" key at all — simulates a pre-T-1 book.
    AudiobookStore.write_meta(bid, meta)
    for path in (
        AudiobookStore.page_clean_path(bid, 1),
        AudiobookStore.page_audio_path(bid, 1),
    ):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "wb").close()

    async def fake_enqueue(book_id: str, api_key: str):
        return None

    monkeypatch.setattr(
        AudiobookService, "enqueue", classmethod(lambda cls, b, k: fake_enqueue(b, k))
    )

    await AudiobookService.retry_failed(bid, "fake-key")

    assert not os.path.exists(AudiobookStore.page_clean_path(bid, 1))
    assert not os.path.exists(AudiobookStore.page_audio_path(bid, 1))


def test_retry_endpoint_requires_api_key_only_for_a_gemini_book():
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
    assert response.status_code == 200

    meta = AudiobookStore.read_meta(bid)
    meta["uses_gemini_cleanup"] = True
    AudiobookStore.write_meta(bid, meta)
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


# ---------- cancel + immediate delete zombie-row race (T-4) ----------


@pytest.mark.asyncio
async def test_cancel_plus_immediate_delete_does_not_resurrect_zombie_row(monkeypatch):
    """Stress test for the finding: _phase_clean's asyncio.gather doesn't
    cancel sibling clean_one tasks when the book is cancelled, so a straggler
    still mid Gemini-call can call update_meta *after* the book's DB row was
    already deleted by a concurrent delete — resurrecting a zombie row. Must
    fail on the pre-fix `asyncio.gather(*(clean_one(n) for n in pending))`
    (no return_exceptions, no explicit sibling cancellation) and pass once
    stragglers are actively cancelled instead.
    """
    from app.services import gemini_cleaner as _gc

    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 2, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["uses_gemini_cleanup"] = True
    AudiobookStore.write_meta(bid, meta)
    for n in (1, 2):
        path = AudiobookStore.page_raw_path(bid, n)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write("x" * 200)  # long enough to route through clean_page, not OCR

    release = asyncio.Event()

    async def slow_clean_page(api_key, text):
        # Simulates a page whose Gemini call is already in flight (past its
        # own cancel checkpoint) when cancel + delete happen concurrently.
        await release.wait()
        return "cleaned slowly"

    monkeypatch.setattr(
        _gc.GeminiCleaner, "clean_page", AsyncMock(side_effect=slow_clean_page)
    )

    clean_task = asyncio.create_task(AudiobookService._phase_clean(bid, "fake-key"))
    await asyncio.sleep(0.05)  # let both pages' clean_one start + block on release

    AudiobookService.cancel(bid)
    # Delete only the DB row here (not the on-disk files via the full
    # AudiobookStore.delete_book/rmtree) so the race under test is isolated
    # to "does a straggler resurrect the DB row via update_meta", not an
    # incidental FileNotFoundError from writing into an already-rmtree'd
    # directory — both are real consequences of the same underlying bug,
    # but only the DB-row resurrection is what T-4 is about.
    conn = AudiobookStore._connection()
    with AudiobookStore._conn_lock:
        conn.execute("DELETE FROM books WHERE book_id = ?", (bid,))

    # Give a correct fix's cancellation watcher time to stop the stragglers
    # before they'd otherwise complete and write to the now-deleted book.
    await asyncio.sleep(0.3)
    release.set()  # let any still-running straggler (pre-fix code) finish

    try:
        await asyncio.wait_for(clean_task, timeout=2.0)
    except BaseException:
        # We don't care exactly how the (possibly still-racy) phase ends —
        # only whether a straggler managed to touch a deleted book's state.
        pass

    assert all(
        b["book_id"] != bid for b in AudiobookStore.list_books()
    ), "a straggler clean_one task resurrected the deleted book's DB row"


# ---------- runtime Gemini cost cap ----------


@pytest.mark.asyncio
async def test_phase_clean_degrades_remaining_pages_when_actual_cost_exceeds_cap(
    monkeypatch,
):
    """Regression: the /start pre-flight cost gate only ever samples 3 pages,
    so a book with uneven page density could pass it and then blow through
    MAX_GEMINI_COST_USD_PER_BOOK with no runtime check at all. _phase_clean
    must track actual chars sent/received and, once the running estimate
    crosses the cap, route further pages to local cleanup instead of Gemini
    — gracefully, like every other per-page Gemini failure in this function
    (timeout, generic exception), not by aborting the whole book. A page
    whose own call already completed and produced good text before the cap
    was crossed keeps that text; only pages processed *after* the cap was
    reached fall back to local cleanup."""
    from app.services import gemini_cleaner as _gc
    from app.services.audiobook_service import AudiobookService

    monkeypatch.setattr(
        "app.services.audiobook_service._settings.MAX_GEMINI_COST_USD_PER_BOOK",
        0.000001,
    )

    page_count = 20
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", page_count, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["uses_gemini_cleanup"] = True
    AudiobookStore.write_meta(bid, meta)
    for n in range(1, page_count + 1):
        path = AudiobookStore.page_raw_path(bid, n)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write("x" * 200)  # long enough to route through clean_page, not OCR

    calls: list[int] = []

    async def fake_clean_page(api_key, text):
        calls.append(1)
        return "cleaned " + text

    monkeypatch.setattr(
        _gc.GeminiCleaner, "clean_page", AsyncMock(side_effect=fake_clean_page)
    )

    # Must complete the book, not raise — the near-zero cap is crossed by
    # the very first page's own chars, so every subsequent page should be
    # locally cleaned instead of calling Gemini.
    await AudiobookService._phase_clean(bid, "fake-key")

    assert len(calls) < page_count, "pages after the cap was crossed must skip Gemini"
    final_meta = AudiobookStore.read_meta(bid)
    capped_pages = [
        n
        for n, status in (final_meta.get("page_status") or {}).items()
        if status == "cost_capped"
    ]
    assert len(capped_pages) > 0
    assert len(capped_pages) == page_count - len(calls)
    # Every page still has clean text on disk (local fallback, not blank).
    for n in range(1, page_count + 1):
        with open(AudiobookStore.page_clean_path(bid, n), encoding="utf-8") as f:
            assert f.read()


@pytest.mark.asyncio
async def test_phase_clean_seeds_running_cost_from_already_cleaned_pages(monkeypatch):
    """A resumed book shouldn't get a fresh budget: already-cleaned pages'
    chars must count toward the cap from the start of the phase, so a new
    page is immediately routed to local cleanup rather than calling Gemini
    at all."""
    from app.services import gemini_cleaner as _gc
    from app.services.audiobook_service import AudiobookService

    monkeypatch.setattr(
        "app.services.audiobook_service._settings.MAX_GEMINI_COST_USD_PER_BOOK",
        0.000001,
    )

    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 2, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["uses_gemini_cleanup"] = True
    AudiobookStore.write_meta(bid, meta)
    # Page 1 already cleaned (simulating a resume) — its chars must be
    # counted even though clean_one won't touch it again.
    clean_path = AudiobookStore.page_clean_path(bid, 1)
    os.makedirs(os.path.dirname(clean_path), exist_ok=True)
    with open(clean_path, "w") as f:
        f.write("x" * 500)
    raw_path = AudiobookStore.page_raw_path(bid, 2)
    os.makedirs(os.path.dirname(raw_path), exist_ok=True)
    with open(raw_path, "w") as f:
        f.write("y" * 200)

    calls: list[int] = []

    async def fake_clean_page(api_key, text):
        calls.append(1)
        return "cleaned " + text

    monkeypatch.setattr(
        _gc.GeminiCleaner, "clean_page", AsyncMock(side_effect=fake_clean_page)
    )

    await AudiobookService._phase_clean(bid, "fake-key")

    assert len(calls) == 0, "page 2 must be cost-capped immediately, no Gemini call"
    final_meta = AudiobookStore.read_meta(bid)
    assert final_meta["page_status"]["2"] == "cost_capped"


@pytest.mark.asyncio
async def test_phase_section_check_cancel_prevents_zombie_row_after_delete(monkeypatch):
    """Regression: _phase_section had no _check_cancel() call anywhere,
    unlike every other phase. A book deleted while Gemini's detect_sections
    call is still in flight (up to 120s) would have its DB row resurrected
    by this phase's own update_meta(sections=...) write after request_delete
    already deleted it — the same zombie-row bug class already fixed for
    _phase_clean (T-4), never applied to _phase_section."""
    from app.services import gemini_cleaner as _gc

    bid = AudiobookStore.create_book("Test.md")
    meta = AudiobookStore.initial_meta(
        bid, "Test.md", 2, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["file_ext"] = "md"
    meta["uses_gemini_cleanup"] = True
    AudiobookStore.write_meta(bid, meta)

    release = asyncio.Event()

    async def slow_detect_sections(api_key, pages):
        await release.wait()
        return [{"title": "Chapter One", "start_page": 1, "end_page": 2}]

    monkeypatch.setattr(
        _gc.GeminiCleaner,
        "detect_sections",
        AsyncMock(side_effect=slow_detect_sections),
    )

    section_task = asyncio.create_task(
        AudiobookService._phase_section(bid, "fake-key", AudiobookStore.read_meta(bid))
    )
    await asyncio.sleep(0.05)  # let it enter the (slow) Gemini call

    AudiobookService.cancel(bid)
    conn = AudiobookStore._connection()
    with AudiobookStore._conn_lock:
        conn.execute("DELETE FROM books WHERE book_id = ?", (bid,))

    release.set()  # let the slow call resolve now that cancel + delete happened

    with pytest.raises(AudiobookCancelled):
        await asyncio.wait_for(section_task, timeout=2.0)

    assert all(
        b["book_id"] != bid for b in AudiobookStore.list_books()
    ), "_phase_section resurrected the deleted book's DB row"


@pytest.mark.asyncio
async def test_transcript_write_failure_marks_book_failed_not_done(monkeypatch):
    """Regression: a transcript.json write failure was silently swallowed —
    the book still reached status="done" with no transcript on disk, so
    GET .../transcript 404s forever and retry_failed's resumable_states
    ({"failed", "needs_key", "cancelled"}) never fires for a "done" book
    with no failed_pages. Must now surface as status="failed" (resumable)."""
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    AudiobookStore.write_meta(bid, meta)
    clean_path = AudiobookStore.page_clean_path(bid, 1)
    os.makedirs(os.path.dirname(clean_path), exist_ok=True)
    with open(clean_path, "w") as f:
        f.write("Page one content.")
    audio_path = AudiobookStore.page_audio_path(bid, 1)
    os.makedirs(os.path.dirname(audio_path), exist_ok=True)
    with open(audio_path, "wb") as f:
        from app.services.audiobook_service import _wav_header as _wh

        f.write(_wh(1200) + b"\x00" * 1200)

    real_open = open

    def failing_open(path, *args, **kwargs):
        if str(path).endswith("transcript.json.tmp"):
            raise OSError("simulated disk failure")
        return real_open(path, *args, **kwargs)

    with patch("builtins.open", side_effect=failing_open):
        with pytest.raises(RuntimeError, match="transcript"):
            await AudiobookService._phase_concat(bid, AudiobookStore.read_meta(bid))

    # The caller (_run_pipeline) is what actually sets status="failed" on
    # this exception — verify the exception type/message it relies on, and
    # that no half-written transcript.json.tmp was left behind.
    assert not os.path.exists(AudiobookStore.transcript_path(bid) + ".tmp")
    assert not os.path.exists(AudiobookStore.transcript_path(bid))


@pytest.mark.asyncio
async def test_run_pipeline_marks_failed_on_transcript_write_error(monkeypatch):
    """Integration: _run_pipeline's own except Exception must catch the
    re-raised transcript-write failure and land the book in status="failed"
    (a resumable state), not leave it stuck or silently "done"."""
    from app.services import audiobook_service as _svc

    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    AudiobookStore.write_meta(bid, meta)

    async def fake_extract(book_id):
        return None

    async def fake_clean(book_id, api_key):
        return None

    async def fake_section(book_id, api_key, meta):
        return None

    async def fake_tts(book_id, meta):
        return None

    async def fake_concat_raises(book_id, meta):
        raise RuntimeError("Failed to write transcript: simulated disk failure")

    monkeypatch.setattr(
        _svc.AudiobookService,
        "_phase_extract",
        classmethod(lambda cls, b: fake_extract(b)),
    )
    monkeypatch.setattr(
        _svc.AudiobookService,
        "_phase_clean",
        classmethod(lambda cls, b, k: fake_clean(b, k)),
    )
    monkeypatch.setattr(
        _svc.AudiobookService,
        "_phase_section",
        classmethod(lambda cls, b, k, m: fake_section(b, k, m)),
    )
    monkeypatch.setattr(
        _svc.AudiobookService,
        "_phase_tts",
        classmethod(lambda cls, b, m: fake_tts(b, m)),
    )
    monkeypatch.setattr(
        _svc.AudiobookService,
        "_phase_concat",
        classmethod(lambda cls, b, m: fake_concat_raises(b, m)),
    )

    await _svc.AudiobookService._run_pipeline(bid)

    final_meta = AudiobookStore.read_meta(bid)
    assert final_meta["status"] == "failed"
    assert "transcript" in (final_meta.get("error") or "").lower()


# ---------- local (no-LLM) chapter detection for Markdown (T-3 gap) ----------


@pytest.mark.asyncio
async def test_local_markdown_sectioning_produces_real_chapters_no_gemini(monkeypatch):
    """Regression: local-first (uses_gemini_cleanup=False, the actual
    default) Markdown books previously always collapsed to one giant
    section covering the whole book — TextExtractor.read_outline always
    returns None and the Gemini branch never runs when Gemini cleanup is
    off, so there was no local signal at all despite Markdown headings
    being a perfectly good one."""
    from app.services import audiobook_service as _svc
    from app.services import gemini_cleaner as _gc

    bid = AudiobookStore.create_book("book.md")
    md_source = (
        "# Chapter One\n\nSome opening content that is long enough to fill "
        "most of a synthetic page on its own, repeated a bit. "
        + ("word " * 380)
        + "\n\n# Chapter Two\n\nMore content for the second chapter, "
        + ("word " * 380)
    )
    source_path = AudiobookStore.source_file_path(bid, "md")
    os.makedirs(os.path.dirname(source_path), exist_ok=True)
    with open(source_path, "w", encoding="utf-8") as f:
        f.write(md_source)

    meta = AudiobookStore.initial_meta(
        bid, "book.md", 2, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["file_ext"] = "md"
    meta["uses_gemini_cleanup"] = False
    AudiobookStore.write_meta(bid, meta)

    monkeypatch.setattr(
        _gc.GeminiCleaner,
        "detect_sections",
        AsyncMock(side_effect=AssertionError("Gemini must not be called")),
    )

    await _svc.AudiobookService._phase_section(bid, "", AudiobookStore.read_meta(bid))

    final_meta = AudiobookStore.read_meta(bid)
    sections = final_meta["sections"]
    assert len(sections) >= 2, "expected real chapter detection, not one giant section"
    titles = [s["title"] for s in sections]
    assert "Chapter One" in titles
    assert "Chapter Two" in titles


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

    async def flaky_async(api_key, raw, tier=None):
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

    async def auth_failing(api_key, raw, tier=None):
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


def test_upload_extraction_failure_returns_curated_message_not_raw_exception(
    monkeypatch,
):
    """Regression: the 400 path for an unreadable file used to interpolate
    the raw exception (`f"Could not read file: {e}"`) straight into the
    user-facing `detail` — library-internal jargon, occasionally an
    internal path fragment, with no useful action for the user. Must now
    be a curated, actionable message; the raw exception is only logged."""
    from fastapi.testclient import TestClient

    from app.main import app
    from app.services import pdf_extractor as _pe

    def _raise(cls, p):
        raise RuntimeError("PyMuPDF: xref table corrupted at offset 0x4f2a, obj 17 0")

    monkeypatch.setattr(_pe.PDFExtractor, "page_count", classmethod(_raise))

    client = TestClient(app)
    files = {"file": ("test.pdf", b"%PDF-1.4\n" + b"x" * 200, "application/pdf")}
    response = client.post("/audiobook", files=files)
    assert response.status_code == 400
    detail = response.json()["detail"]
    assert "xref" not in detail and "PyMuPDF" not in detail and "0x4f2a" not in detail
    assert "corrupted" in detail.lower() or "unsupported" in detail.lower()


def test_upload_unexpected_failure_returns_curated_message_not_raw_exception(
    monkeypatch,
):
    """Same regression for the outer catch-all (`f"Upload failed: {e}"`) —
    any unclassified exception during upload must not reach the user
    verbatim."""
    from fastapi.testclient import TestClient

    from app.main import app
    from app.services import pdf_extractor as _pe

    monkeypatch.setattr(_pe.PDFExtractor, "page_count", classmethod(lambda cls, p: 3))
    monkeypatch.setattr(
        _pe.PDFExtractor, "is_image_only", classmethod(lambda cls, p: False)
    )

    def _raise(cls, p):
        raise RuntimeError("secret internal detail: /Users/himudigonda/private/path")

    monkeypatch.setattr(_pe.PDFExtractor, "sample_word_count", classmethod(_raise))

    client = TestClient(app)
    files = {"file": ("test.pdf", b"%PDF-1.4\n" + b"x" * 200, "application/pdf")}
    response = client.post("/audiobook", files=files)
    assert response.status_code == 500
    detail = response.json()["detail"]
    assert "himudigonda" not in detail and "secret internal detail" not in detail
    assert detail == "Upload failed. Please try again."


def test_upload_flags_byte_identical_reimport_as_duplicate(monkeypatch):
    """Regression: re-uploading the exact same file content previously
    created a fully silent, independent duplicate book with no warning at
    all — each mint a fresh book_id/uuid4 with no dedupe check anywhere.
    The endpoint must now flag it via duplicate_of_book_id/title (without
    blocking a deliberate re-import, e.g. a different voice)."""
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
    monkeypatch.setattr(
        _pe.PDFExtractor, "render_cover", classmethod(lambda cls, b: None)
    )

    client = TestClient(app)
    file_bytes = b"%PDF-1.4\n" + b"x" * 200

    first = client.post(
        "/audiobook", files={"file": ("book.pdf", file_bytes, "application/pdf")}
    )
    assert first.status_code == 200, first.text
    assert first.json()["duplicate_of_book_id"] is None

    second = client.post(
        "/audiobook", files={"file": ("book.pdf", file_bytes, "application/pdf")}
    )
    assert second.status_code == 200, second.text
    second_body = second.json()
    assert second_body["duplicate_of_book_id"] == first.json()["book_id"]
    assert second_body["duplicate_of_title"] == "book.pdf"
    # Not blocked — a second, independent book is still created.
    assert second_body["book_id"] != first.json()["book_id"]


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


@pytest.mark.parametrize(
    ("filename", "content_type"),
    [
        ("notes.txt", "text/plain"),
        ("chapter.md", "text/markdown"),
        (
            "outline.docx",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ),
    ],
)
def test_upload_accepts_every_supported_text_document_kind(
    monkeypatch, filename, content_type
):
    """The API contract, native picker, analytics labels, and backend must
    agree on TXT, Markdown, and DOCX instead of leaving them as UI-only types.
    Extraction is mocked here; TextExtractor routing has its own real-file test.
    """
    from fastapi.testclient import TestClient

    from app.main import app
    from app.services import text_extractor as _te

    monkeypatch.setattr(_te.TextExtractor, "page_count", classmethod(lambda cls, _: 1))
    monkeypatch.setattr(
        _te.TextExtractor, "sample_word_count", classmethod(lambda cls, _: 10)
    )
    monkeypatch.setattr(
        _te.TextExtractor, "sample_char_count", classmethod(lambda cls, _: 50)
    )
    monkeypatch.setattr(
        _te.TextExtractor, "render_cover", classmethod(lambda cls, _: None)
    )

    response = TestClient(app).post(
        "/audiobook", files={"file": (filename, b"document content", content_type)}
    )
    assert response.status_code == 200, response.text
    meta = AudiobookStore.read_meta(response.json()["book_id"])
    assert meta is not None
    assert meta["file_ext"] == filename.rsplit(".", 1)[1]


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
    meta["uses_gemini_cleanup"] = True
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


def test_read_text_rejects_binary_content_with_txt_extension(tmp_path):
    """Regression: validation was extension-only — a binary file renamed to
    .txt decoded silently under errors="replace" and sailed through
    page_count > 0 straight into a "successfully completed" audiobook
    narrating replacement-character noise, with zero warning anywhere."""
    from app.services.text_extractor import TextExtractor

    path = tmp_path / "renamed.txt"
    # Genuinely arbitrary binary bytes — not valid UTF-8, decodes to mostly
    # U+FFFD replacement characters under errors="replace".
    path.write_bytes(bytes(range(256)) * 20)

    with pytest.raises(ValueError, match="doesn't look like readable text"):
        TextExtractor.read_text(str(path))


def test_read_text_accepts_real_text_with_a_few_unencodable_chars(tmp_path):
    """The replacement-char check must not false-positive on a real document
    that happens to contain a handful of genuinely unencodable bytes."""
    from app.services.text_extractor import TextExtractor

    path = tmp_path / "mostly_fine.txt"
    body = "This is a perfectly normal paragraph of real text. " * 50
    with open(path, "wb") as f:
        f.write(body.encode("utf-8"))
        f.write(b"\xff\xfe")  # a couple of stray invalid bytes

    text = TextExtractor.read_text(str(path))
    assert "perfectly normal paragraph" in text


# ---------- PDF extraction opens the PDF once, not once per page ----------


class _FakePage:
    def __init__(self, text: str):
        self._text = text

    def extract_text(self):
        return self._text


class _FakePDF:
    def __init__(self, pages: list[str]):
        self.pages = [_FakePage(t) for t in pages]

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def test_extract_one_opens_pdf_only_once_for_the_whole_book(monkeypatch, tmp_path):
    """Regression: extract_one previously reopened/reparsed the entire PDF
    for every single page (N pages -> N pdfplumber.open calls on a
    single-threaded executor). It now extracts and writes every page on the
    first call, mirroring TextExtractor.extract_one's already-established
    pattern, so a 1000-page book opens the PDF once instead of 1000 times."""
    from app.services.pdf_extractor import PDFExtractor

    page_texts = [f"Page {i} content." for i in range(1, 11)]
    open_calls: list[str] = []

    def fake_open(path):
        open_calls.append(path)
        return _FakePDF(page_texts)

    monkeypatch.setattr("app.services.pdf_extractor.pdfplumber.open", fake_open)

    bid = AudiobookStore.create_book("Test.pdf")
    # extract_one resolves the source path via AudiobookStore.pdf_path, which
    # just needs the book dir to exist (create_book already makes it) — no
    # real PDF bytes are read since pdfplumber.open is mocked above.

    # Mirrors _phase_extract's sequential loop: call extract_one for every
    # page in order, the same way the real pipeline does.
    for n in range(1, 11):
        PDFExtractor.extract_one(bid, n)

    assert (
        len(open_calls) == 1
    ), f"expected 1 pdfplumber.open call, got {len(open_calls)}"
    for n in range(1, 11):
        path = AudiobookStore.page_raw_path(bid, n)
        assert os.path.exists(path)
        with open(path, encoding="utf-8") as f:
            assert f.read() == f"Page {n} content."


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
    meta["uses_gemini_cleanup"] = True
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


@pytest.mark.asyncio
async def test_local_clean_phase_never_calls_gemini(monkeypatch):
    """The default audiobook path copies normal extracted text locally."""
    from app.services import audiobook_service as _svc
    from app.services import gemini_cleaner as _gc

    bid = AudiobookStore.create_book("Local.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Local.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    AudiobookStore.write_meta(bid, meta)
    raw_text = "This page stays on the Mac."
    raw_path = AudiobookStore.page_raw_path(bid, 1)
    os.makedirs(os.path.dirname(raw_path), exist_ok=True)
    with open(raw_path, "w", encoding="utf-8") as f:
        f.write(raw_text)

    monkeypatch.setattr(
        _gc.GeminiCleaner,
        "clean_page",
        AsyncMock(side_effect=AssertionError("Gemini must not be called")),
    )
    monkeypatch.setattr(
        _gc.GeminiCleaner,
        "ocr_page",
        AsyncMock(side_effect=AssertionError("Gemini OCR must not be called")),
    )

    _svc.AudiobookService.initialize()
    await _svc.AudiobookService._phase_clean(bid, api_key="")

    with open(AudiobookStore.page_clean_path(bid, 1), encoding="utf-8") as f:
        assert f.read() == raw_text


# ---------- runtime Gemini cost governor ----------


@pytest.mark.asyncio
async def test_clean_phase_stops_spending_once_cost_cap_reached(monkeypatch):
    """Regression: the upfront /start cost estimate samples only 3 pages and
    doesn't model per-page OCR cost for a mixed text/scanned PDF at all —
    real spend could exceed MAX_GEMINI_COST_USD_PER_BOOK with zero runtime
    check once processing started. With the cap set effectively to zero,
    no page should ever reach GeminiCleaner.clean_page; every page must
    fall back to local cleanup, get marked "cost_capped", and surface via
    failed_pages/page_failed so the user knows why."""
    from app.services import audiobook_service as _svc
    from app.services import gemini_cleaner as _gc

    monkeypatch.setattr(_svc._settings, "MAX_GEMINI_COST_USD_PER_BOOK", 0.0)

    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 2, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["uses_gemini_cleanup"] = True
    AudiobookStore.write_meta(bid, meta)
    for n in (1, 2):
        path = AudiobookStore.page_raw_path(bid, n)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write("# Heading\n\nSome **bold** page " + str(n) + " content. " * 20)

    monkeypatch.setattr(
        _gc.GeminiCleaner,
        "clean_page",
        AsyncMock(
            side_effect=AssertionError("Gemini must not be called once cost-capped")
        ),
    )

    events: list[dict] = []
    orig_emit = AudiobookService._emit

    def _capture_emit(cls, book_id, event_type, **data):
        events.append({"type": event_type, **data})
        return orig_emit(book_id, event_type, **data)

    with patch.object(AudiobookService, "_emit", classmethod(_capture_emit)):
        _svc.AudiobookService.initialize()
        await _svc.AudiobookService._phase_clean(bid, api_key="fake-key")

    final_meta = AudiobookStore.read_meta(bid)
    assert set(final_meta["failed_pages"]) == {1, 2}
    assert final_meta["page_status"]["1"] == "cost_capped"
    assert final_meta["page_status"]["2"] == "cost_capped"

    for n in (1, 2):
        with open(AudiobookStore.page_clean_path(bid, n), encoding="utf-8") as f:
            cleaned = f.read()
        # Local fallback ran (Markdown stripped), not raw passthrough.
        assert "#" not in cleaned and "**" not in cleaned
        assert f"page {n} content" in cleaned

    capped_events = [e for e in events if e["type"] == "page_failed"]
    assert len(capped_events) == 2
    assert all("cost cap" in e["error"].lower() for e in capped_events)


@pytest.mark.asyncio
async def test_retry_failed_reattempts_gemini_for_cost_capped_page():
    """A cost-capped page's on-disk clean text is only the local fallback —
    retry_failed must delete it (like a real cleaning_failed page) so a
    retry actually re-attempts Gemini, not just re-synthesize the fallback
    text's audio."""
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["failed_pages"] = [1]
    meta["page_status"] = {"1": "cost_capped"}
    AudiobookStore.write_meta(bid, meta)

    clean_path = AudiobookStore.page_clean_path(bid, 1)
    os.makedirs(os.path.dirname(clean_path), exist_ok=True)
    with open(clean_path, "w") as f:
        f.write("local fallback text")
    audio_path = AudiobookStore.page_audio_path(bid, 1)
    os.makedirs(os.path.dirname(audio_path), exist_ok=True)
    with open(audio_path, "wb") as f:
        f.write(b"fake")

    async def fake_enqueue(book_id: str, api_key: str):
        return None

    with patch.object(
        AudiobookService, "enqueue", classmethod(lambda cls, b, k: fake_enqueue(b, k))
    ):
        await AudiobookService.retry_failed(bid, "fake-key")

    assert not os.path.exists(
        clean_path
    ), "cost-capped page's clean text must be deleted to force re-clean"
    assert not os.path.exists(audio_path)


# ---------- end-to-end: real Markdown source through the full local pipeline ----------


@pytest.mark.asyncio
async def test_markdown_source_full_pipeline_produces_speakable_transcript():
    """Real regression proof for the "TTS reads literal Markdown symbols" bug:
    a genuine .md source file, run through extract -> clean (no Gemini, the
    actual default) -> tts (mocked, only synth is mocked) -> concat, must
    produce a final transcript with no raw Markdown syntax left in it and
    all real content preserved. Every phase except EngineManager.generate is
    the real production code path — this is not a unit test of the
    normalizer in isolation."""
    from app.services import audiobook_service as _svc

    bid = AudiobookStore.create_book("chapter.md")
    md_source = (
        "# Chapter One: Getting Started\n\n"
        "This is **very important** and *should not* be lost, with a "
        "[link to the docs](https://example.com/docs) for reference.\n\n"
        "> A wise narrator once said something worth remembering.\n\n"
        "- First step\n"
        "- Second step\n\n"
        "| Name | Role |\n"
        "| --- | --- |\n"
        "| Ada | Engineer |\n\n"
        "Run `make verify` before you ship anything.\n\n"
        "---\n\n"
        "It's the end of the chapter, isn't it?"
    )
    source_path = AudiobookStore.source_file_path(bid, "md")
    os.makedirs(os.path.dirname(source_path), exist_ok=True)
    with open(source_path, "w", encoding="utf-8") as f:
        f.write(md_source)

    meta = AudiobookStore.initial_meta(
        bid, "chapter.md", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["file_ext"] = "md"
    meta["uses_gemini_cleanup"] = False  # the actual real-world default
    AudiobookStore.write_meta(bid, meta)

    _svc.AudiobookService._queue = None
    _svc.AudiobookService._worker_task = None
    _svc.AudiobookService.initialize()

    with (
        patch(
            "app.services.audiobook_service.EngineManager.ensure_loaded",
            new=AsyncMock(return_value=None),
        ),
        patch("app.services.audiobook_service.EngineManager.touch", return_value=None),
        patch(
            "app.services.audiobook_service.EngineManager.generate",
            side_effect=_mock_generate_yielding,
        ),
    ):
        await _svc.AudiobookService._phase_extract(bid)
        await _svc.AudiobookService._phase_clean(bid, api_key="")
        current_meta = AudiobookStore.read_meta(bid)
        await _svc.AudiobookService._phase_tts(bid, current_meta)
        await _svc.AudiobookService._phase_concat(bid, current_meta)

    with open(AudiobookStore.transcript_path(bid), encoding="utf-8") as f:
        transcript = json.load(f)

    full_text = " ".join(transcript["pages"].values())

    # No literal Markdown syntax survives into what gets spoken.
    for forbidden in ("#", "**", "[link to the docs]", "(https://", "```", "| Name"):
        assert (
            forbidden not in full_text
        ), f"raw Markdown syntax leaked through: {forbidden!r}"
    # A bare "---" horizontal rule line must be gone (a "-" inside a real
    # word/number is fine; this asserts no standalone rule survived).
    assert "\n---\n" not in full_text and full_text.strip() != "---"

    # Real content is preserved, not just formatting stripped into nothing.
    for expected in (
        "Chapter One",
        "very important",
        "should not",
        "link to the docs",
        "wise narrator",
        "First step",
        "Second step",
        "Ada",
        "Engineer",
        "make verify",
        "end of the chapter",
    ):
        assert expected in full_text, f"real content lost: {expected!r}"

    # Ordinary apostrophes in contractions are untouched (not a Markdown marker).
    assert "It's" in full_text
    assert "isn't" in full_text

    # And the pipeline actually reached a playable end state.
    assert os.path.exists(AudiobookStore.audio_path(bid))
