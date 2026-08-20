import asyncio
from unittest.mock import AsyncMock, patch

import pytest

from app.main import _bg_tasks, _spawn_bg, app, lifespan
from app.services.audiobook_service import AudiobookService
from app.services.engine_manager import EngineManager


@pytest.mark.asyncio
async def test_spawn_bg_tracks_and_discards_task():
    """_spawn_bg must hold a strong reference until the task completes, then
    release it — see HARD-031 (a naive create_task() with no stored ref can
    be GC'd mid-flight)."""
    started = asyncio.Event()

    async def stub():
        started.set()

    task = _spawn_bg(stub())
    assert task in _bg_tasks

    await started.wait()
    await task
    # done_callback fires on the next loop iteration, not synchronously
    # the instant the awaited task completes.
    await asyncio.sleep(0)
    assert task not in _bg_tasks


@pytest.mark.asyncio
async def test_lifespan_holds_all_background_tasks():
    """main.py's 4 lifespan tasks must be held via _bg_tasks, matching the
    pattern already used in app/api/audiobook.py's _bg_tasks/_spawn_bg."""
    with (
        patch.object(EngineManager, "ensure_loaded", new=AsyncMock()),
        patch.object(AudiobookService, "initialize"),
        patch.object(AudiobookService, "resume_in_progress", new=AsyncMock()),
    ):
        async with lifespan(app):
            await asyncio.sleep(0.05)
            # idle_watcher and _parent_watchdog loop forever and must still
            # be tracked; _load_engine_background/resume_in_progress may
            # have already completed (and been discarded) since they're
            # mocked to return instantly — that's expected, not a failure.
            assert len(_bg_tasks) >= 2
            for task in _bg_tasks:
                assert not task.done()

        # idle_watcher/_parent_watchdog loop forever and aren't cancelled by
        # AudiobookService.shutdown — clean them up so they don't leak into
        # later tests sharing this event loop.
        pending = list(_bg_tasks)
        for task in pending:
            task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        assert len(_bg_tasks) == 0
