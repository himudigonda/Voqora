"""OpenAI-compatible contract of the local API: models, voices, speech."""

from __future__ import annotations

import asyncio
import io
import wave
from unittest.mock import AsyncMock, patch

import numpy as np
import pytest
import soundfile as sf
from fastapi.testclient import TestClient

from app.api.public_app import create_public_app
from app.services.engine_manager import EngineManager
from app.services.languages import VOICE_IDS
from app.services.public_voices import (
    OPENAI_VOICE_ALIASES,
    custom_voices,
    resolve_voice,
    voice_list,
)
from app.services.speech_stream import clamp_engine_speed
from app.services.tts import interactive_tts_lock

API_KEY = "test-local-api-key-0123456789abcdef"
AUTH = {"Authorization": f"Bearer {API_KEY}"}
SAMPLES = 2400


async def _generate(*_args, **_kwargs):
    yield np.linspace(-0.2, 0.2, SAMPLES, dtype=np.float32)
    yield np.linspace(0.2, -0.2, SAMPLES, dtype=np.float32)


async def _failing_generate(*_args, **_kwargs):
    yield np.zeros(SAMPLES, dtype=np.float32)
    raise RuntimeError("simulated failure at /Users/someone/secret.onnx")


@pytest.fixture
def client() -> TestClient:
    return TestClient(create_public_app(API_KEY), headers=AUTH)


@pytest.fixture
def engine():
    with (
        patch.object(EngineManager, "ensure_loaded", new=AsyncMock()),
        patch.object(EngineManager, "generate", side_effect=_generate) as generate,
    ):
        yield generate


def _speech(**overrides) -> dict:
    body = {"model": "tts-1", "input": "Hello from the local API.", "voice": "alloy"}
    body.update(overrides)
    return body


def test_models_list_shape(client: TestClient) -> None:
    body = client.get("/v1/models").json()
    assert body["object"] == "list"
    assert [m["id"] for m in body["data"]] == ["kokoro", "tts-1", "tts-1-hd"]
    for model in body["data"]:
        assert model["object"] == "model"
        assert model["owned_by"] == "voqora"
        assert isinstance(model["created"], int)


def test_voices_list_includes_builtins_and_aliases(client: TestClient) -> None:
    body = client.get("/v1/voices").json()
    ids = [voice["id"] for voice in body["data"]]
    assert ids[: len(VOICE_IDS)] == VOICE_IDS
    first = body["data"][0]
    assert set(first) == {"id", "name", "gender", "language", "type"}
    assert first["type"] == "builtin"
    assert body["aliases"] == OPENAI_VOICE_ALIASES


def test_voices_list_includes_custom_ids_when_present() -> None:
    state = {**EngineManager.state(), "blends": [{"id": "blend_warm", "name": "Warm"}]}
    with patch.object(EngineManager, "state", return_value=state):
        voices = voice_list()
        assert voices[-1] == {"id": "blend_warm", "name": "Warm", "type": "custom"}
        assert resolve_voice("blend_warm") == "blend_warm"


def test_custom_voices_ignore_malformed_entries() -> None:
    state = {"blends": [{"id": 3}, "x", {"name": "nameless"}, {"id": "ok"}]}
    with patch.object(EngineManager, "state", return_value=state):
        assert custom_voices() == [{"id": "ok", "name": "ok", "type": "custom"}]


def test_no_custom_voices_by_default() -> None:
    assert custom_voices() == []


@pytest.mark.parametrize("alias", sorted(OPENAI_VOICE_ALIASES))
def test_openai_voice_names_map_to_builtin_voices(alias: str) -> None:
    assert resolve_voice(alias) in VOICE_IDS
    assert resolve_voice(alias.upper()) == resolve_voice(alias)


def test_voice_resolution_rules() -> None:
    assert resolve_voice("bm_george") == "bm_george"
    assert resolve_voice("fable") == "bm_fable"
    assert resolve_voice("nonexistent") is None
    assert resolve_voice("AF_BELLA") is None


@pytest.mark.parametrize(
    "requested,expected", [(0.25, 0.5), (0.5, 0.5), (1.3, 1.3), (2.0, 2.0), (4.0, 2.0)]
)
def test_engine_speed_is_clamped(requested: float, expected: float) -> None:
    assert clamp_engine_speed(requested) == expected


def test_speech_wav_streams_riff_audio(client: TestClient, engine) -> None:
    response = client.post("/v1/audio/speech", json=_speech(response_format="wav"))
    assert response.status_code == 200
    assert response.headers["content-type"] == "audio/wav"
    assert response.content[:4] == b"RIFF"
    assert response.content[8:12] == b"WAVE"
    with wave.open(io.BytesIO(response.content)) as wav:
        assert wav.getframerate() == 24000
        assert wav.getnchannels() == 1
        assert wav.getsampwidth() == 2


def test_speech_defaults_to_wav(client: TestClient, engine) -> None:
    response = client.post("/v1/audio/speech", json=_speech())
    assert response.status_code == 200
    assert response.headers["content-type"] == "audio/wav"


def test_speech_pcm_is_raw_little_endian_int16(client: TestClient, engine) -> None:
    response = client.post("/v1/audio/speech", json=_speech(response_format="pcm"))
    assert response.status_code == 200
    assert response.headers["content-type"] == "audio/pcm"
    assert len(response.content) == SAMPLES * 2 * 2
    pcm = np.frombuffer(response.content, dtype="<i2")
    assert pcm[0] == int(-0.2 * 32767)


