"""Shared interactive speech path used by /speak and the local API."""

from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, patch

import numpy as np
import pytest
from fastapi.testclient import TestClient
from starlette.requests import ClientDisconnect

from app.main import app
from app.services.audio import AudioService
from app.services.engine_manager import EngineManager
from app.services.speech_stream import (
    SpeechStreamResponse,
    open_speech_samples,
    speakable_text,
)
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


@pytest.mark.asyncio
async def test_pause_length_reaches_the_engine_without_a_book_scope() -> None:
    with (
        patch.object(EngineManager, "ensure_loaded", new=AsyncMock()),
        patch.object(EngineManager, "generate", side_effect=_generate) as generate,
    ):
        samples = await open_speech_samples("hi", "af_bella", 1.0, pause_scale=1.5)
        [chunk async for chunk in samples]
    assert generate.call_args.kwargs == {"pause_scale": 1.5, "book_id": None}


def _engine():
    return (
        patch.object(EngineManager, "ensure_loaded", new=AsyncMock()),
        patch.object(EngineManager, "generate", side_effect=_generate),
    )


@pytest.mark.asyncio
async def test_closing_before_the_first_chunk_releases_the_lock() -> None:
    first, second = _engine()
    with first, second:
        samples = await open_speech_samples("hi", "af_bella", 1.0)
        await samples.aclose()
        assert not interactive_tts_lock.locked()
        await interactive_tts_lock.acquire()
        await samples.aclose()
        assert interactive_tts_lock.locked()
        interactive_tts_lock.release()


async def _ignore_receive() -> dict:
    await asyncio.Event().wait()
    return {}


@pytest.mark.asyncio
async def test_stream_response_releases_the_lock_when_the_client_is_gone() -> None:
    async def gone(_message: dict) -> None:
        raise OSError("client went away")

    first, second = _engine()
    with first, second:
        samples = await open_speech_samples("hi", "af_bella", 1.0)
        response = SpeechStreamResponse(
            samples, AudioService.stream_samples_to_wav(samples, 1.0), "audio/wav"
        )
        scope = {"type": "http", "asgi": {"spec_version": "2.4"}}
        with pytest.raises(ClientDisconnect):
            await response(scope, _ignore_receive, gone)
    assert not interactive_tts_lock.locked()


@pytest.mark.asyncio
async def test_stream_response_releases_the_lock_on_disconnect_before_reading() -> None:
    started = asyncio.Event()

    async def disconnect() -> dict:
        await started.wait()
        return {"type": "http.disconnect"}

    async def stalled(_message: dict) -> None:
        started.set()
        await asyncio.Event().wait()

    first, second = _engine()
    with first, second:
        samples = await open_speech_samples("hi", "af_bella", 1.0)
        response = SpeechStreamResponse(
            samples, AudioService.stream_samples_to_wav(samples, 1.0), "audio/wav"
        )
        await asyncio.wait_for(response({"type": "http"}, disconnect, stalled), 5)
    assert not interactive_tts_lock.locked()


@pytest.mark.asyncio
async def test_stream_response_releases_the_lock_when_cancelled() -> None:
    sent = asyncio.Event()

    async def stalled(_message: dict) -> None:
        sent.set()
        await asyncio.Event().wait()

    first, second = _engine()
    with first, second:
        samples = await open_speech_samples("hi", "af_bella", 1.0)
        response = SpeechStreamResponse(
            samples, AudioService.stream_samples_to_wav(samples, 1.0), "audio/wav"
        )
        scope = {"type": "http", "asgi": {"spec_version": "2.4"}}
        task = asyncio.create_task(response(scope, _ignore_receive, stalled))
        await asyncio.wait_for(sent.wait(), 5)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
    assert not interactive_tts_lock.locked()


def test_speak_streams_and_releases_the_lock() -> None:
    first, second = _engine()
    with first, second:
        response = TestClient(app).post(
            "/speak", json={"text": "hello", "voice": "af_bella"}
        )
    assert response.status_code == 200
    assert response.headers["content-type"] == "audio/wav"
    assert not interactive_tts_lock.locked()
