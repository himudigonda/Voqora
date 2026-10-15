from __future__ import annotations

import os
import shutil
import tempfile
import threading

import pytest
from PIL import Image

from app.services import pdf_extractor as _pdf_module
from app.services import text_extractor as _text_module
from app.services.audiobook_store import AudiobookStore
from app.services.pdf_extractor import PDFExtractor
from app.services.text_extractor import TextExtractor

_ITERATIONS = 25


@pytest.fixture(autouse=True)
def isolated_audiobooks_dir(monkeypatch):
    tmp = tempfile.mkdtemp(prefix="ss_audiobooks_test_")

    class _PatchedSettings:
        @property
        def AUDIOBOOKS_DIR(self) -> str:
            return tmp

    monkeypatch.setattr("app.services.audiobook_store.settings", _PatchedSettings())
    AudiobookStore._reset_for_tests()
    yield tmp
    AudiobookStore._reset_for_tests()
    shutil.rmtree(tmp, ignore_errors=True)


def _make_txt_book() -> str:
    bid = AudiobookStore.create_book("Race.txt")
    meta = AudiobookStore.initial_meta(
        bid, "Race.txt", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["file_ext"] = "txt"
    AudiobookStore.write_meta(bid, meta)
    return bid


def test_concurrent_cover_renders_never_corrupt_cover_jpg():
    bid = _make_txt_book()
    cover_path = AudiobookStore.cover_path(bid)
    cover_dir = os.path.dirname(cover_path)

    for i in range(_ITERATIONS):
        if os.path.exists(cover_path):
            os.remove(cover_path)
        for name in os.listdir(cover_dir):
            if name.startswith("cover.jpg") and name != "cover.jpg":
                os.remove(os.path.join(cover_dir, name))

        barrier = threading.Barrier(2)
        errors: list[BaseException] = []

        def render() -> None:
            try:
                barrier.wait(timeout=5.0)
                TextExtractor.render_cover(bid)
            except BaseException as error:
                errors.append(error)

        threads = [threading.Thread(target=render) for _ in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=5.0)

        assert not errors, f"iteration {i}: {errors!r}"
        with Image.open(cover_path) as img:
            img.load()
            assert img.size == (600, 840)
        leftovers = [
            name
            for name in os.listdir(cover_dir)
            if name.startswith("cover.jpg") and name != "cover.jpg"
        ]
        assert not leftovers, f"iteration {i}: {leftovers}"


@pytest.mark.parametrize(
    ("module", "extractor"),
    [(_text_module, TextExtractor), (_pdf_module, PDFExtractor)],
)
def test_atomic_writes_use_a_unique_tmp_path_per_call(
    monkeypatch, tmp_path, module, extractor
):
    seen: list[str] = []
    real_replace = os.replace

    def spy_replace(src, dst):
        seen.append(src)
        real_replace(src, dst)

    monkeypatch.setattr(module.os, "replace", spy_replace)
    out = str(tmp_path / "nested" / "file.bin")

    extractor._atomic_write_bytes(out, b"first")
    extractor._atomic_write_bytes(out, b"second-longer")
    extractor._atomic_write(out + ".txt", "first")
    extractor._atomic_write(out + ".txt", "second")

    assert len(seen) == 4
    assert len(set(seen)) == 4
    assert all(path.endswith(".tmp") for path in seen)
    assert not [
        name for name in os.listdir(tmp_path / "nested") if name.endswith(".tmp")
    ]
    with open(out, "rb") as f:
        assert f.read() == b"second-longer"


def test_service_atomic_helpers_use_a_unique_tmp_path_per_call(monkeypatch, tmp_path):
    import app.services.audiobook_service as _service_module
    from app.services.audiobook_service import AudiobookService

    seen: list[str] = []
    real_replace = os.replace

    def spy_replace(src, dst):
        seen.append(src)
        real_replace(src, dst)

    monkeypatch.setattr(_service_module.os, "replace", spy_replace)
    json_path = str(tmp_path / "out" / "timing.json")
    wav_path = str(tmp_path / "out" / "silence.wav")

    AudiobookService._write_json_atomic(json_path, {"a": 1})
    AudiobookService._write_json_atomic(json_path, {"a": 2})
    AudiobookService._write_silence_wav(wav_path, 0.1)
    AudiobookService._write_silence_wav(wav_path, 0.1)

    assert len(seen) == 4
    assert len(set(seen)) == 4
    assert not [name for name in os.listdir(tmp_path / "out") if name.endswith(".tmp")]
