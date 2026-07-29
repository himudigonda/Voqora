"""Benchmarks for audio processing operations.

Pre-HARD-040 this file called `list(...)` on an async generator and
referenced `AudioService.process_samples` / `generate_silence` which
were removed in HARD-032. Rewritten to exercise the actual public surface
(`get_silence`, `stream_samples_to_wav`).
"""

import asyncio

import numpy as np
import pytest

from app.services.audio import AudioService


@pytest.mark.benchmark
def test_bench_get_silence():
    """Cached silence retrieval — first call populates, subsequent hit."""
    durations = [0.35, 0.2, 0.12, 0.1, 0.5]
    for d in durations:
        silence = AudioService.get_silence(d)
        assert silence.dtype == np.float32
        assert (silence == 0).all()


async def _collect(stream):
    out: list[bytes] = []
    async for chunk in stream:
        out.append(chunk)
    return out


@pytest.mark.benchmark
def test_bench_stream_samples_to_wav():
    """Benchmark streaming audio chunks to WAV format end-to-end."""

    async def sample_async_gen():
        for _ in range(10):
            yield np.random.uniform(-0.5, 0.5, 2400).astype(np.float32)

    chunks = asyncio.run(
        _collect(AudioService.stream_samples_to_wav(sample_async_gen(), 1.0))
    )

    # First chunk = pre-computed WAV header, then 10 PCM data chunks.
    assert chunks[0][:4] == b"RIFF"
    assert len(chunks) == 11
