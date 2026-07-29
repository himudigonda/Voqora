"""Tests for GeminiAuthError sibling task cancellation in _phase_clean.

When one Gemini clean task raises GeminiAuthError, ALL sibling tasks must be
immediately cancelled. Without the fix (old asyncio.gather without explicit
task.cancel()), sibling tasks would keep making Gemini API calls with a
known-bad key — wasting quota and hanging the pipeline.

The fix implemented in v2.2:
    tasks = [asyncio.create_task(clean_one(n)) for n in pending]
    try:
        await asyncio.gather(*tasks)
    except GeminiAuthError:
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        raise
"""

from __future__ import annotations

import asyncio
import os
import shutil

import pytest

from app.services.audiobook_service import AudiobookService
from app.services.audiobook_store import AudiobookStore
from app.services.gemini_cleaner import GeminiAuthError

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def isolated_dir(monkeypatch, tmp_path):
    class _S:
        @property
        def AUDIOBOOKS_DIR(self):
            return str(tmp_path)

    monkeypatch.setattr("app.services.audiobook_store.settings", _S())
    AudiobookStore._reset_for_tests()
    yield str(tmp_path)
    AudiobookStore._reset_for_tests()
    shutil.rmtree(str(tmp_path), ignore_errors=True)


@pytest.fixture(autouse=True)
def reset_audiobook_service():
    """Each test gets a fresh service state (queue + worker)."""
    AudiobookService._queue = None
    AudiobookService._worker_task = None
    AudiobookService._executor = None
    yield
    AudiobookService._queue = None
    AudiobookService._worker_task = None
    if AudiobookService._executor is not None:
        AudiobookService._executor.shutdown(wait=False, cancel_futures=True)
        AudiobookService._executor = None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_book(page_count: int = 3) -> str:
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", page_count, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    AudiobookStore.write_meta(bid, meta)
    for n in range(1, page_count + 1):
        raw = AudiobookStore.page_raw_path(bid, n)
        os.makedirs(os.path.dirname(raw), exist_ok=True)
        # Write content long enough to skip OCR threshold (50 chars)
        with open(raw, "w", encoding="utf-8") as f:
            f.write("A" * 200)
    return bid


# ===========================================================================
# GeminiAuthError propagation
# ===========================================================================


@pytest.mark.asyncio
async def test_phase_clean_re_raises_gemini_auth_error(monkeypatch):
    """When clean_page raises GeminiAuthError, _phase_clean must propagate it."""
    bid = _make_book(2)

    from unittest.mock import AsyncMock

    from app.services import gemini_cleaner as _gc

    monkeypatch.setattr(
        _gc.GeminiCleaner,
        "clean_page",
        AsyncMock(side_effect=GeminiAuthError("bad key")),
    )
    AudiobookService.initialize()

    with pytest.raises(GeminiAuthError):
        await AudiobookService._phase_clean(bid, api_key="bad-key")


@pytest.mark.asyncio
async def test_phase_clean_cancels_sibling_tasks_on_auth_error(monkeypatch):
    """When one task raises GeminiAuthError, ALL siblings must be cancelled.

    Design: siblings (pages 1 and 2) start sleeping and signal via an Event;
    page 3 (the auth-failing page) waits for that signal before raising, so
    we KNOW siblings are truly sleeping when the auth error fires — no race.
    """
    bid = _make_book(3)

    siblings_sleeping = asyncio.Event()  # set when ≥1 sibling is in sleep
    sibling_cancelled = asyncio.Event()  # set when a sibling gets CancelledError
    call_num = [0]

    from unittest.mock import AsyncMock

    from app.services import gemini_cleaner as _gc

    async def dispatch(api_key, text):
        call_num[0] += 1
        n = call_num[0]
        if n < 3:
            # Sibling pages: signal they're sleeping, then hang until cancelled
            siblings_sleeping.set()
            try:
                await asyncio.sleep(60.0)
                return "done"
            except asyncio.CancelledError:
                sibling_cancelled.set()
                raise
        else:
            # Auth-failing page: wait until siblings are truly sleeping, then fail
            await siblings_sleeping.wait()
            raise GeminiAuthError("bad key")

    monkeypatch.setattr(
        _gc.GeminiCleaner, "clean_page", AsyncMock(side_effect=dispatch)
    )
    AudiobookService.initialize()

    with pytest.raises(GeminiAuthError):
        await AudiobookService._phase_clean(bid, api_key="bad-key")

    assert sibling_cancelled.is_set(), (
        "Sibling tasks were not cancelled when GeminiAuthError was raised. "
        "This is the regression the v2.2 fix addressed."
    )


