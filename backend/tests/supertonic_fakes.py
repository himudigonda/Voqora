from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from app.services.supertonic_catalog import MODEL_REVISION, VOICE_IDS, style_name
from app.services.supertonic_installer import INSTALL_MARKER


def write_model_files(directory: Path) -> None:
    (directory / "onnx").mkdir(parents=True, exist_ok=True)
    for name in (
        "duration_predictor.onnx",
        "text_encoder.onnx",
        "vector_estimator.onnx",
        "vocoder.onnx",
        "tts.json",
        "unicode_indexer.json",
    ):
        (directory / "onnx" / name).write_bytes(b"fake")
    (directory / "voice_styles").mkdir(parents=True, exist_ok=True)
    for voice_id in VOICE_IDS:
        (directory / "voice_styles" / f"{style_name(voice_id)}.json").write_text("{}")


def mark_installed(directory: Path) -> None:
    write_model_files(directory)
    (directory / INSTALL_MARKER).write_text(json.dumps({"revision": MODEL_REVISION}))


class FakeProcessor:
    def __init__(self, unsupported: str = "") -> None:
        self.unsupported = unsupported

    def validate_text(self, text: str) -> tuple[bool, list[str]]:
        found = [char for char in set(text) if char in self.unsupported]
        return not found, found


class FakeInner:
    def __init__(self, unsupported: str = "") -> None:
        self.text_processor = FakeProcessor(unsupported)


class FakeSupertonic:
    sample_rate = 44100

    def __init__(self, unsupported: str = "", fail_on: str | None = None) -> None:
        self.model = FakeInner(unsupported)
        self.fail_on = fail_on
        self.calls: list[dict] = []

    def get_voice_style(self, name: str) -> str:
        return f"style-{name}"

    def synthesize(self, text, voice_style, speed=1.0, lang=None, **kwargs):
        self.calls.append(
            {"text": text, "style": voice_style, "speed": speed, "lang": lang}
        )
        if self.fail_on and self.fail_on in text:
            raise RuntimeError("boom")
        samples = np.full((1, self.sample_rate // 10), 0.25, dtype=np.float32)
        return samples, np.array([0.1])
