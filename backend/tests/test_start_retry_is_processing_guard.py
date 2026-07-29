"""Tests for D4: /start and /retry must guard against double-enqueueing a
pipeline run on a book that's already processing, mirroring /delete's
existing AudiobookService.is_processing() guard.

Before this fix, /start and /retry called AudiobookService.enqueue() /
retry_failed() unconditionally as soon as the book existed — an
SSE-reconnect re-POST, a double-clicked button, or any other race could fire
a second concurrent pipeline run on a book already mid-processing.
"""

from __future__ import annotations

import shutil
import tempfile
from unittest.mock import AsyncMock

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


def _make_book(status: str = "ready") -> str:
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["status"] = status
    AudiobookStore.write_meta(bid, meta)
    return bid


# ---------------------------------------------------------------------------
# /start
# ---------------------------------------------------------------------------


def test_start_returns_409_when_book_already_processing(monkeypatch):
    from fastapi.testclient import TestClient

    from app.main import app

    enqueued: list[str] = []

    async def fake_enqueue(book_id: str, api_key: str):
        enqueued.append(book_id)

    monkeypatch.setattr(
        AudiobookService, "enqueue", classmethod(lambda cls, b, k: fake_enqueue(b, k))
    )
    # Simulate the book already being the actively-processing job.
    bid = _make_book(status="tts")
    monkeypatch.setattr(AudiobookService, "_current_book_id", bid)

    client = TestClient(app)
    response = client.post(
        f"/audiobook/{bid}/start",
        headers={"X-Gemini-Api-Key": "x", "X-Gemini-Consent": "true"},
    )

    assert response.status_code == 409
    assert enqueued == [], "a processing book must not be re-enqueued"


def test_start_called_twice_in_succession_only_enqueues_once(monkeypatch):
    """Calling /start twice in quick succession on the same book must only
    trigger one pipeline run — the second call sees the first's in-flight
    status via is_processing() and is rejected."""
    from fastapi.testclient import TestClient

    from app.main import app

    enqueued: list[str] = []

    async def fake_enqueue(book_id: str, api_key: str):
        enqueued.append(book_id)
        # Mirror the real enqueue()'s effect closely enough for
        # is_processing() (which also consults meta["status"]) to see this
        # book as in-flight on the second call.
        await AudiobookStore.update_meta(book_id, status="queued")

    monkeypatch.setattr(
        AudiobookService, "enqueue", classmethod(lambda cls, b, k: fake_enqueue(b, k))
    )
    bid = _make_book(status="ready")
    client = TestClient(app)
    headers = {"X-Gemini-Api-Key": "x", "X-Gemini-Consent": "true"}

    first = client.post(f"/audiobook/{bid}/start", headers=headers)
    second = client.post(f"/audiobook/{bid}/start", headers=headers)

    assert first.status_code == 200
    assert second.status_code == 409
    assert enqueued == [bid], "only the first /start should have enqueued a run"


def test_start_succeeds_when_book_not_processing(monkeypatch):
    """Non-regression: the guard must not false-trip on a fresh, unstarted
    book (status defaults to "ready", not in is_processing()'s status set)."""
    from fastapi.testclient import TestClient

    from app.main import app

    enqueued: list[str] = []

    async def fake_enqueue(book_id: str, api_key: str):
        enqueued.append(book_id)

    monkeypatch.setattr(
        AudiobookService, "enqueue", classmethod(lambda cls, b, k: fake_enqueue(b, k))
    )
    bid = _make_book(status="ready")
    client = TestClient(app)

    response = client.post(
        f"/audiobook/{bid}/start",
        headers={"X-Gemini-Api-Key": "x", "X-Gemini-Consent": "true"},
    )

    assert response.status_code == 200
    assert enqueued == [bid]


# ---------------------------------------------------------------------------
# /retry
# ---------------------------------------------------------------------------


def test_retry_returns_409_when_book_already_processing(monkeypatch):
    from fastapi.testclient import TestClient

    from app.main import app

    retry_mock = AsyncMock(return_value=2)
    monkeypatch.setattr(AudiobookService, "retry_failed", retry_mock)
    bid = _make_book(status="cleaning")
    monkeypatch.setattr(AudiobookService, "_current_book_id", bid)

    client = TestClient(app)
    response = client.post(f"/audiobook/{bid}/retry", headers={"X-Gemini-Api-Key": "x"})

    assert response.status_code == 409
    retry_mock.assert_not_called()


def test_retry_called_twice_in_succession_only_retries_once(monkeypatch):
    """Mirrors the /start double-POST test: a double-clicked Retry (or an
    SSE-reconnect re-POST) must not fire a second concurrent pipeline run."""
    from fastapi.testclient import TestClient

    from app.main import app

    retried: list[str] = []

    async def fake_retry_failed(book_id: str, api_key: str) -> int:
        retried.append(book_id)
        await AudiobookStore.update_meta(book_id, status="queued", failed_pages=[])
        return 1

    monkeypatch.setattr(
        AudiobookService,
        "retry_failed",
        classmethod(lambda cls, b, k: fake_retry_failed(b, k)),
    )
    bid = _make_book(status="failed")
    AudiobookStore.write_meta(
        bid, {**AudiobookStore.read_meta(bid), "failed_pages": [1]}
    )
    client = TestClient(app)
    headers = {"X-Gemini-Api-Key": "x"}

    first = client.post(f"/audiobook/{bid}/retry", headers=headers)
    second = client.post(f"/audiobook/{bid}/retry", headers=headers)

    assert first.status_code == 200
    assert second.status_code == 409
    assert retried == [bid], "only the first /retry should have re-processed"


def test_retry_succeeds_when_book_not_processing(monkeypatch):
    """Non-regression: a genuinely failed/idle book can still be retried."""
    from fastapi.testclient import TestClient

    from app.main import app

    retry_mock = AsyncMock(return_value=1)
    monkeypatch.setattr(AudiobookService, "retry_failed", retry_mock)
    bid = _make_book(status="failed")

    client = TestClient(app)
    response = client.post(f"/audiobook/{bid}/retry", headers={"X-Gemini-Api-Key": "x"})

    assert response.status_code == 200
    retry_mock.assert_awaited_once()