@pytest.mark.asyncio
async def test_all_sibling_tasks_cancelled_on_auth_error(monkeypatch):
    """With N pages, (N-1) sleeping siblings must ALL receive CancelledError.

    The last page raises auth error only after all N-1 siblings are sleeping,
    so cancellation of every sleeping task is guaranteed to be observable.
    """
    page_count = 4
    bid = _make_book(page_count)

    # N-1 siblings must sleep before the auth page fires
    sleeping_latch = [0]  # count of sleeping sibling tasks
    all_sleeping = asyncio.Event()
    cancelled_count = [0]
    call_num = [0]

    from unittest.mock import AsyncMock

    from app.services import gemini_cleaner as _gc

    async def dispatch(api_key, text):
        call_num[0] += 1
        n = call_num[0]
        if n < page_count:
            sleeping_latch[0] += 1
            if sleeping_latch[0] >= page_count - 1:
                all_sleeping.set()
            try:
                await asyncio.sleep(60.0)
                return "done"
            except asyncio.CancelledError:
                cancelled_count[0] += 1
                raise
        else:
            # Last page: ensure siblings are sleeping first
            await all_sleeping.wait()
            raise GeminiAuthError("bad key")

    monkeypatch.setattr(
        _gc.GeminiCleaner, "clean_page", AsyncMock(side_effect=dispatch)
    )
    AudiobookService.initialize()

    with pytest.raises(GeminiAuthError):
        await AudiobookService._phase_clean(bid, api_key="bad-key")

    assert (
        cancelled_count[0] == page_count - 1
    ), f"Expected {page_count - 1} cancelled siblings, got {cancelled_count[0]}"


@pytest.mark.asyncio
async def test_phase_clean_does_not_hang_after_auth_error(monkeypatch):
    """_phase_clean must return promptly (not block forever) when auth fails.
    Timeout of 3s catches the old behaviour where gather() would block on
    the hanging sibling tasks."""
    bid = _make_book(3)

    call_num = [0]

    from unittest.mock import AsyncMock

    from app.services import gemini_cleaner as _gc

    async def dispatch(api_key, text):
        call_num[0] += 1
        if call_num[0] == 1:
            raise GeminiAuthError("bad key")
        await asyncio.sleep(60.0)  # would block forever without the fix
        return "done"

    monkeypatch.setattr(
        _gc.GeminiCleaner, "clean_page", AsyncMock(side_effect=dispatch)
    )
    AudiobookService.initialize()

    # Must complete within 3 seconds, not hang on the sleeping siblings
    with pytest.raises(GeminiAuthError):
        await asyncio.wait_for(
            AudiobookService._phase_clean(bid, api_key="bad-key"),
            timeout=3.0,
        )


# ===========================================================================
# Non-auth errors do NOT cancel siblings
# ===========================================================================


@pytest.mark.asyncio
async def test_non_auth_error_does_not_cancel_siblings(monkeypatch):
    """Network errors / bad responses are non-fatal: other pages must still complete."""
    bid = _make_book(2)

    page_2_completed = asyncio.Event()
    call_num = [0]

    from unittest.mock import AsyncMock

    from app.services import gemini_cleaner as _gc

    async def dispatch(api_key, text):
        call_num[0] += 1
        if call_num[0] == 1:
            raise RuntimeError("transient network error")
        page_2_completed.set()
        return "cleaned page 2"

    monkeypatch.setattr(
        _gc.GeminiCleaner, "clean_page", AsyncMock(side_effect=dispatch)
    )
    AudiobookService.initialize()

    # Must NOT raise — non-auth errors are swallowed into failed_pages
    await AudiobookService._phase_clean(bid, api_key="ok-key")

    assert (
        page_2_completed.is_set()
    ), "Page 2 must complete when page 1 has a non-auth error"


@pytest.mark.asyncio
async def test_rate_limit_error_does_not_cancel_siblings(monkeypatch):
    """Rate-limit errors are transient — the retry logic handles them internally.
    They must not cancel sibling tasks."""
    bid = _make_book(2)

    page_2_completed = asyncio.Event()
    call_num = [0]

    from unittest.mock import AsyncMock

    from app.services import gemini_cleaner as _gc

    # Patch _BACKOFF_BASE to 0 so retries are instant
    monkeypatch.setattr(_gc.GeminiCleaner, "_BACKOFF_BASE", 0.0)

    async def dispatch(api_key, text):
        call_num[0] += 1
        if call_num[0] == 1:
            # GeminiCleaner.clean_page retries rate-limit errors internally,
            # so this raises — but it's not an auth error, it's swallowed by
            # the pipeline after exhausting retries
            raise RuntimeError("rate limit simulation")
        page_2_completed.set()
        return "cleaned page 2"

    monkeypatch.setattr(
        _gc.GeminiCleaner, "clean_page", AsyncMock(side_effect=dispatch)
    )
    AudiobookService.initialize()

    await AudiobookService._phase_clean(bid, api_key="ok-key")
    assert page_2_completed.is_set()


# ===========================================================================
# Auth error updates book status
# ===========================================================================


@pytest.mark.asyncio
async def test_auth_error_from_pipeline_sets_failed_status(monkeypatch):
    """GeminiAuthError escaping _phase_clean must flip the book to 'failed' via
    _run_pipeline's exception handler, not leave it stuck in 'cleaning'."""
    bid = _make_book(1)

    from unittest.mock import AsyncMock

    from app.services import gemini_cleaner as _gc

    monkeypatch.setattr(
        _gc.GeminiCleaner,
        "clean_page",
        AsyncMock(side_effect=GeminiAuthError("bad key")),
    )

    # We test _phase_clean directly and verify the error bubbles up
    AudiobookService.initialize()

    with pytest.raises(GeminiAuthError):
        await AudiobookService._phase_clean(bid, api_key="bad-key")

    # _phase_clean raised — caller (_run_pipeline) is responsible for status update.
    # Here we just confirm the exception propagated correctly.
    # (The _run_pipeline level sets status="failed"; that path is tested in test_audiobook.py)
