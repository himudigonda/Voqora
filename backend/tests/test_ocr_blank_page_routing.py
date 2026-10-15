from __future__ import annotations

import os
import shutil
import tempfile
from unittest.mock import AsyncMock, patch

import numpy as np
import pytest

from app.services import llm_cleaner as _lc
from app.services import pdf_extractor as _pe
from app.services.audiobook_service import (
    SAMPLE_RATE,
    WAV_HEADER_SIZE,
    AudiobookService,
)
from app.services.audiobook_store import AudiobookStore
from app.services.llm_providers import LLMCredential


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


def _make_pdf_book(is_image_only: bool | None, uses_llm: bool = True) -> str:
    bid = AudiobookStore.create_book("Scan.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Scan.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["file_ext"] = "pdf"
    meta["uses_gemini_cleanup"] = uses_llm
    if is_image_only is not None:
        meta["is_image_only"] = is_image_only
    AudiobookStore.write_meta(bid, meta)
    return bid


def _write_raw(bid: str, text: str) -> None:
    raw = AudiobookStore.page_raw_path(bid, 1)
    os.makedirs(os.path.dirname(raw), exist_ok=True)
    with open(raw, "w", encoding="utf-8") as f:
        f.write(text)


def _read_clean(bid: str) -> str:
    with open(AudiobookStore.page_clean_path(bid, 1), encoding="utf-8") as f:
        return f.read()


def _forbid_llm(monkeypatch) -> dict[str, AsyncMock]:
    mocks = {
        "ocr": AsyncMock(side_effect=AssertionError("OCR must not be called")),
        "clean": AsyncMock(side_effect=AssertionError("clean_page must not be called")),
        "render": AsyncMock(side_effect=AssertionError("render must not be called")),
        "reserve": AsyncMock(side_effect=AssertionError("no reservation expected")),
    }
    monkeypatch.setattr(_lc.LLMCleaner, "ocr_page", mocks["ocr"])
    monkeypatch.setattr(_lc.LLMCleaner, "clean_page", mocks["clean"])
    monkeypatch.setattr(
        _pe.PDFExtractor,
        "render_page_image",
        classmethod(lambda cls, p, n, **kw: mocks["render"]()),
    )
    monkeypatch.setattr(AudiobookService, "_reserve_llm_operation", mocks["reserve"])
    return mocks


@pytest.mark.asyncio
@pytest.mark.parametrize("blank_text", ["", "   \n\n   \t  "])
async def test_blank_page_in_text_pdf_skips_ocr_and_reservation(
    monkeypatch, blank_text
):
    bid = _make_pdf_book(is_image_only=False)
    _write_raw(bid, blank_text)
    mocks = _forbid_llm(monkeypatch)

    AudiobookService.initialize()
    await AudiobookService._phase_clean(bid, LLMCredential.gemini("test-key"))

    for mock in mocks.values():
        mock.assert_not_called()
    assert _read_clean(bid) == "-"
    after = AudiobookStore.read_meta(bid)
    assert not after.get("failed_pages")
    assert not (after.get("budget") or {}).get("ledger")


def _write_source_pdf(bid: str, *, with_image: bool) -> None:
    from PIL import Image

    path = AudiobookStore.source_file_path(bid, "pdf")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if with_image:
        Image.new("RGB", (200, 200), (20, 20, 20)).save(path)
        return
    with open(path, "wb") as f:
        f.write(
            b"%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
            b"2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"
            b"3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>\n"
            b"endobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n"
        )


@pytest.mark.asyncio
async def test_scanned_page_in_text_pdf_is_ocred_not_blanked(monkeypatch):
    bid = _make_pdf_book(is_image_only=False)
    _write_raw(bid, "")
    _write_source_pdf(bid, with_image=True)
    monkeypatch.setattr(
        _pe.PDFExtractor,
        "render_page_image",
        classmethod(lambda cls, p, n, **kw: b"imgbytes"),
    )
    ocr = AsyncMock(return_value="Scanned appendix text.")
    monkeypatch.setattr(_lc.LLMCleaner, "ocr_page", ocr)

    AudiobookService.initialize()
    await AudiobookService._phase_clean(bid, LLMCredential.gemini("test-key"))

    ocr.assert_called_once()
    assert _read_clean(bid) == "Scanned appendix text."


@pytest.mark.asyncio
async def test_page_without_raster_content_in_text_pdf_stays_blank(monkeypatch):
    bid = _make_pdf_book(is_image_only=False)
    _write_raw(bid, "")
    _write_source_pdf(bid, with_image=False)
    mocks = _forbid_llm(monkeypatch)

    AudiobookService.initialize()
    await AudiobookService._phase_clean(bid, LLMCredential.gemini("test-key"))

    for mock in mocks.values():
        mock.assert_not_called()
    assert _read_clean(bid) == "-"


@pytest.mark.asyncio
async def test_blank_page_in_text_pdf_is_not_a_failure_for_a_text_only_model(
    monkeypatch,
):
    bid = _make_pdf_book(is_image_only=False)
    _write_raw(bid, "")
    _forbid_llm(monkeypatch)

    AudiobookService.initialize()
    await AudiobookService._phase_clean(bid, LLMCredential("groq", api_key="gsk"))

    assert _read_clean(bid) == "-"
    assert not AudiobookStore.read_meta(bid).get("failed_pages")


@pytest.mark.asyncio
async def test_image_only_page_in_text_pdf_is_blank_not_failed_for_a_text_only_model(
    monkeypatch,
):
    bid = _make_pdf_book(is_image_only=False)
    _write_raw(bid, "")
    _write_source_pdf(bid, with_image=True)
    mocks = _forbid_llm(monkeypatch)

    AudiobookService.initialize()
    await AudiobookService._phase_clean(bid, LLMCredential("groq", api_key="gsk"))

    for mock in mocks.values():
        mock.assert_not_called()
    assert _read_clean(bid) == "-"
    assert not AudiobookStore.read_meta(bid).get("failed_pages")


@pytest.mark.asyncio
async def test_sparse_nonempty_page_in_text_pdf_still_routes_to_ocr(monkeypatch):
    bid = _make_pdf_book(is_image_only=False)
    _write_raw(bid, "1")
    monkeypatch.setattr(
        _pe.PDFExtractor,
        "render_page_image",
        classmethod(lambda cls, p, n, **kw: b"imgbytes"),
    )
    ocr = AsyncMock(return_value="OCR result.")
    monkeypatch.setattr(_lc.LLMCleaner, "ocr_page", ocr)

    AudiobookService.initialize()
    await AudiobookService._phase_clean(bid, LLMCredential.gemini("test-key"))

    ocr.assert_called_once()
    assert _read_clean(bid) == "OCR result."


@pytest.mark.asyncio
async def test_image_only_document_blank_page_still_routes_to_ocr(monkeypatch):
    bid = _make_pdf_book(is_image_only=True)
    _write_raw(bid, "")
    monkeypatch.setattr(
        _pe.PDFExtractor,
        "render_page_image",
        classmethod(lambda cls, p, n, **kw: b"imgbytes"),
    )
    ocr = AsyncMock(return_value="Chapter One: The Beginning")
    monkeypatch.setattr(_lc.LLMCleaner, "ocr_page", ocr)

    AudiobookService.initialize()
    await AudiobookService._phase_clean(bid, LLMCredential.gemini("test-key"))

    ocr.assert_called_once()
    assert _read_clean(bid) == "Chapter One: The Beginning"


@pytest.mark.asyncio
async def test_document_without_image_only_flag_still_ocrs_blank_page(monkeypatch):
    bid = _make_pdf_book(is_image_only=None)
    _write_raw(bid, "")
    monkeypatch.setattr(
        _pe.PDFExtractor,
        "render_page_image",
        classmethod(lambda cls, p, n, **kw: b"imgbytes"),
    )
    ocr = AsyncMock(return_value="Recovered text.")
    monkeypatch.setattr(_lc.LLMCleaner, "ocr_page", ocr)

    AudiobookService.initialize()
    await AudiobookService._phase_clean(bid, LLMCredential.gemini("test-key"))

    ocr.assert_called_once()


@pytest.mark.asyncio
async def test_blank_txt_page_never_reaches_ocr(monkeypatch):
    bid = AudiobookStore.create_book("Notes.txt")
    meta = AudiobookStore.initial_meta(
        bid, "Notes.txt", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["file_ext"] = "txt"
    meta["uses_gemini_cleanup"] = False
    AudiobookStore.write_meta(bid, meta)
    _write_raw(bid, "")
    mocks = _forbid_llm(monkeypatch)

    AudiobookService.initialize()
    await AudiobookService._phase_clean(bid, None)

    mocks["ocr"].assert_not_called()
    assert _read_clean(bid) == "-"


@pytest.mark.asyncio
async def test_text_matching_old_blank_marker_pattern_is_narrated():
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    AudiobookStore.write_meta(bid, meta)
    clean_path = AudiobookStore.page_clean_path(bid, 1)
    os.makedirs(os.path.dirname(clean_path), exist_ok=True)
    with open(clean_path, "w", encoding="utf-8") as f:
        f.write("[blank space intentionally left for the reader's notes]")

    async def real_tts(*args, **kwargs):
        yield np.ones(4800, dtype=np.float32)

    with (
        patch(
            "app.services.audiobook_service.EngineManager.ensure_loaded",
            new=AsyncMock(return_value=None),
        ),
        patch("app.services.audiobook_service.EngineManager.touch", return_value=None),
        patch(
            "app.services.audiobook_service.EngineManager.generate",
            side_effect=real_tts,
        ),
        patch("app.services.audiobook_service.asyncio.sleep", new=AsyncMock()),
    ):
        await AudiobookService._phase_tts(bid, meta)

    wav_path = AudiobookStore.page_audio_path(bid, 1)
    assert os.path.getsize(wav_path) >= WAV_HEADER_SIZE + 4800 * 2
    assert os.path.getsize(wav_path) != WAV_HEADER_SIZE + int(0.3 * SAMPLE_RATE) * 2


@pytest.mark.asyncio
async def test_literal_dash_marker_still_produces_silence():
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    AudiobookStore.write_meta(bid, meta)
    clean_path = AudiobookStore.page_clean_path(bid, 1)
    os.makedirs(os.path.dirname(clean_path), exist_ok=True)
    with open(clean_path, "w", encoding="utf-8") as f:
        f.write("-")

    generate = AsyncMock(side_effect=AssertionError("TTS must not run for '-'"))
    with (
        patch(
            "app.services.audiobook_service.EngineManager.ensure_loaded",
            new=AsyncMock(return_value=None),
        ),
        patch("app.services.audiobook_service.EngineManager.touch", return_value=None),
        patch("app.services.audiobook_service.EngineManager.generate", generate),
    ):
        await AudiobookService._phase_tts(bid, meta)

    wav_path = AudiobookStore.page_audio_path(bid, 1)
    assert os.path.getsize(wav_path) == WAV_HEADER_SIZE + int(0.3 * SAMPLE_RATE) * 2
