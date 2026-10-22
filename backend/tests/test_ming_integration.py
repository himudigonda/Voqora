from __future__ import annotations

import os
from pathlib import Path

import numpy as np
import pytest
import pytest_asyncio

from app.core.config import settings
from app.services.delivery import Delivery
from app.services.ming_engine import MingEngine, runaway_limit_seconds
from app.services.ming_installer import MingInstaller

RUNTIME = os.environ.get("VOQORA_MING_RUNTIME")
CODE = os.environ.get("VOQORA_MING_CODE")
MODEL = os.environ.get("VOQORA_MING_MODEL")

pytestmark = pytest.mark.skipif(
    not (RUNTIME and CODE and MODEL),
    reason="set VOQORA_MING_RUNTIME, VOQORA_MING_CODE and VOQORA_MING_MODEL",
)

SENTENCE = "The quick brown fox jumps over the lazy dog."
MIN_SECONDS = 1.5
MAX_SECONDS = 12.0
MIN_RMS = 0.005


@pytest_asyncio.fixture
async def real_worker(monkeypatch):
    monkeypatch.setattr(MingInstaller, "is_installed", classmethod(lambda cls: True))
    monkeypatch.setattr(
        MingEngine,
        "command",
        classmethod(
            lambda cls: [
                RUNTIME,
                "-I",
                str(Path(settings.RESOURCE_PATH) / "app/engines/ming/worker.py"),
                "--code",
                CODE,
                "--model",
                MODEL,
            ]
        ),
    )
    await MingEngine.shutdown()
    yield
    await MingEngine.shutdown()


async def speak(voice: str, delivery: Delivery | None = None) -> np.ndarray:
    chunks = [
        chunk
        async for chunk in MingEngine.generate(SENTENCE, voice, 1.0, delivery=delivery)
    ]
    assert len(chunks) == 1
    return chunks[0]


def assert_plausible_speech(audio: np.ndarray) -> None:
    seconds = len(audio) / settings.AUDIO_SAMPLE_RATE
    assert audio.dtype == np.float32
    assert np.isfinite(audio).all()
    assert MIN_SECONDS <= seconds <= MAX_SECONDS
    assert float(np.sqrt(np.mean(audio**2))) > MIN_RMS
    assert float(np.max(np.abs(audio))) > 0.05


@pytest.mark.asyncio
async def test_real_worker_speaks_a_built_in_voice_and_an_emotional_delivery(
    real_worker,
):
    await MingEngine.ensure_loaded()
    plain = await speak("ming:US_James")
    happy = await speak("ming:US_James", Delivery(emotion="happy"))
    assert_plausible_speech(plain)
    assert_plausible_speech(happy)
    assert not np.array_equal(plain, happy)


@pytest.mark.asyncio
async def test_real_worker_speaks_a_combined_delivery_at_a_plausible_length(
    real_worker,
):
    delivery = Delivery(emotion="happy", pace="slow", style="like a cheerful host")
    audio = await speak("ming:US_James", delivery)
    assert_plausible_speech(audio)
    limit = runaway_limit_seconds(SENTENCE, "en")
    assert len(audio) / settings.AUDIO_SAMPLE_RATE <= limit + 1.0
