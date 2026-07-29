"""Tests for D2: AudiobookCancelled sibling-task cancellation in _phase_clean,
and the AudiobookStore.update_meta guard against resurrecting a deleted book.

Mirrors tests/test_gemini_auth_sibling_cancel.py's pattern (same bug class —
an exception escaping one clean_one() task must cancel every sibling task,
not leave them running as orphans), but for AudiobookCancelled instead of
GeminiAuthError.

Before this fix, _phase_clean's except clause only caught GeminiAuthError:

    tasks = [asyncio.create_task(clean_one(n)) for n in pending]
    try:
        await asyncio.gather(*tasks)
    except GeminiAuthError:
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        raise

A cancel mid-clean-phase raised AudiobookCancelled from one task but left
every sibling Gemini task running as an orphan — one of which could finish
after the pipeline had already unwound and a follow-up delete had removed
the book, and its own update_meta() call would silently resurrect a ghost
DB row for a book_id that no longer exists. The fix adds AudiobookCancelled
to the except tuple (same cancellation handling) AND guards update_meta
itself against writing a row for a missing book_id, as defense in depth.

IMPORTANT asymmetry vs. GeminiAuthError: clean_one()'s try/except only
re-raises GeminiAuthError explicitly; every other exception raised INSIDE
that try block (including, if mocked there, AudiobookCancelled) is caught by
the generic `except Exception` and swallowed into failed_pages. In real
code, AudiobookCancelled can only ever escape clean_one() via the
_check_cancel(book_id) call at the TOP of the function — BEFORE the
try/except — so these tests trigger it that way (via the real
AudiobookService._cancel_flags, exactly as the /cancel endpoint does), not
by mocking clean_page to raise it directly.
"""

from __future__ import annotations

import asyncio
import os
import shutil

import pytest

from app.services.audiobook_service import AudiobookCancelled, AudiobookService
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
    """Each test gets a fresh service state (queue + worker + cancel flags)."""
    AudiobookService._queue = None
    AudiobookService._worker_task = None
    AudiobookService._executor = None
    AudiobookService._cancel_flags = {}
    AudiobookService._cancel_events = {}
    yield
    AudiobookService._queue = None
    AudiobookService._worker_task = None
    AudiobookService._cancel_flags = {}
    AudiobookService._cancel_events = {}
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
        # Write content long enough to skip the OCR threshold (50 chars).
        with open(raw, "w", encoding="utf-8") as f:
            f.write("A" * 200)
    return bid


# ===========================================================================
# AudiobookCancelled propagation + sibling cancellation (T5.1 / D2)
# ===========================================================================


@pytest.mark.asyncio
async def test_phase_clean_re_raises_audiobook_cancelled():
    """When cancellation is observed via _check_cancel, _phase_clean must
    propagate AudiobookCancelled (not swallow it)."""
    bid = _make_book(2)
    AudiobookService.initialize()
    AudiobookService.cancel(bid)  # sets the real flag, exactly as /cancel does

    with pytest.raises(AudiobookCancelled):
        await AudiobookService._phase_clean(bid, api_key="irrelevant")


