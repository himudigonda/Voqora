"""EngineManager — concurrency + dispatch surface coverage (HARD-041).

This module owns the load/unload + double-load guard for the inference path.
Previously excluded from coverage by `pyproject.toml`'s omit list, which
hid the most consequential concurrency primitives in the backend.
"""

from __future__ import annotations

import asyncio
from unittest.mock import MagicMock

import pytest

from app.services.engine_manager import (
    KOKORO_DEFAULT_VOICE,
    KOKORO_VOICES,
    EngineManager,
)
from app.services.tts import TTSEngine


@pytest.fixture(autouse=True)
def _reset_engine_state():
    """Each test starts with a known-clean TTSEngine class state. The
    EngineManager is a pure pass-through so resetting TTSEngine is enough."""
    saved = (
        TTSEngine._model,
        TTSEngine._executor,
        TTSEngine._is_initializing,
        TTSEngine._load_event,
        TTSEngine._last_request_time,
    )
    TTSEngine._model = None
    TTSEngine._executor = None
    TTSEngine._is_initializing = False
    TTSEngine._load_event = asyncio.Event()
    TTSEngine._last_request_time = 0.0
    yield
    (
        TTSEngine._model,
        TTSEngine._executor,
        TTSEngine._is_initializing,
        TTSEngine._load_event,
        TTSEngine._last_request_time,
    ) = saved


def test_state_returns_kokoro_metadata():
    state = EngineManager.state()
    assert state["engine"] == "kokoro"
    assert isinstance(state["voices"], list)
    assert KOKORO_DEFAULT_VOICE in state["voices"]


def test_voices_list_matches_module_constant():
    assert EngineManager.voices() == KOKORO_VOICES
    assert EngineManager.default_voice() == KOKORO_DEFAULT_VOICE


def test_is_loaded_reflects_model_state():
    assert EngineManager.is_loaded() is False
    TTSEngine._model = MagicMock()
    assert EngineManager.is_loaded() is True


def test_touch_updates_last_request_time(monkeypatch):
    """`touch` resets the idle timer so the idle_watcher doesn't fire mid-job."""
    import time

    fake_now = [10_000.0]
    monkeypatch.setattr(time, "monotonic", lambda: fake_now[0])
    EngineManager.touch()
    assert TTSEngine._last_request_time == 10_000.0
    fake_now[0] += 5
    EngineManager.touch()
    assert TTSEngine._last_request_time == 10_005.0


@pytest.mark.asyncio
async def test_ensure_loaded_no_op_when_already_loaded(monkeypatch):
    """If the model is already loaded, ensure_loaded returns immediately
    without re-initializing."""
    TTSEngine._model = MagicMock()  # pretend already loaded

    initialize_calls = []

    def _spy_initialize():
        initialize_calls.append("called")

    monkeypatch.setattr(TTSEngine, "initialize", _spy_initialize)

    await EngineManager.ensure_loaded()
    assert initialize_calls == []


@pytest.mark.asyncio
async def test_generate_with_timing_passthrough(monkeypatch):
    """generate_with_timing mirrors the existing generate() passthrough exactly:
    forwards args unchanged, yields TTSEngine's items unchanged."""
    captured_args = {}

    async def fake_generate_with_timing(text, voice, speed):
        captured_args.update(text=text, voice=voice, speed=speed)
        yield {
            "index": 0,
            "text": text,
            "ok": True,
            "audio": None,
            "duration_sec": 1.0,
        }

    monkeypatch.setattr(TTSEngine, "generate_with_timing", fake_generate_with_timing)

    items = [
        item
        async for item in EngineManager.generate_with_timing("Hello.", "af_bella", 1.0)
    ]

    assert captured_args == {"text": "Hello.", "voice": "af_bella", "speed": 1.0}
    assert items == [
        {"index": 0, "text": "Hello.", "ok": True, "audio": None, "duration_sec": 1.0}
    ]


@pytest.mark.asyncio
async def test_ensure_loaded_double_load_guard(monkeypatch):
    """Three concurrent cold-start ensure_loaded() coroutines must result in
    exactly ONE TTSEngine.initialize() call. Without the guard, the ONNX
    session would be allocated 3× (~3.6 GB) and the espeak-ng phonemizer
    state would corrupt.
    """
    initialize_calls = 0
    start_signal = asyncio.Event()

    def _slow_initialize():
        nonlocal initialize_calls
        initialize_calls += 1
        # Simulate the expensive ONNX session creation by blocking the executor
        # thread until the signal fires. The other ensure_loaded() coroutines
        # should be waiting on _load_event during this window.
        import time as _time

        _time.sleep(0.1)
        TTSEngine._model = MagicMock()  # mark loaded so the guard short-circuits
        start_signal.set()

    monkeypatch.setattr(TTSEngine, "initialize", _slow_initialize)

    await asyncio.gather(
        EngineManager.ensure_loaded(),
        EngineManager.ensure_loaded(),
        EngineManager.ensure_loaded(),
    )
    assert initialize_calls == 1
    assert start_signal.is_set()
