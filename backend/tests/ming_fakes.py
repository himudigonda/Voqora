from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

from app.services.ming_catalog import CODE_REVISION, MODEL_REVISION
from app.services.ming_engine import MingEngine
from app.services.ming_installer import (
    CODE_REQUIRED_FILES,
    INSTALL_MARKER,
    MODEL_REQUIRED_FILES,
    MingInstaller,
)

FAKE_WORKER = Path(__file__).with_name("ming_fake_worker.py")


def write_install_files(root: Path) -> None:
    python = MingInstaller.runtime_python(root)
    python.parent.mkdir(parents=True, exist_ok=True)
    python.write_bytes(b"fake")
    code = MingInstaller.code_dir(root)
    code.mkdir(parents=True, exist_ok=True)
    for name in CODE_REQUIRED_FILES:
        (code / name).write_text("")
    model = MingInstaller.model_dir(root)
    model.mkdir(parents=True, exist_ok=True)
    for name in MODEL_REQUIRED_FILES:
        (model / name).write_bytes(b"fake")


def mark_installed(root: Path | None = None) -> None:
    root = root or MingInstaller.install_dir()
    write_install_files(root)
    (root / INSTALL_MARKER).write_text(
        json.dumps({"code_revision": CODE_REVISION, "model_revision": MODEL_REVISION})
    )


def use_fake_worker(monkeypatch, tmp_path: Path) -> Path:
    log_path = tmp_path / "worker-requests.jsonl"
    monkeypatch.setattr(
        MingEngine,
        "command",
        classmethod(lambda cls: [sys.executable, str(FAKE_WORKER)]),
    )
    monkeypatch.setenv("FAKE_MING_LOG", str(log_path))
    return log_path


def worker_requests(log_path: Path) -> list[dict]:
    if not log_path.exists():
        return []
    return [json.loads(line) for line in log_path.read_text().splitlines()]


def tone_samples(seconds: float, rate: int = 44100) -> np.ndarray:
    time = np.arange(int(seconds * rate)) / rate
    return (0.3 * np.sin(2 * np.pi * 220 * time)).astype(np.float32)


def wav_bytes(seconds: float, rate: int = 44100, channels: int = 1) -> bytes:
    import io

    samples = tone_samples(seconds, rate)
    if channels > 1:
        samples = np.stack([samples] * channels, axis=1)
    buffer = io.BytesIO()
    sf.write(buffer, samples, rate, format="WAV", subtype="PCM_16")
    return buffer.getvalue()