@pytest.mark.asyncio
async def test_phase_clean_cancels_sibling_tasks_on_cancellation(monkeypatch):
    """A cancellation observed by one page's _check_cancel() must cancel
    every OTHER page's still-in-flight clean_one() task.

    Design: _CLEAN_PARALLELISM (4) pages start immediately and fill the
    semaphore. 3 of them ("sleepers") hang in a mocked Gemini call and
    signal via an Event once all 3 are confirmed sleeping. The 4th
    ("releaser") waits for an explicit test-controlled gate before
    returning — freeing its slot for the 5th (queued) page. The test only
    opens that gate AFTER calling AudiobookService.cancel(bid), guaranteeing
    the 5th page's _check_cancel() observes the flag deterministically (no
    race) and raises AudiobookCancelled — exactly mirroring a real /cancel
    call landing while a real clean phase has pages genuinely in flight.
    """
    bid = _make_book(5)
    n_sleepers = AudiobookService._CLEAN_PARALLELISM - 1  # 3

    all_sleeping = asyncio.Event()
    release_gate = asyncio.Event()
    sleeping_count = [0]
    cancelled_count = [0]
    call_num = [0]

    from unittest.mock import AsyncMock

    from app.services import gemini_cleaner as _gc

    async def dispatch(api_key, text):
        call_num[0] += 1
        n = call_num[0]
        if n <= n_sleepers:
            sleeping_count[0] += 1
            if sleeping_count[0] == n_sleepers:
                all_sleeping.set()
            try:
                await asyncio.sleep(60.0)
                return "done"
            except asyncio.CancelledError:
                cancelled_count[0] += 1
                raise
        elif n == n_sleepers + 1:
            # Releaser: only frees its semaphore slot once the test has
            # already flipped the cancel flag (see below) — guarantees the
            # 5th (queued) page's _check_cancel() sees it deterministically.
            await release_gate.wait()
            return "cleaned"
        else:
            raise AssertionError(
                f"unexpected clean_page call #{n} — the 5th page should have "
                "been stopped by _check_cancel() before ever reaching here"
            )

    monkeypatch.setattr(
        _gc.GeminiCleaner, "clean_page", AsyncMock(side_effect=dispatch)
    )
    AudiobookService.initialize()

    task = asyncio.create_task(AudiobookService._phase_clean(bid, api_key="irrelevant"))
    await all_sleeping.wait()
    # Simulate a real /cancel call landing while 3 siblings are confirmed
    # in-flight and the 5th page is still queued behind the semaphore.
    AudiobookService.cancel(bid)
    release_gate.set()

    with pytest.raises(AudiobookCancelled):
        await asyncio.wait_for(task, timeout=5.0)

    assert cancelled_count[0] == n_sleepers, (
        f"Expected all {n_sleepers} sleeping siblings to be cancelled, "
        f"got {cancelled_count[0]}. This is the D2 regression: orphaned "
        "siblings could keep running Gemini calls (and later resurrect a "
        "deleted book's DB row via a stale update_meta() call) after the "
        "pipeline had already unwound."
    )


@pytest.mark.asyncio
async def test_phase_clean_cancellation_takes_effect_for_small_books_mid_flight(
    monkeypatch,
):
    """_check_cancel() is only consulted once per page, right when
    clean_one() acquires its semaphore slot — never again while that page's
    Gemini call is actually in flight. For page_count <= _CLEAN_PARALLELISM
    (the real default, 4 — deliberately NOT patched down here, unlike the
    test above), every page acquires a slot and starts immediately; no task
    is ever left queued behind the semaphore to notice a flag set later.

    Without racing the in-flight Gemini call itself against cancellation
    (_await_cancellable), a /cancel landing during this window was
    invisible until the NEXT pipeline phase — _phase_clean would complete
    normally without ever raising AudiobookCancelled, burning the full
    Gemini cost for every already-in-flight page first. This is exactly the
    common case (an ordinary short document) the 5-page test above
    deliberately sidesteps by using more pages than parallelism allows.
    """
    bid = _make_book(3)  # 3 <= _CLEAN_PARALLELISM (4) — none ever queue
    assert AudiobookService._CLEAN_PARALLELISM >= 3, "test assumes no queueing"

    all_started = asyncio.Event()
    started_count = [0]
    cancelled_count = [0]

    from unittest.mock import AsyncMock

    from app.services import gemini_cleaner as _gc

    async def dispatch(api_key, text):
        started_count[0] += 1
        if started_count[0] == 3:
            all_started.set()
        try:
            await asyncio.sleep(60.0)
            return "done"
        except asyncio.CancelledError:
            cancelled_count[0] += 1
            raise

    monkeypatch.setattr(
        _gc.GeminiCleaner, "clean_page", AsyncMock(side_effect=dispatch)
    )
    AudiobookService.initialize()

    task = asyncio.create_task(AudiobookService._phase_clean(bid, api_key="irrelevant"))
    await all_started.wait()
    # All 3 pages are now genuinely mid-flight (none queued) — this is the
    # exact moment a real /cancel call would previously have no effect.
    AudiobookService.cancel(bid)

    with pytest.raises(AudiobookCancelled):
        await asyncio.wait_for(task, timeout=3.0)

    assert cancelled_count[0] == 3, (
        f"Expected all 3 in-flight pages to be interrupted promptly, got "
        f"{cancelled_count[0]}. This is the small-book D2 gap: with "
        "page_count <= _CLEAN_PARALLELISM, no task is ever left queued to "
        "observe _check_cancel(), so a mid-flight cancel was previously "
        "invisible until the NEXT pipeline phase."
    )


