from unittest.mock import patch

import numpy as np
from fastapi.testclient import TestClient

from app.main import app
from app.services.audio import AudioService
from app.services.engine_manager import EngineManager

client = TestClient(app)


# Helper to mock the async generator
async def mock_engine_generate(*args, **kwargs):
    # Yield small chunks to simulate stream
    yield np.zeros(12000, dtype=np.float32)
    yield AudioService.get_silence(0.2)
    yield np.zeros(12000, dtype=np.float32)


@patch.object(EngineManager, "ensure_loaded")
def test_health_check(mock_ensure):
    response = client.get("/health")
    assert response.status_code == 200
    body = response.json()
    assert "status" in body
    assert "loaded" in body


@patch.object(EngineManager, "ensure_loaded")
@patch.object(EngineManager, "generate", side_effect=mock_engine_generate)
def test_speak_endpoint_streaming(mock_generate, mock_ensure):
    payload = {
        "text": "Test streaming",
        "voice": "af_bella",
        "speed": 1.0,
        "volume": 1.0,
    }

    # TestClient.post will invoke the endpoint
    response = client.post("/speak", json=payload)

    assert response.status_code == 200
    assert response.headers["content-type"] == "audio/wav"

    # Consume the stream
    content = b"".join(response.iter_bytes())

    # Validate WAV Header (RIFF....WAVE)
    assert content[:4] == b"RIFF"
    assert content[8:12] == b"WAVE"
    # Ensure we got data
    assert len(content) > 100


@patch.object(EngineManager, "ensure_loaded")
def test_engine_get_endpoint(mock_ensure):
    """Test GET /engine returns current engine state."""
    response = client.get("/engine")
    assert response.status_code == 200
    body = response.json()
    assert "engine" in body
    assert "model" in body
    assert "voices" in body
    assert isinstance(body["voices"], list)


def test_engine_post_endpoint():
    """Test POST /engine with kokoro returns current engine state."""
    payload = {"engine": "kokoro"}
    response = client.post("/engine", json=payload)

    assert response.status_code == 200
    body = response.json()
    assert body["engine"] == "kokoro"
    assert "voices" in body


def test_engine_post_unknown():
    """Test POST /engine with unknown engine returns 400."""
    response = client.post("/engine", json={"engine": "kitten"})
    assert response.status_code == 400
