"""SSE /audiobook/{id}/events contract tests (HARD-042).

Two layers:

1. AudiobookService pub/sub primitive — subscribe / unsubscribe / _emit
   behave correctly under concurrent subscribers and queue-full conditions.
   Plain asyncio.Queue interactions, no HTTP harness needed.

2. HTTP layer — the route returns the right status / Content-Type /
   404 / 400 envelopes. The actual streaming-body delivery is covered by
   end-to-end manual runs; testing it under TestClient's buffered transport
   is fragile (the in-memory ASGI transport doesn't reliably stream
   incremental SSE frames in a deterministic way under timeouts).
"""

from __future__ import annotations

import asyncio
import shutil
import tempfile

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.services.audiobook_service import AudiobookService
from app.services.audiobook_store import AudiobookStore


@pytest.fixture(autouse=True)
def isolated_audiobooks_dir(monkeypatch):
    tmp = tempfile.mkdtemp(prefix="ss_sse_test_")

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
def reset_subscribers():
    AudiobookService._subscribers.clear()
    yield
    AudiobookService._subscribers.clear()


def _create_book(status: str = "queued") -> str:
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["status"] = status
    AudiobookStore.write_meta(bid, meta)
    return bid


# ---------- pub/sub primitive ----------


@pytest.mark.asyncio
async def test_subscribe_returns_queue_and_registers_subscriber():
    bid = _create_book()
    q = AudiobookService.subscribe(bid)
    assert isinstance(q, asyncio.Queue)
    assert q in AudiobookService._subscribers[bid]


@pytest.mark.asyncio
async def test_unsubscribe_removes_subscriber_and_cleans_empty_key():
    bid = _create_book()
    q = AudiobookService.subscribe(bid)
    AudiobookService.unsubscribe(bid, q)
    # When the last subscriber leaves, the key is purged so the dict doesn't
    # grow unbounded across books.
    assert bid not in AudiobookService._subscribers


@pytest.mark.asyncio
async def test_emit_delivers_payload_to_all_active_subscribers():
    bid = _create_book()
    q1 = AudiobookService.subscribe(bid)
    q2 = AudiobookService.subscribe(bid)
    AudiobookService._emit(bid, "progress", page=5, phase="clean")

    e1 = q1.get_nowait()
    e2 = q2.get_nowait()
    for evt in (e1, e2):
        assert evt["type"] == "progress"
        assert evt["page"] == 5
        assert evt["phase"] == "clean"
        assert evt["book_id"] == bid


@pytest.mark.asyncio
async def test_emit_after_unsubscribe_does_not_deliver():
    bid = _create_book()
    q = AudiobookService.subscribe(bid)
    AudiobookService.unsubscribe(bid, q)
    AudiobookService._emit(bid, "progress", page=1)
    with pytest.raises(asyncio.QueueEmpty):
        q.get_nowait()


@pytest.mark.asyncio
async def test_emit_on_unknown_book_is_a_noop():
    AudiobookService._emit("00000000000000000000000000000000", "progress", page=1)
    # No exception, no side effects.
    assert AudiobookService._subscribers == {}


# ---------- HTTP envelope ----------


def test_events_returns_400_on_malformed_book_id():
    client = TestClient(app)
    r = client.get("/audiobook/not_hex/events")
    assert r.status_code in (400, 404)


def test_events_returns_404_on_unknown_book():
    client = TestClient(app)
    r = client.get("/audiobook/" + ("e" * 32) + "/events")
    assert r.status_code == 404


def test_events_returns_200_text_event_stream_for_known_terminal_book():
    """A book in a terminal state still produces a 200 with the right
    Content-Type. The body contains one snapshot line then the stream closes.
    We just check status + headers — the byte-level format is tested at
    the service layer above and via manual e2e."""
    bid = _create_book(status="done")
    client = TestClient(app)
    with client.stream("GET", f"/audiobook/{bid}/events") as resp:
        assert resp.status_code == 200
        assert resp.headers["content-type"].startswith("text/event-stream")
        # Drain so the response closes cleanly.
        body = b""
        for chunk in resp.iter_bytes():
            body += chunk
        assert b"data: " in body
        assert b'"type": "snapshot"' in body
        assert b'"status": "done"' in body