@pytest.mark.asyncio
async def test_phase_clean_does_not_hang_after_cancellation(monkeypatch):
    """Safety-net companion to the sibling-cancellation test above:
    _phase_clean must resolve within a bounded time on cancellation, whether
    or not siblings get explicitly cancelled along the way (in THIS
    codebase, an unmatched exception from asyncio.gather() propagates
    immediately either way — it does not itself hang pre-fix — so this test
    does not by itself discriminate pre/post-fix; it guards against a
    hang being introduced if _phase_clean's structure ever changes, e.g. to
    gather(..., return_exceptions=True) with manual result inspection).

    Parallelism is patched down to 2 (from the real 4) so that, with 3
    pages, exactly one is left queued behind the semaphore — the same
    "releaser frees a slot only after the flag is set" choreography as
    test_phase_clean_cancels_sibling_tasks_on_cancellation, just with fewer
    moving parts.
    """
    monkeypatch.setattr(AudiobookService, "_CLEAN_PARALLELISM", 2)
    bid = _make_book(3)

    sleeper_ready = asyncio.Event()
    release_gate = asyncio.Event()
    call_num = [0]

    from unittest.mock import AsyncMock

    from app.services import gemini_cleaner as _gc

    async def dispatch(api_key, text):
        call_num[0] += 1
        n = call_num[0]
        if n == 1:
            sleeper_ready.set()
            await asyncio.sleep(60.0)  # would block forever without the fix
            return "done"
        elif n == 2:
            await release_gate.wait()
            return "cleaned"
        else:
            raise AssertionError(f"unexpected clean_page call #{n}")

    monkeypatch.setattr(
        _gc.GeminiCleaner, "clean_page", AsyncMock(side_effect=dispatch)
    )
    AudiobookService.initialize()

    task = asyncio.create_task(AudiobookService._phase_clean(bid, api_key="irrelevant"))
    await sleeper_ready.wait()
    AudiobookService.cancel(bid)
    release_gate.set()

    # Must complete within 3 seconds, not hang on the sleeping sibling.
    with pytest.raises(AudiobookCancelled):
        await asyncio.wait_for(task, timeout=3.0)


@pytest.mark.asyncio
async def test_gemini_auth_error_still_cancels_siblings_after_fix(monkeypatch):
    """Non-regression: adding AudiobookCancelled to the except tuple must not
    disturb the pre-existing GeminiAuthError sibling-cancellation behaviour."""
    bid = _make_book(2)

    sibling_cancelled = asyncio.Event()
    call_num = [0]

    from unittest.mock import AsyncMock

    from app.services import gemini_cleaner as _gc

    async def dispatch(api_key, text):
        call_num[0] += 1
        if call_num[0] == 1:
            try:
                await asyncio.sleep(60.0)
            except asyncio.CancelledError:
                sibling_cancelled.set()
                raise
        else:
            raise GeminiAuthError("bad key")

    monkeypatch.setattr(
        _gc.GeminiCleaner, "clean_page", AsyncMock(side_effect=dispatch)
    )
    AudiobookService.initialize()

    with pytest.raises(GeminiAuthError):
        await asyncio.wait_for(
            AudiobookService._phase_clean(bid, api_key="bad-key"), timeout=3.0
        )


# ===========================================================================
# AudiobookStore.update_meta guard against resurrecting a deleted book (D2)
# ===========================================================================


@pytest.mark.asyncio
async def test_update_meta_on_deleted_book_is_noop():
    """The other half of D2: an orphaned task's late update_meta() call must
    never resurrect a row for a book_id that's already been deleted."""
    bid = AudiobookStore.create_book("Ghost.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Ghost.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    AudiobookStore.write_meta(bid, meta)
    assert AudiobookStore.read_meta(bid) is not None  # sanity: row exists

    AudiobookStore.delete_book(bid)
    assert AudiobookStore.read_meta(bid) is None  # sanity: row is gone

    # Simulate the orphaned sibling task's late write.
    result = await AudiobookStore.update_meta(
        bid, status="done", actual={"pages": 1, "words": 10}
    )

    assert result == {}, "update_meta on a deleted book_id must return {} (no-op)"
    assert (
        AudiobookStore.read_meta(bid) is None
    ), "update_meta must NOT resurrect a ghost row for a deleted book_id"
    assert bid not in {b["book_id"] for b in AudiobookStore.list_books()}


@pytest.mark.asyncio
async def test_update_meta_on_existing_book_still_writes():
    """Non-regression: the no-op guard must not block ordinary updates to a
    book that genuinely exists."""
    bid = AudiobookStore.create_book("Real.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Real.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    AudiobookStore.write_meta(bid, meta)

    result = await AudiobookStore.update_meta(bid, status="cleaning")

    assert result["status"] == "cleaning"
    persisted = AudiobookStore.read_meta(bid)
    assert persisted is not None
    assert persisted["status"] == "cleaning"
