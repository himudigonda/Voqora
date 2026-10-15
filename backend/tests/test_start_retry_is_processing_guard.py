from __future__ import annotations

import shutil
import tempfile
from unittest.mock import AsyncMock

import pytest
from fastapi.testclient import TestClient

from app.main import app
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


def test_retry_returns_409_when_book_is_the_running_job(monkeypatch):
    retry = AsyncMock(return_value=2)
    monkeypatch.setattr(AudiobookService, "retry_failed", retry)
    bid = _make_book(status="cleaning")
    monkeypatch.setattr(AudiobookService, "_current_book_id", bid)

    response = TestClient(app).post(f"/audiobook/{bid}/retry")

    assert response.status_code == 409
    retry.assert_not_called()


@pytest.mark.parametrize("status", ["queued", "extracting", "tts", "concatenating"])
def test_retry_returns_409_for_in_flight_status(monkeypatch, status):
    retry = AsyncMock(return_value=2)
    monkeypatch.setattr(AudiobookService, "retry_failed", retry)
    bid = _make_book(status=status)

    response = TestClient(app).post(f"/audiobook/{bid}/retry")

    assert response.status_code == 409
    retry.assert_not_called()


def test_retry_called_twice_only_retries_once(monkeypatch):
    retried: list[str] = []

    async def fake_retry_failed(book_id: str, credential) -> int:
        retried.append(book_id)
        await AudiobookStore.update_meta(book_id, status="queued", failed_pages=[])
        return 1

    monkeypatch.setattr(
        AudiobookService,
        "retry_failed",
        classmethod(lambda cls, b, c, **kw: fake_retry_failed(b, c)),
    )
    bid = _make_book(status="failed")
    client = TestClient(app)

    first = client.post(f"/audiobook/{bid}/retry")
    second = client.post(f"/audiobook/{bid}/retry")

    assert first.status_code == 200
    assert second.status_code == 409
    assert retried == [bid]


def test_retry_succeeds_when_book_is_idle(monkeypatch):
    retry = AsyncMock(return_value=1)
    monkeypatch.setattr(AudiobookService, "retry_failed", retry)
    bid = _make_book(status="failed")

    response = TestClient(app).post(f"/audiobook/{bid}/retry")

    assert response.status_code == 200
    retry.assert_awaited_once()


def test_retry_guard_runs_before_the_credential_requirement(monkeypatch):
    retry = AsyncMock(return_value=1)
    monkeypatch.setattr(AudiobookService, "retry_failed", retry)
    bid = _make_book(status="cleaning")
    meta = AudiobookStore.read_meta(bid)
    meta["uses_gemini_cleanup"] = True
    AudiobookStore.write_meta(bid, meta)

    response = TestClient(app).post(f"/audiobook/{bid}/retry")

    assert response.status_code == 409
    retry.assert_not_called()


def test_start_returns_409_when_book_is_already_scheduled(monkeypatch):
    bid = _make_book(status="ready")
    monkeypatch.setattr(AudiobookService, "_scheduled_book_ids", {bid})

    response = TestClient(app).post(f"/audiobook/{bid}/start")

    assert response.status_code == 409
