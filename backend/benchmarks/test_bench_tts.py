"""Benchmarks for TTS engine operations.

Note (HARD-040): the previous version called `list(TTSEngine.generate(...))`
on an async generator, which raises TypeError — the benchmarks had never
executed. Replaced with `asyncio.run(_collect(...))` and aligned the mock
target to the public `EngineManager.generate` path (what production uses).
"""

import asyncio
import concurrent.futures
from unittest.mock import patch

import numpy as np
import pytest

from app.services.tts import TTSEngine


class _MockKokoro:
    """Mock Kokoro model: returns 1s of mid-amplitude noise at 24 kHz."""

    def create(self, text, voice, speed, lang):
        return np.random.uniform(-0.5, 0.5, 24000).astype(np.float32), None


def _patched_tts():
    """Context manager that swaps TTSEngine internals so generate() can run
    without the real ONNX session being loaded."""
    return patch.multiple(
        TTSEngine,
        _model=_MockKokoro(),
        _executor=concurrent.futures.ThreadPoolExecutor(max_workers=1),
    )


async def _collect(text: str, voice: str, speed: float) -> list[np.ndarray]:
    chunks: list[np.ndarray] = []
    async for chunk in TTSEngine.generate(text, voice, speed):
        chunks.append(chunk)
    return chunks


@pytest.mark.benchmark
def test_bench_tts_sentence_splitting():
    """Benchmark text preprocessing + sequential streaming inference."""
    with _patched_tts():
        text = "Hello world. This is a test! How are you? I'm fine, thanks. What about you?"
        chunks = asyncio.run(_collect(text, "af_bella", 1.0))
        assert len(chunks) > 0


@pytest.mark.benchmark
def test_bench_tts_long_text():
    """Benchmark processing longer text passages."""
    with _patched_tts():
        text = " ".join(
            [
                "This is a benchmark for testing text-to-speech performance.",
                "We want to measure how efficiently the engine processes longer passages.",
                "The system should handle multiple sentences gracefully.",
                "Performance matters for real-time speech synthesis.",
                "Let's make sure the benchmarks capture realistic usage patterns.",
            ]
        )
        chunks = asyncio.run(_collect(text, "af_bella", 1.0))
        assert len(chunks) > 0


@pytest.mark.benchmark
def test_bench_tts_speed_variations():
    """Benchmark TTS at speed=0.8/1.0/1.2."""
    with _patched_tts():
        text = "Testing different speech speeds for performance."
        for speed in (0.8, 1.0, 1.2):
            chunks = asyncio.run(_collect(text, "af_bella", speed))
            assert len(chunks) > 0
