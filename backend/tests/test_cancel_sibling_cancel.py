from __future__ import annotations

import asyncio
import os
import shutil
from unittest.mock import AsyncMock

import pytest

from app.services import llm_cleaner as _lc
from app.services.audiobook_service import AudiobookCancelled, AudiobookService
from app.services.audiobook_store import AudiobookStore
from app.services.llm_providers import LLMAuthError, LLMCredential

CREDENTIAL = LLMCredential.gemini("irrelevant")


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
    AudiobookService._queue = None
    AudiobookService._worker_task = None
    AudiobookService._executor = None
    AudiobookService._cancel_flags = {}
    yield
    AudiobookService._queue = None
    AudiobookService._worker_task = None
    AudiobookService._cancel_flags = {}
    if AudiobookService._executor is not None:
        AudiobookService._executor.shutdown(wait=False, cancel_futures=True)
        AudiobookService._executor = None


def _make_book(page_count: int = 3) -> str:
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", page_count, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["uses_gemini_cleanup"] = True
    AudiobookStore.write_meta(bid, meta)
    for n in range(1, page_count + 1):
        raw = AudiobookStore.page_raw_path(bid, n)
        os.makedirs(os.path.dirname(raw), exist_ok=True)
        with open(raw, "w", encoding="utf-8") as f:
            f.write("A" * 200)
    return bid


@pytest.mark.asyncio
async def test_phase_clean_re_raises_audiobook_cancelled():
    bid = _make_book(2)
    AudiobookService.initialize()
    AudiobookService.cancel(bid)

    with pytest.raises(AudiobookCancelled):
        await AudiobookService._phase_clean(bid, CREDENTIAL)


@pytest.mark.asyncio
async def test_phase_clean_cancels_sibling_tasks_on_cancellation(monkeypatch):
    bid = _make_book(5)
    sleepers = AudiobookService._CLEAN_PARALLELISM - 1
    all_sleeping = asyncio.Event()
    release_gate = asyncio.Event()
    sleeping = [0]
    cancelled = [0]
    call_num = [0]

    async def dispatch(credential, text):
        call_num[0] += 1
        n = call_num[0]
        if n <= sleepers:
            sleeping[0] += 1
            if sleeping[0] == sleepers:
                all_sleeping.set()
            try:
                await asyncio.sleep(60.0)
                return "done"
            except asyncio.CancelledError:
                cancelled[0] += 1
                raise
        if n == sleepers + 1:
            await release_gate.wait()
            return "cleaned"
        raise AssertionError(f"unexpected clean_page call #{n}")

    monkeypatch.setattr(_lc.LLMCleaner, "clean_page", AsyncMock(side_effect=dispatch))
    AudiobookService.initialize()

    task = asyncio.create_task(AudiobookService._phase_clean(bid, CREDENTIAL))
    await all_sleeping.wait()
    AudiobookService.cancel(bid)
    release_gate.set()

    with pytest.raises(AudiobookCancelled):
        await asyncio.wait_for(task, timeout=5.0)

    assert cancelled[0] == sleepers


@pytest.mark.asyncio
async def test_phase_clean_cancellation_interrupts_in_flight_pages_of_a_small_book(
    monkeypatch,
):
    bid = _make_book(3)
    assert AudiobookService._CLEAN_PARALLELISM >= 3
    all_started = asyncio.Event()
    started = [0]
    cancelled = [0]

    async def dispatch(credential, text):
        started[0] += 1
        if started[0] == 3:
            all_started.set()
        try:
            await asyncio.sleep(60.0)
            return "done"
        except asyncio.CancelledError:
            cancelled[0] += 1
            raise

    monkeypatch.setattr(_lc.LLMCleaner, "clean_page", AsyncMock(side_effect=dispatch))
    AudiobookService.initialize()

    task = asyncio.create_task(AudiobookService._phase_clean(bid, CREDENTIAL))
    await all_started.wait()
    AudiobookService.cancel(bid)

    with pytest.raises(AudiobookCancelled):
        await asyncio.wait_for(task, timeout=3.0)

    assert cancelled[0] == 3


@pytest.mark.asyncio
async def test_phase_clean_does_not_hang_after_cancellation(monkeypatch):
    monkeypatch.setattr(AudiobookService, "_CLEAN_PARALLELISM", 2)
    bid = _make_book(3)
    sleeper_ready = asyncio.Event()
    release_gate = asyncio.Event()
    call_num = [0]

    async def dispatch(credential, text):
        call_num[0] += 1
        if call_num[0] == 1:
            sleeper_ready.set()
            await asyncio.sleep(60.0)
            return "done"
        if call_num[0] == 2:
            await release_gate.wait()
            return "cleaned"
        raise AssertionError(f"unexpected clean_page call #{call_num[0]}")

    monkeypatch.setattr(_lc.LLMCleaner, "clean_page", AsyncMock(side_effect=dispatch))
    AudiobookService.initialize()

    task = asyncio.create_task(AudiobookService._phase_clean(bid, CREDENTIAL))
    await sleeper_ready.wait()
    AudiobookService.cancel(bid)
    release_gate.set()

    with pytest.raises(AudiobookCancelled):
        await asyncio.wait_for(task, timeout=3.0)


@pytest.mark.asyncio
async def test_auth_error_still_cancels_siblings_alongside_cancellation(monkeypatch):
    bid = _make_book(2)
    sibling_cancelled = asyncio.Event()
    call_num = [0]

    async def dispatch(credential, text):
        call_num[0] += 1
        if call_num[0] == 1:
            try:
                await asyncio.sleep(60.0)
            except asyncio.CancelledError:
                sibling_cancelled.set()
                raise
        raise LLMAuthError("bad key")

    monkeypatch.setattr(_lc.LLMCleaner, "clean_page", AsyncMock(side_effect=dispatch))
    AudiobookService.initialize()

    with pytest.raises(LLMAuthError):
        await asyncio.wait_for(AudiobookService._phase_clean(bid, CREDENTIAL), 3.0)

    assert sibling_cancelled.is_set()
