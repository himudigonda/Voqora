"""Tests for D6 (paid OCR must never be spent on a genuinely-blank PDF page)
and D8 (removal of the dead, unreachable "[blank...]" branch in _phase_tts).

D6: _phase_clean routed ANY PDF page under _OCR_TEXT_THRESHOLD (50) chars —
including genuinely 0-char blank pages — through a paid Gemini vision OCR
call. GeminiCleaner.clean_page already short-circuits truly-empty text for
free (no network call: `if not raw_text.strip(): return "-"`), but PDF pages
never reached that path because the under-threshold check diverted them to
OCR first. The fix short-circuits truly-empty PDF pages to "-" before the
OCR branch — BUT only when the document itself isn't classified as a scan
(`meta["is_image_only"]`, persisted at upload time). A scanned page also
extracts to "" (no text LAYER at all, not "no content"), so silencing every
0-char page unconditionally would have silently dropped real, recoverable
narration for scanned books — worse than the bug it fixed. Every
under-threshold page in an image-only document (0 chars included) still
routes to OCR to give it a chance to recover real content.

D8: _phase_tts had a second, unreachable branch treating any cleaned text
starting with "[blank" and ending with "]" as a silence marker. Neither
Gemini prompt (clean or OCR) ever emits that string — only the literal "-"
marker — so the branch could only ever fire on a page whose REAL narration
text happened to look like that pattern, silently silencing real content
that should have been narrated.
"""

from __future__ import annotations

import os
import shutil
import tempfile
from unittest.mock import AsyncMock, patch

import numpy as np
import pytest

from app.services.audiobook_service import (
    SAMPLE_RATE,
    WAV_HEADER_SIZE,
    AudiobookService,
)
from app.services.audiobook_store import AudiobookStore


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


