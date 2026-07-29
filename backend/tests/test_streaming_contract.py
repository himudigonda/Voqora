"""Wire-format contract for /speak and /health.

Locks the JSON shape and the streaming PCM/WAV envelope so a frontend
change can't silently regress them. Inference itself is mocked — the
contract under test is the HTTP layer.
"""

from __future__ import annotations

import struct
from unittest.mock import patch

import numpy as np
from fastapi.testclient import TestClient

from app.main import app
from app.services.audio import AudioService
from app.services.engine_manager import EngineManager


async def _mock_generate(*_args, **_kwargs):
    yield np.linspace(-0.1, 0.1, 2400, dtype=np.float32)
    yield AudioService.get_silence(0.1)
    yield np.linspace(0.05, -0.05, 2400, dtype=np.float32)


def _client() -> TestClient:
    return TestClient(app)


# ---------- /health contract ----------


@patch.object(EngineManager, "ensure_loaded")
def test_health_response_shape(mock_ensure) -> None:
    body = _client().get("/health").json()
    assert set(body.keys()) >= {"status", "loaded"}
    assert isinstance(body["loaded"], bool)
    assert body["status"] in {"ready", "cold", "loading"}


# ---------- /speak streaming contract ----------


@patch.object(EngineManager, "ensure_loaded")
@patch.object(EngineManager, "generate", side_effect=_mock_generate)
def test_speak_returns_wav_riff_header(_mock_gen, _mock_load) -> None:
    payload = {
        "text": "Contract test.",
        "voice": "af_bella",
        "speed": 1.0,
        "volume": 1.0,
    }
    response = _client().post("/speak", json=payload)
    assert response.status_code == 200
    content = response.content
    assert content.startswith(b"RIFF"), "first chunk must be a valid RIFF header"
    assert content[8:12] == b"WAVE", "must declare WAVE format"


@patch.object(EngineManager, "ensure_loaded")
@patch.object(EngineManager, "generate", side_effect=_mock_generate)
def test_speak_declares_24khz_mono_16bit(_mock_gen, _mock_load) -> None:
    response = _client().post(
        "/speak",
        json={"text": "Foo.", "voice": "af_bella", "speed": 1.0, "volume": 1.0},
    )
    content = response.content
    # fmt chunk: channels @ offset 22, sample rate @ offset 24, bits-per-sample @ 34
    channels = struct.unpack_from("<H", content, 22)[0]
    sample_rate = struct.unpack_from("<I", content, 24)[0]
    bits = struct.unpack_from("<H", content, 34)[0]
    assert channels == 1
    assert sample_rate == 24000
    assert bits == 16


@patch.object(EngineManager, "ensure_loaded")
@patch.object(EngineManager, "generate", side_effect=_mock_generate)
def test_speak_emits_pcm_payload(_mock_gen, _mock_load) -> None:
    response = _client().post(
        "/speak",
        json={"text": "Foo.", "voice": "af_bella", "speed": 1.0, "volume": 1.0},
    )
    content = response.content
    pcm = np.frombuffer(content[44:], dtype=np.int16)
    assert pcm.size > 0
    assert pcm.min() >= -32768
    assert pcm.max() <= 32767


@patch.object(EngineManager, "ensure_loaded")
def test_speak_rejects_malformed_payload_without_leaking_internals(
    _mock_load,
) -> None:
    response = _client().post(
        "/speak",
        json={"voice": "af_bella", "speed": 1.0, "volume": 1.0},  # missing 'text'
    )
    assert response.status_code in (400, 422)
    body = response.text.lower()
    assert "traceback" not in body
    assert "/users/" not in body, "must not leak filesystem paths"


# ---------- mid-stream failure (HARD-043) ----------


async def _faulty_generate(*_args, **_kwargs):
    """Yield two valid chunks, then raise — simulates an ONNX failure halfway
    through a long response."""
    yield np.linspace(-0.1, 0.1, 2400, dtype=np.float32)
    yield np.linspace(0.05, -0.05, 2400, dtype=np.float32)
    raise RuntimeError("simulated mid-stream failure: model session crashed")


@patch.object(EngineManager, "ensure_loaded")
@patch.object(EngineManager, "generate", side_effect=_faulty_generate)
def test_speak_truncates_cleanly_on_midstream_failure(_mock_gen, _mock_load) -> None:
    """When inference raises after the StreamingResponse has begun, the
    response body must:
      - still be a parseable WAV (RIFF header + PCM emitted so far)
      - NOT contain a stack trace or any /Users/... filesystem path
      - NOT contain the raw exception class name

    Without the _guarded_wav_stream wrapper, the exception would bubble
    through to ASGI which appends a 500 error body to a 200 response.
    """
    response = _client().post(
        "/speak",
        json={
            "text": "Crash mid-stream.",
            "voice": "af_bella",
            "speed": 1.0,
            "volume": 1.0,
        },
    )
    # Already sent 200 + WAV header before the raise — clients see a
    # truncated audio stream rather than a status-code change.
    assert response.status_code == 200
    body = response.content
    assert body.startswith(b"RIFF")
    assert b"WAVE" in body[:12]
    # Must NOT leak exception internals into the response body.
    assert b"Traceback" not in body
    assert b"RuntimeError" not in body
    assert b"/Users/" not in body
    assert b"simulated mid-stream failure" not in body
    # Two chunks worth of PCM made it through before the raise.
    pcm = np.frombuffer(body[44:], dtype=np.int16)
    assert pcm.size > 0