def test_speech_flac_decodes(client: TestClient, engine) -> None:
    response = client.post("/v1/audio/speech", json=_speech(response_format="flac"))
    assert response.status_code == 200
    assert response.headers["content-type"] == "audio/flac"
    data, rate = sf.read(io.BytesIO(response.content))
    assert rate == 24000
    assert data.shape == (SAMPLES * 2,)


def test_speech_maps_voice_and_clamps_speed(client: TestClient, engine) -> None:
    response = client.post("/v1/audio/speech", json=_speech(voice="onyx", speed=4.0))
    assert response.status_code == 200
    text, voice, speed, lang = engine.call_args.args
    assert voice == "am_adam"
    assert speed == 2.0
    assert lang is None
    assert text == "Hello from the local API."


def test_speech_accepts_native_voice_and_hd_alias(client: TestClient, engine) -> None:
    response = client.post(
        "/v1/audio/speech", json=_speech(model="tts-1-hd", voice="ff_siwis")
    )
    assert response.status_code == 200
    assert engine.call_args.args[1] == "ff_siwis"


def test_speech_strips_markdown(client: TestClient, engine) -> None:
    client.post("/v1/audio/speech", json=_speech(input="# Title\n\n**bold** text"))
    assert "#" not in engine.call_args.args[0]
    assert "*" not in engine.call_args.args[0]


@pytest.mark.parametrize("fmt", ["mp3", "opus", "aac", "WAV", "ogg"])
def test_unsupported_response_format_is_a_clear_400(
    client: TestClient, engine, fmt: str
) -> None:
    response = client.post("/v1/audio/speech", json=_speech(response_format=fmt))
    assert response.status_code == 400
    error = response.json()["error"]
    assert error["type"] == "invalid_request_error"
    assert error["param"] == "response_format"
    assert "wav, pcm, flac" in error["message"]
    engine.assert_not_called()


@pytest.mark.parametrize(
    "overrides,param",
    [
        ({"model": "gpt-4"}, "model"),
        ({"voice": "unknown_voice"}, "voice"),
        ({"input": ""}, "input"),
        ({"input": "   "}, "input"),
        ({"input": "a" * 50_001}, "input"),
        ({"speed": 0.1}, "speed"),
        ({"speed": 4.5}, "speed"),
        ({"voice": "v" * 65}, "voice"),
        ({"response_format": "w" * 17}, "response_format"),
    ],
)
def test_invalid_speech_requests_are_400(
    client: TestClient, engine, overrides: dict, param: str
) -> None:
    response = client.post("/v1/audio/speech", json=_speech(**overrides))
    assert response.status_code == 400
    assert response.json()["error"]["param"] == param
    engine.assert_not_called()


def test_missing_fields_are_400(client: TestClient, engine) -> None:
    response = client.post("/v1/audio/speech", json={"input": "hi"})
    assert response.status_code == 400
    assert response.json()["error"]["param"] == "model"


def test_malformed_json_is_400(client: TestClient, engine) -> None:
    response = client.post(
        "/v1/audio/speech",
        content=b"{not json",
        headers={"Content-Type": "application/json"},
    )
    assert response.status_code == 400
    error = response.json()["error"]
    assert error["message"] == "Request body is not valid JSON."
    assert error["param"] is None


def test_input_at_limit_is_accepted(client: TestClient, engine) -> None:
    response = client.post("/v1/audio/speech", json=_speech(input="a" * 50_000))
    assert response.status_code == 200


def test_speech_releases_interactive_lock(client: TestClient, engine) -> None:
    client.post("/v1/audio/speech", json=_speech())
    assert not interactive_tts_lock.locked()


def test_engine_load_failure_is_500_without_internals(client: TestClient) -> None:
    failing = AsyncMock(side_effect=RuntimeError("/Users/someone/model.onnx missing"))
    with patch.object(EngineManager, "ensure_loaded", new=failing):
        response = client.post("/v1/audio/speech", json=_speech())
    assert response.status_code == 500
    assert "/Users/" not in response.text
    assert "RuntimeError" not in response.text
    assert response.json()["error"]["type"] == "server_error"
    assert not interactive_tts_lock.locked()


def test_midstream_failure_truncates_cleanly(client: TestClient) -> None:
    with (
        patch.object(EngineManager, "ensure_loaded", new=AsyncMock()),
        patch.object(EngineManager, "generate", side_effect=_failing_generate),
    ):
        response = client.post("/v1/audio/speech", json=_speech(response_format="pcm"))
    assert response.status_code == 200
    assert len(response.content) == SAMPLES * 2
    assert b"/Users/" not in response.content
    assert not interactive_tts_lock.locked()


@pytest.mark.asyncio
async def test_speech_waits_for_interactive_lock() -> None:
    from httpx import ASGITransport, AsyncClient

    transport = ASGITransport(app=create_public_app(API_KEY))
    with (
        patch.object(EngineManager, "ensure_loaded", new=AsyncMock()),
        patch.object(EngineManager, "generate", side_effect=_generate) as generate,
    ):
        await interactive_tts_lock.acquire()
        async with AsyncClient(transport=transport, base_url="http://t") as http:
            request = asyncio.create_task(
                http.post("/v1/audio/speech", json=_speech(), headers=AUTH)
            )
            await asyncio.sleep(0.05)
            assert not request.done()
            generate.assert_not_called()
            interactive_tts_lock.release()
            response = await asyncio.wait_for(request, timeout=5)
    assert response.status_code == 200
    assert not interactive_tts_lock.locked()
