"""Benchmarks for API endpoints.

HARD-040: previous version patched `TTSEngine.generate` but the endpoint
dispatches via `EngineManager.generate`. Patch was a no-op. Now patches
the correct symbol and uses an async generator (matching the production
contract).
"""

from unittest.mock import patch

import numpy as np
import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.services.tts import TTSEngine

client = TestClient(app)


async def _mock_async_generate(*args, **kwargs):
    """Async generator yielding three short PCM chunks — what production
    EngineManager.generate is shaped like."""
    for _ in range(3):
        yield np.random.uniform(-0.5, 0.5, 12000).astype(np.float32)


@pytest.mark.benchmark
@patch.object(TTSEngine, "_model", object())
def test_bench_health_check():
    """Benchmark health check endpoint."""
    response = client.get("/health")
    assert response.status_code == 200


@pytest.mark.benchmark
@patch.object(TTSEngine, "_model", object())
@patch("app.services.engine_manager.EngineManager.ensure_loaded")
@patch(
    "app.services.engine_manager.EngineManager.generate",
    side_effect=_mock_async_generate,
)
def test_bench_speak_endpoint(_mock_generate, _mock_load):
    """Benchmark the main /speak endpoint with streaming."""
    payload = {
        "text": "This is a performance test for the speak endpoint.",
        "voice": "af_bella",
        "speed": 1.0,
        "volume": 1.0,
    }

    response = client.post("/speak", json=payload)
    assert response.status_code == 200
    content = b"".join(response.iter_bytes())
    assert len(content) > 0


@pytest.mark.benchmark
@patch.object(TTSEngine, "_model", object())
@patch("app.services.engine_manager.EngineManager.ensure_loaded")
@patch(
    "app.services.engine_manager.EngineManager.generate",
    side_effect=_mock_async_generate,
)
def test_bench_speak_long_text(_mock_generate, _mock_load):
    """Benchmark /speak with longer text input."""
    payload = {
        "text": " ".join(
            [
                "This is a longer text to benchmark.",
                "It contains multiple sentences.",
                "We want to measure performance with realistic input.",
                "The API should handle this efficiently.",
            ]
        ),
        "voice": "af_bella",
        "speed": 1.0,
        "volume": 1.0,
    }

    response = client.post("/speak", json=payload)
    assert response.status_code == 200
    content = b"".join(response.iter_bytes())
    assert len(content) > 0
