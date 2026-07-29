"""Tests for D7: two independent cover-render call sites — api/audiobook.py's
upload-time background task (_render_cover_task) and
audiobook_service.py's _phase_extract — both funnel into the same
PDFExtractor.render_cover / TextExtractor.render_cover, both gated by the
same `if os.path.exists(out): return` idempotency check. If /start fires
before the upload-time render finishes, both calls can pass that check
before either has written anything (the TOCTOU window), then race to write
cover.jpg.

Before the fix, _atomic_write_bytes always wrote to a FIXED `path + ".tmp"`
name. Two true concurrent writers sharing that one tmp path can interleave
writes into the same inode, or race each other's os.replace() (whichever
one's os.replace() runs second finds the tmp file already renamed away by
the first, raising FileNotFoundError) — either a corrupted cover.jpg or an
unhandled crash. The fix gives every call its own uuid-suffixed tmp path, so
concurrent writers never share a file before either's os.replace() (itself
atomic) — the loser's replace just overwrites the winner's with an equally
complete, valid image.

Real thread scheduling is too unreliable to trust as a one-shot regression
test, so this forces genuine overlap with a barrier and repeats across many
iterations — post-fix this is 100% reliably clean; pre-fix it reliably
corrupts or crashes within a handful of iterations (empirically confirmed
against the pre-fix code during development of this test).
"""

from __future__ import annotations

import os
import shutil
import tempfile
import threading

import pytest
from PIL import Image

from app.services.audiobook_store import AudiobookStore
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
    """Fires TextExtractor.render_cover twice concurrently against the same
    book (simulating the upload-time task racing _phase_extract's own
    render), forcing genuine overlap with a barrier, repeated across many
    iterations. Every iteration's result must be a complete, decodable JPEG
    at the expected size — never a corrupted mix, never an unhandled
    exception from either caller."""
    bid = _make_txt_book()
    cover_path = AudiobookStore.cover_path(bid)

    for i in range(_ITERATIONS):
        if os.path.exists(cover_path):
            os.remove(cover_path)
        # Also clear any leftover tmp files from a previous (possibly
        # crashed) iteration so exists-checks stay meaningful.
        cover_dir = os.path.dirname(cover_path)
        for fname in os.listdir(cover_dir):
            if fname.startswith("cover.jpg") and fname != "cover.jpg":
                os.remove(os.path.join(cover_dir, fname))

        barrier = threading.Barrier(2)
        errors: list[BaseException] = []

        def render() -> None:
            try:
                barrier.wait(timeout=5.0)
                TextExtractor.render_cover(bid)
            except (
                BaseException
            ) as e:  # noqa: BLE001 - captured for main-thread assertion
                errors.append(e)

        t1 = threading.Thread(target=render)
        t2 = threading.Thread(target=render)
        t1.start()
        t2.start()
        t1.join(timeout=5.0)
        t2.join(timeout=5.0)

        assert not errors, f"iteration {i}: concurrent render raised: {errors!r}"
        assert os.path.exists(cover_path), f"iteration {i}: cover.jpg missing"
        with Image.open(cover_path) as img:
            img.load()  # force full decode, not just header parse
            assert img.size == (600, 840), f"iteration {i}: corrupted/wrong-size image"

        # No stray tmp files must survive a completed render (both writers'
        # own uuid-suffixed tmp paths must have been replaced away).
        leftover_tmp = [
            f
            for f in os.listdir(cover_dir)
            if f.startswith("cover.jpg") and f != "cover.jpg"
        ]
        assert not leftover_tmp, f"iteration {i}: leftover tmp file(s): {leftover_tmp}"


def test_atomic_write_bytes_uses_a_unique_tmp_path_per_call():
    """Direct mechanism check: two back-to-back calls must never compute the
    same tmp path. This is what makes the race in the test above impossible
    post-fix — two writers can never share an inode via the same pathname,
    so the only remaining non-determinism is which complete, valid image
    "wins" the final os.replace(), never a corrupted mix of both."""
    tmp_dir = tempfile.mkdtemp(prefix="ss_atomic_write_test_")
    try:
        out = os.path.join(tmp_dir, "cover.jpg")
        seen_tmp_paths: set[str] = set()
        real_replace = os.replace

        def spy_replace(src, dst):
            seen_tmp_paths.add(src)
            real_replace(src, dst)

        import app.services.text_extractor as _te_mod

        original = _te_mod.os.replace
        _te_mod.os.replace = spy_replace
        try:
            TextExtractor._atomic_write_bytes(out, b"first-image-bytes")
            TextExtractor._atomic_write_bytes(out, b"second-image-bytes-longer")
        finally:
            _te_mod.os.replace = original

        assert len(seen_tmp_paths) == 2, (
            "each _atomic_write_bytes call must use its own unique tmp path — "
            f"got {seen_tmp_paths}"
        )
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)