def _make_pdf_book(page_count: int = 1, is_image_only: bool = False) -> str:
    bid = AudiobookStore.create_book("Scan.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Scan.pdf", page_count, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["file_ext"] = "pdf"
    meta["is_image_only"] = is_image_only
    AudiobookStore.write_meta(bid, meta)
    return bid


# ===========================================================================
# D6: blank PDF pages must never reach paid OCR
# ===========================================================================


@pytest.mark.asyncio
async def test_truly_blank_pdf_page_skips_ocr_and_clean_page(monkeypatch):
    """A genuinely 0-char PDF page must short-circuit to '-' without calling
    EITHER GeminiCleaner.ocr_page (paid vision OCR) or clean_page (a network
    call clean_page itself would have short-circuited for free anyway, but
    PDFs must never reach it via the OCR branch in the first place)."""
    bid = _make_pdf_book(1)
    raw = AudiobookStore.page_raw_path(bid, 1)
    os.makedirs(os.path.dirname(raw), exist_ok=True)
    with open(raw, "w", encoding="utf-8") as f:
        f.write("")  # genuinely empty — not even whitespace

    from app.services import gemini_cleaner as _gc
    from app.services import pdf_extractor as _pe

    # No source.pdf exists on disk for this test book — render_page_image
    # (called BEFORE ocr_page, to build the vision payload) would itself
    # raise on a missing file, which clean_one's generic except swallows,
    # producing a false-positive "ocr_page not called" even on unfixed code.
    # Mock it explicitly so the ONLY thing that can prevent OCR is the D6
    # short-circuit under test, not an incidental missing-file error.
    render_image_mock = AsyncMock(
        side_effect=AssertionError("render_page_image must not be called")
    )
    monkeypatch.setattr(
        _pe.PDFExtractor,
        "render_page_image",
        classmethod(lambda cls, p, n, **kw: render_image_mock()),
    )
    ocr_mock = AsyncMock(side_effect=AssertionError("OCR must not be called"))
    clean_mock = AsyncMock(side_effect=AssertionError("clean_page must not be called"))
    monkeypatch.setattr(_gc.GeminiCleaner, "ocr_page", ocr_mock)
    monkeypatch.setattr(_gc.GeminiCleaner, "clean_page", clean_mock)

    AudiobookService.initialize()
    await AudiobookService._phase_clean(bid, api_key="test-key")

    render_image_mock.assert_not_called()
    ocr_mock.assert_not_called()
    clean_mock.assert_not_called()
    clean_path = AudiobookStore.page_clean_path(bid, 1)
    assert os.path.exists(clean_path)
    with open(clean_path, encoding="utf-8") as f:
        assert f.read() == "-"


@pytest.mark.asyncio
async def test_whitespace_only_pdf_page_skips_ocr(monkeypatch):
    """Whitespace-only extracted text (e.g. "   \\n\\n  ") is functionally
    blank — stripped, it's empty — so it must be treated identically to a
    literal 0-char page, not routed to OCR."""
    bid = _make_pdf_book(1)
    raw = AudiobookStore.page_raw_path(bid, 1)
    os.makedirs(os.path.dirname(raw), exist_ok=True)
    with open(raw, "w", encoding="utf-8") as f:
        f.write("   \n\n   \t  ")

    from app.services import gemini_cleaner as _gc
    from app.services import pdf_extractor as _pe

    # See test_truly_blank_pdf_page_skips_ocr_and_clean_page: without this
    # mock, a missing source.pdf makes render_page_image raise on its own,
    # which would produce a false-positive "ocr_page not called" even on
    # unfixed code — mock it so OCR-avoidance is proven directly.
    render_image_mock = AsyncMock(
        side_effect=AssertionError("render_page_image must not be called")
    )
    monkeypatch.setattr(
        _pe.PDFExtractor,
        "render_page_image",
        classmethod(lambda cls, p, n, **kw: render_image_mock()),
    )
    ocr_mock = AsyncMock(side_effect=AssertionError("OCR must not be called"))
    monkeypatch.setattr(_gc.GeminiCleaner, "ocr_page", ocr_mock)

    AudiobookService.initialize()
    await AudiobookService._phase_clean(bid, api_key="test-key")

    render_image_mock.assert_not_called()
    ocr_mock.assert_not_called()
    clean_path = AudiobookStore.page_clean_path(bid, 1)
    with open(clean_path, encoding="utf-8") as f:
        assert f.read() == "-"


@pytest.mark.asyncio
async def test_sparse_nonempty_pdf_page_still_routes_to_ocr(monkeypatch):
    """The D6 fix must not overcorrect: a page with SOME text under the
    threshold (a real image page with a little bleed-through/watermark
    text) must still go through paid OCR — only genuinely-empty pages are
    exempted."""
    bid = _make_pdf_book(1)
    raw = AudiobookStore.page_raw_path(bid, 1)
    os.makedirs(os.path.dirname(raw), exist_ok=True)
    with open(raw, "w", encoding="utf-8") as f:
        f.write("1")  # a single stray character — nonzero, still << threshold

    from app.services import gemini_cleaner as _gc
    from app.services import pdf_extractor as _pe

    monkeypatch.setattr(
        _pe.PDFExtractor,
        "render_page_image",
        classmethod(lambda cls, p, n, **kw: b"imgbytes"),
    )
    ocr_mock = AsyncMock(return_value="OCR result.")
    monkeypatch.setattr(_gc.GeminiCleaner, "ocr_page", ocr_mock)

    AudiobookService.initialize()
    await AudiobookService._phase_clean(bid, api_key="test-key")

    ocr_mock.assert_called_once()
    clean_path = AudiobookStore.page_clean_path(bid, 1)
    with open(clean_path, encoding="utf-8") as f:
        assert f.read() == "OCR result."


@pytest.mark.asyncio
async def test_image_only_document_blank_page_still_routes_to_ocr(monkeypatch):
    """The critical D6 guard: a page extracting to 0 chars in a document
    classified as image-only (a real scan) must NOT be silenced — it has no
    text LAYER, not necessarily no content. A real scanned page showing
    "Chapter One: The Beginning" still extracts to "" via pdfplumber (no
    embedded text), and must still get a real OCR attempt to recover it,
    exactly like any other under-threshold page in that same document.
    Silencing it instead would ship a book with real pages gone silent and
    no error, despite the user having been quoted an OCR cost for exactly
    this content at upload time."""
    bid = _make_pdf_book(1, is_image_only=True)
    raw = AudiobookStore.page_raw_path(bid, 1)
    os.makedirs(os.path.dirname(raw), exist_ok=True)
    with open(raw, "w", encoding="utf-8") as f:
        f.write("")  # 0 extracted chars — the scan's text layer is empty

    from app.services import gemini_cleaner as _gc
    from app.services import pdf_extractor as _pe

    monkeypatch.setattr(
        _pe.PDFExtractor,
        "render_page_image",
        classmethod(lambda cls, p, n, **kw: b"imgbytes"),
    )
    ocr_mock = AsyncMock(return_value="Chapter One: The Beginning")
    monkeypatch.setattr(_gc.GeminiCleaner, "ocr_page", ocr_mock)

    AudiobookService.initialize()
    await AudiobookService._phase_clean(bid, api_key="test-key")

    ocr_mock.assert_called_once()
    clean_path = AudiobookStore.page_clean_path(bid, 1)
    with open(clean_path, encoding="utf-8") as f:
        assert f.read() == "Chapter One: The Beginning"


@pytest.mark.asyncio
async def test_blank_txt_page_unaffected_by_d6_fix(monkeypatch):
    """Non-PDF files were never part of the D6 bug (is_pdf gates the whole
    branch) — a blank TXT/MD page already reached clean_page's own free
    short-circuit. Confirms the fix's `is_pdf and not stripped` guard
    doesn't accidentally change non-PDF behaviour."""
    bid = AudiobookStore.create_book("Notes.txt")
    meta = AudiobookStore.initial_meta(
        bid, "Notes.txt", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["file_ext"] = "txt"
    AudiobookStore.write_meta(bid, meta)
    raw = AudiobookStore.page_raw_path(bid, 1)
    os.makedirs(os.path.dirname(raw), exist_ok=True)
    with open(raw, "w", encoding="utf-8") as f:
        f.write("")

    from app.services import gemini_cleaner as _gc

    ocr_mock = AsyncMock(side_effect=AssertionError("OCR must not be called for TXT"))
    monkeypatch.setattr(_gc.GeminiCleaner, "ocr_page", ocr_mock)
    # clean_page is the real (unmocked) implementation here — its own
    # `if not raw_text.strip(): return "-"` free short-circuit must fire.

    AudiobookService.initialize()
    await AudiobookService._phase_clean(bid, api_key="test-key")

    ocr_mock.assert_not_called()
    clean_path = AudiobookStore.page_clean_path(bid, 1)
    with open(clean_path, encoding="utf-8") as f:
        assert f.read() == "-"


# ===========================================================================
# D8: dead "[blank...]" branch removed from _phase_tts
# ===========================================================================


@pytest.mark.asyncio
async def test_text_matching_dead_blank_marker_pattern_is_narrated():
    """A page whose REAL cleaned narration text happens to look like the old
    dead marker pattern ("[blank ...]") must be sent to TTS like any other
    real text, not silently silenced. Only the literal "-" marker means
    'blank page' — this text is a full sentence, not that marker."""
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    AudiobookStore.write_meta(bid, meta)
    clean_path = AudiobookStore.page_clean_path(bid, 1)
    os.makedirs(os.path.dirname(clean_path), exist_ok=True)
    with open(clean_path, "w", encoding="utf-8") as f:
        # A real sentence that happens to match the dead startswith/endswith
        # pattern — e.g. from a book about form design or typography.
        f.write("[blank space intentionally left for the reader's notes]")

    async def real_tts(text, voice, speed):
        yield {
            "index": 0,
            "text": text,
            "ok": True,
            "audio": np.ones(4800, dtype=np.float32),
            "duration_sec": 4800 / SAMPLE_RATE,
        }

    with (
        patch(
            "app.services.audiobook_service.EngineManager.ensure_loaded",
            new=AsyncMock(return_value=None),
        ),
        patch("app.services.audiobook_service.EngineManager.touch", return_value=None),
        patch(
            "app.services.audiobook_service.EngineManager.generate_with_timing",
            side_effect=real_tts,
        ),
    ):
        await AudiobookService._phase_tts(bid, meta)

    wav_path = AudiobookStore.page_audio_path(bid, 1)
    assert os.path.exists(wav_path)
    # Real synthesized audio (4800 samples), NOT the 0.3s-silence marker size
    # the dead branch would have produced (int(0.3 * SAMPLE_RATE) samples).
    silence_samples = int(0.3 * SAMPLE_RATE)
    assert (
        os.path.getsize(wav_path) == WAV_HEADER_SIZE + 4800 * 2
    ), "text resembling the dead '[blank...]' pattern must be narrated, not silenced"
    assert 4800 != silence_samples, "sanity: fixture sizes must differ"


@pytest.mark.asyncio
async def test_literal_dash_marker_still_produces_silence():
    """Non-regression: the ONE real blank-page marker ("-", written by
    GeminiCleaner/the dedup logic) must still produce silence after the dead
    branch's removal."""
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    AudiobookStore.write_meta(bid, meta)
    clean_path = AudiobookStore.page_clean_path(bid, 1)
    os.makedirs(os.path.dirname(clean_path), exist_ok=True)
    with open(clean_path, "w", encoding="utf-8") as f:
        f.write("-")

    generate_mock = AsyncMock(side_effect=AssertionError("TTS must not run for '-'"))
    with (
        patch(
            "app.services.audiobook_service.EngineManager.ensure_loaded",
            new=AsyncMock(return_value=None),
        ),
        patch("app.services.audiobook_service.EngineManager.touch", return_value=None),
        patch(
            "app.services.audiobook_service.EngineManager.generate_with_timing",
            generate_mock,
        ),
    ):
        await AudiobookService._phase_tts(bid, meta)

    wav_path = AudiobookStore.page_audio_path(bid, 1)
    assert os.path.exists(wav_path)
    silence_samples = int(0.3 * SAMPLE_RATE)
    assert os.path.getsize(wav_path) == WAV_HEADER_SIZE + silence_samples * 2
