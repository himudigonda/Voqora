"""Shared interactive speech path used by /speak and the local API."""

from __future__ import annotations

from unittest.mock import AsyncMock, patch

import numpy as np
import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.services.engine_manager import EngineManager
from app.services.speech_stream import open_speech_samples, speakable_text
from app.services.tts import interactive_tts_lock


async def _generate(*_args, **_kwargs):
    yield np.zeros(10, dtype=np.float32)


@pytest.mark.asyncio
async def test_lock_is_held_while_streaming_and_released_after() -> None:
    with (
        patch.object(EngineManager, "ensure_loaded", new=AsyncMock()),
        patch.object(EngineManager, "generate", side_effect=_generate),
    ):
        samples = await open_speech_samples("hi", "af_bella", 1.0)
        assert interactive_tts_lock.locked()
        chunks = [chunk async for chunk in samples]
    assert len(chunks) == 1
    assert not interactive_tts_lock.locked()


@pytest.mark.asyncio
async def test_lock_is_released_when_engine_fails_to_load() -> None:
    failing = AsyncMock(side_effect=RuntimeError("no model"))
    with patch.object(EngineManager, "ensure_loaded", new=failing):
        with pytest.raises(RuntimeError):
            await open_speech_samples("hi", "af_bella", 1.0)
    assert not interactive_tts_lock.locked()


def test_speak_returns_stable_500_when_engine_fails() -> None:
    failing = AsyncMock(side_effect=RuntimeError("/Users/someone/kokoro.onnx"))
    with patch.object(EngineManager, "ensure_loaded", new=failing):
        response = TestClient(app).post(
            "/speak", json={"text": "hello", "voice": "af_bella"}
        )
    assert response.status_code == 500
    assert "/Users/" not in response.text
    assert not interactive_tts_lock.locked()


def test_speakable_text_strips_markdown_and_rejects_blank() -> None:
    assert speakable_text("  **Hello**  ") == "Hello"
    with pytest.raises(ValueError):
        speakable_text("   ")
