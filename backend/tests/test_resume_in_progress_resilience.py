"""Tests for D10: resume_in_progress's per-book loop must not let one
corrupted/malformed row abort resumption of every other in-flight book.

Before this fix, the loop body had no try/except: any exception raised while
resuming one book (e.g. AudiobookStore.update_meta failing to re-serialise a
corrupted meta row) propagated straight out of resume_in_progress(), which
runs once at backend startup — so a single bad row could silently prevent
every OTHER in-flight book from ever resuming, with no log identifying which
book was the culprit.

The corruption is reproduced for real (not mocked): AudiobookStore.write_meta
always coerces page_count via int(meta.get("page_count") or 0)
(_meta_to_row), so a normal write can never persist a non-numeric
page_count. This test bypasses that coercion with a direct SQL UPDATE on the
meta_json column (simulating on-disk corruption from any other source), so
the FIRST write attempted by resume_in_progress against that row genuinely
raises ValueError — not a mocked stand-in for one.
"""

from __future__ import annotations

import json
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
    yield
    AudiobookService._queue = None
    AudiobookService._worker_task = None
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
    AudiobookStore.write_meta(bid, meta)
    return bid


def _corrupt_page_count(book_id: str) -> None:
    """Simulate real on-disk corruption: bypass write_meta's int() coercion
    (_meta_to_row) by UPDATE-ing the meta_json column directly, so the next
    genuine write attempt against this row raises ValueError for real."""
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
    """Sanity check on the corruption technique itself: confirms
    _corrupt_page_count() genuinely breaks the next write (not a mock), so
    the resilience test below is exercising a real failure, not a stand-in."""
    bid = _make_book("Corrupt.pdf", "2024-01-01T00:00:00Z", "cleaning")
    _corrupt_page_count(bid)

    import asyncio

    with pytest.raises(ValueError):
        asyncio.run(AudiobookStore.update_meta(bid, status="needs_key"))


@pytest.mark.asyncio
async def test_resume_in_progress_skips_corrupted_book_and_resumes_others():
    """3 books; the MIDDLE one (by created_at DESC, matching
    list_books()'s real ordering) has a corrupted page_count. resume_in_progress
    must not raise, and the other 2 books must still be flipped to
    needs_key."""
    # created_at DESC → list_books() order is [newest, middle, oldest].
    newest = _make_book("Newest.pdf", "2024-01-03T00:00:00Z", "cleaning")
    middle = _make_book("Middle.pdf", "2024-01-02T00:00:00Z", "cleaning")
    oldest = _make_book("Oldest.pdf", "2024-01-01T00:00:00Z", "cleaning")

    order = [b["book_id"] for b in AudiobookStore.list_books()]
    assert order == [newest, middle, oldest], "test setup requires this exact order"

    _corrupt_page_count(middle)

    # Must complete without raising — this is the D10 regression itself.
    await AudiobookService.resume_in_progress()

    assert AudiobookStore.read_meta(newest)["status"] == "needs_key"
    assert AudiobookStore.read_meta(oldest)["status"] == "needs_key"
    # The corrupted book's write failed, so its status is whatever it was
    # before the failed attempt (unchanged) — never silently left corrupted
    # further, never crashing the whole resume pass either.
    assert AudiobookStore.read_meta(middle)["status"] == "cleaning"


@pytest.mark.asyncio
async def test_resume_in_progress_logs_the_failing_book_id(caplog):
    """The fix must log the failure with the specific book_id, so an
    operator can identify which row is corrupted."""
    import logging

    bid = _make_book("Corrupt.pdf", "2024-01-01T00:00:00Z", "cleaning")
    _corrupt_page_count(bid)

    with caplog.at_level(logging.ERROR):
        await AudiobookService.resume_in_progress()

    assert any(
        bid in record.message or bid in str(getattr(record, "book_id", ""))
        for record in caplog.records
    ) or any(
        bid in json.dumps(getattr(record, "__dict__", {}), default=str)
        for record in caplog.records
    ), f"expected a log record referencing the failing book_id {bid}"


@pytest.mark.asyncio
async def test_resume_in_progress_with_tts_status_also_survives_a_sibling_failure(
    monkeypatch,
):
    """The try/except must cover the enqueue() branch too (status in
    {"tts", "concatenating"}), not just the needs_key branches."""
    good = _make_book("Good.pdf", "2024-01-02T00:00:00Z", "tts")
    bad = _make_book("Bad.pdf", "2024-01-01T00:00:00Z", "tts")
    _corrupt_page_count(bad)

    enqueued: list[str] = []
    real_enqueue = AudiobookService.enqueue.__func__

    async def spy_enqueue(cls, book_id, api_key):
        enqueued.append(book_id)
        await real_enqueue(cls, book_id, api_key)

    monkeypatch.setattr(AudiobookService, "enqueue", classmethod(spy_enqueue))

    await AudiobookService.resume_in_progress()

    assert good in enqueued
    # The corrupted book's enqueue() itself calls update_meta(status="queued")
    # internally, which is where the real ValueError fires — it must not have
    # prevented the good book's enqueue from running.
    persisted_good = AudiobookStore.read_meta(good)
    assert persisted_good["status"] == "queued"
