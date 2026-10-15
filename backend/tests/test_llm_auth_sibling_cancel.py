from __future__ import annotations

import asyncio
import os
import shutil
from unittest.mock import AsyncMock

import pytest

from app.services import llm_cleaner as _lc
from app.services.audiobook_service import AudiobookService
from app.services.audiobook_store import AudiobookStore
from app.services.llm_providers import LLMAuthError, LLMCredential

CREDENTIAL = LLMCredential.gemini("bad-key")


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
    yield
    AudiobookService._queue = None
    AudiobookService._worker_task = None
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
async def test_phase_clean_re_raises_llm_auth_error(monkeypatch):
    bid = _make_book(2)
    monkeypatch.setattr(
        _lc.LLMCleaner, "clean_page", AsyncMock(side_effect=LLMAuthError("bad key"))
    )
    AudiobookService.initialize()

    with pytest.raises(LLMAuthError):
        await AudiobookService._phase_clean(bid, CREDENTIAL)


@pytest.mark.asyncio
async def test_phase_clean_cancels_sibling_tasks_on_auth_error(monkeypatch):
    bid = _make_book(3)
    siblings_sleeping = asyncio.Event()
    sibling_cancelled = asyncio.Event()
    call_num = [0]

    async def dispatch(credential, text):
        call_num[0] += 1
        if call_num[0] < 3:
            siblings_sleeping.set()
            try:
                await asyncio.sleep(60.0)
                return "done"
            except asyncio.CancelledError:
                sibling_cancelled.set()
                raise
        await siblings_sleeping.wait()
        raise LLMAuthError("bad key")

    monkeypatch.setattr(_lc.LLMCleaner, "clean_page", AsyncMock(side_effect=dispatch))
    AudiobookService.initialize()

    with pytest.raises(LLMAuthError):
        await asyncio.wait_for(AudiobookService._phase_clean(bid, CREDENTIAL), 5.0)

    assert sibling_cancelled.is_set()


@pytest.mark.asyncio
async def test_all_sibling_tasks_cancelled_on_auth_error(monkeypatch):
    page_count = 4
    bid = _make_book(page_count)
    sleeping = [0]
    all_sleeping = asyncio.Event()
    cancelled = [0]
    call_num = [0]

    async def dispatch(credential, text):
        call_num[0] += 1
        if call_num[0] < page_count:
            sleeping[0] += 1
            if sleeping[0] >= page_count - 1:
                all_sleeping.set()
            try:
                await asyncio.sleep(60.0)
                return "done"
            except asyncio.CancelledError:
                cancelled[0] += 1
                raise
        await all_sleeping.wait()
        raise LLMAuthError("bad key")

    monkeypatch.setattr(_lc.LLMCleaner, "clean_page", AsyncMock(side_effect=dispatch))
    AudiobookService.initialize()

    with pytest.raises(LLMAuthError):
        await asyncio.wait_for(AudiobookService._phase_clean(bid, CREDENTIAL), 5.0)

    assert cancelled[0] == page_count - 1


@pytest.mark.asyncio
async def test_phase_clean_does_not_hang_after_auth_error(monkeypatch):
    bid = _make_book(3)
    call_num = [0]

    async def dispatch(credential, text):
        call_num[0] += 1
        if call_num[0] == 1:
            raise LLMAuthError("bad key")
        await asyncio.sleep(60.0)
        return "done"

    monkeypatch.setattr(_lc.LLMCleaner, "clean_page", AsyncMock(side_effect=dispatch))
    AudiobookService.initialize()

    with pytest.raises(LLMAuthError):
        await asyncio.wait_for(AudiobookService._phase_clean(bid, CREDENTIAL), 3.0)


@pytest.mark.asyncio
async def test_non_auth_error_does_not_cancel_siblings(monkeypatch):
    bid = _make_book(2)
    page_2_completed = asyncio.Event()
    call_num = [0]

    async def dispatch(credential, text):
        call_num[0] += 1
        if call_num[0] == 1:
            raise RuntimeError("transient network error")
        page_2_completed.set()
        return "cleaned page 2"

    monkeypatch.setattr(_lc.LLMCleaner, "clean_page", AsyncMock(side_effect=dispatch))
    AudiobookService.initialize()

    await AudiobookService._phase_clean(bid, CREDENTIAL)

    assert page_2_completed.is_set()
    assert AudiobookStore.read_meta(bid)["failed_pages"] == [1]
