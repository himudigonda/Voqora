from __future__ import annotations

import asyncio
import json
import logging
import shutil
import tempfile

import pytest

from app.services.audiobook_service import AudiobookService
from app.services.audiobook_store import AudiobookStore


@pytest.fixture(autouse=True)
def isolated_audiobooks_dir(monkeypatch):
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


@pytest.fixture(autouse=True)
def reset_audiobook_service():
    AudiobookService._queue = None
    AudiobookService._worker_task = None
    AudiobookService._executor = None
    AudiobookService._scheduled_book_ids.clear()
    yield
    AudiobookService._queue = None
    AudiobookService._worker_task = None
    AudiobookService._scheduled_book_ids.clear()
    if AudiobookService._executor is not None:
        AudiobookService._executor.shutdown(wait=False, cancel_futures=True)
        AudiobookService._executor = None


def _make_book(title: str, created_at: str, status: str) -> str:
    bid = AudiobookStore.create_book(title)
    meta = AudiobookStore.initial_meta(
        bid, title, 3, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["created_at"] = created_at
    meta["status"] = status
    meta["uses_gemini_cleanup"] = True
    AudiobookStore.write_meta(bid, meta)
    return bid


def _corrupt_page_count(book_id: str) -> None:
    meta = AudiobookStore.read_meta(book_id)
    assert meta is not None
    meta["page_count"] = "CORRUPT"
    conn = AudiobookStore._connection()
    with AudiobookStore._conn_lock:
        conn.execute(
            "UPDATE books SET meta_json = ? WHERE book_id = ?",
            (json.dumps(meta), book_id),
        )


def test_corrupted_row_write_raises_for_real():
    bid = _make_book("Corrupt.pdf", "2024-01-01T00:00:00Z", "cleaning")
    _corrupt_page_count(bid)

    with pytest.raises(ValueError):
        asyncio.run(AudiobookStore.update_meta(bid, status="needs_key"))


@pytest.mark.asyncio
async def test_resume_in_progress_skips_corrupted_book_and_resumes_others():
    newest = _make_book("Newest.pdf", "2024-01-03T00:00:00Z", "cleaning")
    middle = _make_book("Middle.pdf", "2024-01-02T00:00:00Z", "cleaning")
    oldest = _make_book("Oldest.pdf", "2024-01-01T00:00:00Z", "cleaning")
    order = [b["book_id"] for b in AudiobookStore.list_books()]
    assert order == [newest, middle, oldest]
    _corrupt_page_count(middle)

    await AudiobookService.resume_in_progress()

    assert AudiobookStore.read_meta(newest)["status"] == "needs_key"
    assert AudiobookStore.read_meta(oldest)["status"] == "needs_key"
    assert AudiobookStore.read_meta(middle)["status"] == "cleaning"


@pytest.mark.asyncio
async def test_resume_in_progress_logs_the_failing_book_id(caplog):
    bid = _make_book("Corrupt.pdf", "2024-01-01T00:00:00Z", "cleaning")
    _corrupt_page_count(bid)

    with caplog.at_level(logging.ERROR):
        await AudiobookService.resume_in_progress()

    failures = [r for r in caplog.records if r.levelno >= logging.ERROR]
    assert failures
    assert any(getattr(r, "book_id", None) == bid for r in failures)
    assert any(r.exc_info for r in failures)


@pytest.mark.asyncio
async def test_resume_in_progress_survives_a_sibling_failure_in_the_enqueue_branch(
    monkeypatch,
):
    good = _make_book("Good.pdf", "2024-01-02T00:00:00Z", "tts")
    bad = _make_book("Bad.pdf", "2024-01-03T00:00:00Z", "tts")
    _corrupt_page_count(bad)

    await AudiobookService.resume_in_progress()

    assert AudiobookStore.read_meta(good)["status"] == "queued"
