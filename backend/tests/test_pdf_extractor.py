"""Tests for PDFExtractor — pdfplumber wrapper.

Most tests mock pdfplumber.open so no real PDF file is needed. The
read_outline() suite is the exception: it exercises pypdfium2 against real
PDF fixtures built in-test via pypdf (see _build_pdf_with_outline), because
the bug it covers (T3.1 / the v1.1 design notes §3.4) is specifically about pypdfium2's
actual installed API shape — a mock would hide the exact regression this
suite exists to catch.

Key coverage:
  - extract_batch(): opens PDF exactly once for N pages (O(1) open — our fix)
  - extract_batch(): skips existing output files (idempotent / resume-safe)
  - extract_batch(): handles per-page errors gracefully (writes empty string, continues)
  - extract_batch(): no-op on empty page list
  - extract_one(): idempotent — second call skips pdfplumber entirely
  - is_image_only(): sampling logic
  - sample_word_count() / sample_char_count(): three-page sampling
  - page_count(): delegates to pdfplumber
  - read_outline(): real pypdfium2 outline reading — titles/pages/levels,
    no-outline, corrupt/missing file, blank-titled entries (T3.1)
  - _atomic_write() / _atomic_write_bytes(): tmp+rename atomicity
"""

from __future__ import annotations

import os
from contextlib import contextmanager
from unittest.mock import MagicMock, patch

import pytest

from app.services.pdf_extractor import PDFExtractor

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _fake_page(text) -> MagicMock:
    page = MagicMock()
    page.extract_text.return_value = text
    return page


@contextmanager
def _mock_pdf(*page_texts):
    """Patch pdfplumber.open to return N fake pages with the given texts."""
    pdf = MagicMock()
    pdf.__enter__ = MagicMock(return_value=pdf)
    pdf.__exit__ = MagicMock(return_value=False)
    pdf.pages = [_fake_page(t) for t in page_texts]
    with patch("pdfplumber.open", return_value=pdf) as mock_open:
        yield mock_open, pdf


@pytest.fixture()
def tmp_book(tmp_path, monkeypatch):
    """Redirect AudiobookStore to tmp_path and yield (book_id, tmp_path)."""
    from app.services.audiobook_store import AudiobookStore

    class _S:
        @property
        def AUDIOBOOKS_DIR(self):
            return str(tmp_path)

    monkeypatch.setattr("app.services.audiobook_store.settings", _S())
    AudiobookStore._reset_for_tests()
    bid = AudiobookStore.create_book("test.pdf")
    yield bid, str(tmp_path)
    AudiobookStore._reset_for_tests()


# ---------------------------------------------------------------------------
# page_count
# ---------------------------------------------------------------------------


def test_page_count_returns_len_of_pages():
    with _mock_pdf("p1", "p2", "p3"):
        count = PDFExtractor.page_count("/fake/path.pdf")
    assert count == 3


def test_page_count_single_page():
    with _mock_pdf("only"):
        assert PDFExtractor.page_count("/fake.pdf") == 1


def test_page_count_empty_pdf():
    with _mock_pdf():
        assert PDFExtractor.page_count("/empty.pdf") == 0


# ---------------------------------------------------------------------------
# is_image_only
# ---------------------------------------------------------------------------


def test_is_image_only_false_when_text_found():
    long_text = "Hello world. " * 10  # > 100 chars
    with _mock_pdf(long_text):
        assert PDFExtractor.is_image_only("/fake.pdf") is False


def test_is_image_only_true_when_no_text():
    with _mock_pdf("", "", ""):
        assert PDFExtractor.is_image_only("/fake.pdf") is True


def test_is_image_only_true_when_text_below_threshold():
    with _mock_pdf("ab", "cd"):
        assert PDFExtractor.is_image_only("/fake.pdf") is True


def test_is_image_only_early_exit_once_threshold_exceeded():
    """Once total_chars >= threshold the loop short-circuits (no extra opens)."""
    pages = [""] * 10
    pages[0] = "X" * 200
    with _mock_pdf(*pages) as (_, pdf):
        result = PDFExtractor.is_image_only("/fake.pdf")
    assert result is False
    # Only first page needed to exceed threshold; pdf.pages is still available
    # (all-or-nothing list, but extract_text on later pages NOT called)
    pdf.pages[1].extract_text.assert_not_called()


# ---------------------------------------------------------------------------
# sample_word_count / sample_char_count
# ---------------------------------------------------------------------------


def test_sample_word_count_single_page():
    with _mock_pdf("one two three"):
        assert PDFExtractor.sample_word_count("/f.pdf") == 3


def test_sample_word_count_samples_three_of_five():
    # 5 pages; indices sampled: 0, 2, 4 (first, mid, last)
    # word counts: 2, 3, 4 → average = (2+3+4)//3 = 3
    pages = ["a b", "x x x x", "a b c", "d e", "a b c d"]
    with _mock_pdf(*pages):
        count = PDFExtractor.sample_word_count("/f.pdf")
    assert count == 3


def test_sample_word_count_zero_when_no_pages():
    pdf = MagicMock()
    pdf.__enter__ = MagicMock(return_value=pdf)
    pdf.__exit__ = MagicMock(return_value=False)
    pdf.pages = []
    with patch("pdfplumber.open", return_value=pdf):
        assert PDFExtractor.sample_word_count("/f.pdf") == 0


def test_sample_char_count_single_page():
    text = "hello world"
    with _mock_pdf(text):
        assert PDFExtractor.sample_char_count("/f.pdf") == len(text)


def test_sample_char_count_averages_three_samples():
    # indices 0, 2, 4 → lengths 5, 3, 4 → (5+3+4)//3 = 4
    pages = ["abcde", "xx", "abc", "d", "abcd"]
    with _mock_pdf(*pages):
        assert PDFExtractor.sample_char_count("/f.pdf") == 4


# ---------------------------------------------------------------------------
# extract_one
# ---------------------------------------------------------------------------


def test_extract_one_writes_extracted_text(tmp_book):
    bid, _ = tmp_book
    from app.services.audiobook_store import AudiobookStore

    with _mock_pdf("Page content here"):
        PDFExtractor.extract_one(bid, 1)

    out = AudiobookStore.page_raw_path(bid, 1)
    assert os.path.exists(out)
    assert open(out).read() == "Page content here"


def test_extract_one_writes_empty_string_when_extract_returns_none(tmp_book):
    bid, _ = tmp_book
    from app.services.audiobook_store import AudiobookStore

    with _mock_pdf(None) as (_, pdf):
        pdf.pages[0].extract_text.return_value = None
        PDFExtractor.extract_one(bid, 1)

    out = AudiobookStore.page_raw_path(bid, 1)
    assert open(out).read() == ""


def test_extract_one_is_idempotent(tmp_book):
    """If output already exists, pdfplumber.open must NOT be called."""
    bid, _ = tmp_book
    from app.services.audiobook_store import AudiobookStore

    out = AudiobookStore.page_raw_path(bid, 1)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        f.write("already here")

    with _mock_pdf("Different content") as (mock_open, _):
        PDFExtractor.extract_one(bid, 1)
        mock_open.assert_not_called()

    assert open(out).read() == "already here"


# ---------------------------------------------------------------------------
# extract_batch — the O(1)-open fix
# ---------------------------------------------------------------------------


def test_extract_batch_noop_for_empty_list(tmp_book):
    bid, _ = tmp_book
    with patch("pdfplumber.open") as mock_open:
        PDFExtractor.extract_batch(bid, [])
        mock_open.assert_not_called()


def test_extract_batch_opens_pdf_exactly_once(tmp_book):
    """Core O(1) guarantee: one pdfplumber.open() for any number of pages."""
    bid, _ = tmp_book
    with _mock_pdf("p1", "p2", "p3") as (mock_open, _):
        PDFExtractor.extract_batch(bid, [1, 2, 3])
    assert mock_open.call_count == 1


def test_extract_batch_writes_all_requested_pages(tmp_book):
    bid, _ = tmp_book
    from app.services.audiobook_store import AudiobookStore

    with _mock_pdf("First", "Second", "Third"):
        PDFExtractor.extract_batch(bid, [1, 2, 3])

    for n, expected in [(1, "First"), (2, "Second"), (3, "Third")]:
        out = AudiobookStore.page_raw_path(bid, n)
        assert os.path.exists(out), f"page {n} missing"
        assert open(out).read() == expected


def test_extract_batch_skips_existing_files(tmp_book):
    """Pre-existing output files are not overwritten (resume-safe)."""
    bid, _ = tmp_book
    from app.services.audiobook_store import AudiobookStore

    # Pre-write page 2
    out2 = AudiobookStore.page_raw_path(bid, 2)
    os.makedirs(os.path.dirname(out2), exist_ok=True)
    with open(out2, "w") as f:
        f.write("cached content")

    with _mock_pdf("p1", "p2-different", "p3") as (mock_open, pdf):
        PDFExtractor.extract_batch(bid, [1, 2, 3])

    # Page 2 extract_text must NOT have been called (file existed)
    pdf.pages[1].extract_text.assert_not_called()
    # Pre-existing content preserved
    assert open(out2).read() == "cached content"
    # Pages 1 and 3 written correctly
    assert open(AudiobookStore.page_raw_path(bid, 1)).read() == "p1"
    assert open(AudiobookStore.page_raw_path(bid, 3)).read() == "p3"


def test_extract_batch_handles_corrupted_page_gracefully(tmp_book):
    """A page that raises during extract_text writes empty string and continues
    without crashing the whole batch — corrupted page must not abort siblings."""
    bid, _ = tmp_book
    from app.services.audiobook_store import AudiobookStore

    pdf = MagicMock()
    pdf.__enter__ = MagicMock(return_value=pdf)
    pdf.__exit__ = MagicMock(return_value=False)
    p1 = _fake_page("good content")
    p_bad = MagicMock()
    p_bad.extract_text.side_effect = RuntimeError("corrupted page")
    p3 = _fake_page("page 3 content")
    pdf.pages = [p1, p_bad, p3]

    with patch("pdfplumber.open", return_value=pdf):
        PDFExtractor.extract_batch(bid, [1, 2, 3])

    assert open(AudiobookStore.page_raw_path(bid, 1)).read() == "good content"
    assert open(AudiobookStore.page_raw_path(bid, 2)).read() == ""
    assert open(AudiobookStore.page_raw_path(bid, 3)).read() == "page 3 content"


def test_extract_batch_handles_none_text_as_empty_string(tmp_book):
    """extract_text() returning None is treated as empty string, not written as 'None'."""
    bid, _ = tmp_book
    from app.services.audiobook_store import AudiobookStore

    with _mock_pdf(None) as (_, pdf):  # type: ignore[arg-type]
        pdf.pages[0].extract_text.return_value = None
        PDFExtractor.extract_batch(bid, [1])

    out = AudiobookStore.page_raw_path(bid, 1)
    assert open(out).read() == ""


def test_extract_batch_partial_list_skips_others(tmp_book):
    """extract_batch([1, 3]) must only write pages 1 and 3, not page 2."""
    bid, _ = tmp_book
    from app.services.audiobook_store import AudiobookStore

    with _mock_pdf("pg1", "pg2-shouldnt-be-written", "pg3"):
        PDFExtractor.extract_batch(bid, [1, 3])

    assert os.path.exists(AudiobookStore.page_raw_path(bid, 1))
    assert os.path.exists(AudiobookStore.page_raw_path(bid, 3))
    assert not os.path.exists(AudiobookStore.page_raw_path(bid, 2))


# ---------------------------------------------------------------------------
# read_outline — T3.1: pypdfium2's PdfBookmark exposes get_title() /
# get_dest().get_index() (methods), not .title/.page_index (attributes).
# Every access previously raised AttributeError, caught by the blanket
# `except Exception`, so read_outline ALWAYS returned None — every PDF,
# bookmarked or not, silently fell through to Gemini/fallback section
# detection. Confirmed via live introspection of the installed pypdfium2
# (dir(pdfium.PdfBookmark) → only get_count/get_dest/get_title) before
# writing the fix. Zero coverage of this path existed before this suite.
# ---------------------------------------------------------------------------


def _build_pdf_with_outline(
    path: str, num_pages: int, items: list[tuple[str, int, str | None]]
) -> None:
    """Write a real PDF with an embedded bookmark outline to `path`.

    `items` is (title, zero_indexed_page, parent_title_or_None) — parent_title,
    if given, must be an earlier item's title in this same list, letting tests
    build multi-level (nested) outlines. Uses pypdf (dev-only test dependency,
    see backend/pyproject.toml) to author real outline entries that pypdfium2
    then reads back — an in-test-constructed fixture was chosen over a
    checked-in binary PDF so the exact outline structure under test stays
    visible and diffable in the test itself.
    """
    from pypdf import PdfWriter

    writer = PdfWriter()
    for _ in range(num_pages):
        writer.add_blank_page(width=200, height=200)

    added: dict[str, object] = {}
    for title, page_num, parent_title in items:
        parent = added.get(parent_title) if parent_title else None
        added[title] = writer.add_outline_item(title, page_num, parent=parent)

    with open(path, "wb") as f:
        writer.write(f)


def test_read_outline_returns_real_titles_pages_and_levels(tmp_path):
    """The core T3.1 regression check: a PDF with a real embedded outline
    (including nested Part -> Chapter levels) must yield real titles/pages,
    not None — and .level must be captured, not discarded."""
    path = str(tmp_path / "with_outline.pdf")
    _build_pdf_with_outline(
        path,
        num_pages=6,
        items=[
            ("Part One", 0, None),
            ("Chapter 1", 0, "Part One"),
            ("Chapter 2", 2, "Part One"),
            ("Part Two", 4, None),
        ],
    )

    sections = PDFExtractor.read_outline(path)

    assert sections is not None
    by_title = {s["title"]: s for s in sections}
    assert by_title["Part One"] == {"title": "Part One", "start_page": 1, "level": 0}
    assert by_title["Chapter 1"] == {"title": "Chapter 1", "start_page": 1, "level": 1}
    assert by_title["Chapter 2"] == {"title": "Chapter 2", "start_page": 3, "level": 1}
    assert by_title["Part Two"] == {"title": "Part Two", "start_page": 5, "level": 0}


def test_read_outline_returns_none_when_pdf_has_no_bookmarks(tmp_path):
    from pypdf import PdfWriter

    path = str(tmp_path / "no_outline.pdf")
    writer = PdfWriter()
    for _ in range(3):
        writer.add_blank_page(width=200, height=200)
    with open(path, "wb") as f:
        writer.write(f)

    assert PDFExtractor.read_outline(path) is None


def test_read_outline_returns_none_on_missing_file(tmp_path):
    missing = str(tmp_path / "does_not_exist.pdf")
    assert PDFExtractor.read_outline(missing) is None


def test_read_outline_returns_none_on_corrupt_file(tmp_path):
    """The blanket except must still degrade gracefully for a GENUINE parse
    failure — this is the one case it should actually be catching, unlike
    before the fix where it also (wrongly) swallowed every real outline."""
    corrupt = str(tmp_path / "corrupt.pdf")
    with open(corrupt, "wb") as f:
        f.write(b"not a real pdf")
    assert PDFExtractor.read_outline(corrupt) is None


def test_read_outline_skips_blank_titled_entries(tmp_path):
    path = str(tmp_path / "blank_title.pdf")
    _build_pdf_with_outline(
        path,
        num_pages=3,
        items=[("   ", 0, None), ("Real Chapter", 1, None)],
    )

    sections = PDFExtractor.read_outline(path)

    assert sections is not None
    assert len(sections) == 1
    assert sections[0]["title"] == "Real Chapter"


# ---------------------------------------------------------------------------
# _atomic_write / _atomic_write_bytes
# ---------------------------------------------------------------------------


def test_atomic_write_creates_nested_dirs_and_file(tmp_path):
    path = str(tmp_path / "sub" / "nested" / "out.txt")
    PDFExtractor._atomic_write(path, "hello")
    assert open(path).read() == "hello"
    assert not os.path.exists(path + ".tmp"), "temp file must be cleaned up"


def test_atomic_write_replaces_existing_file(tmp_path):
    path = str(tmp_path / "out.txt")
    with open(path, "w") as f:
        f.write("old")
    PDFExtractor._atomic_write(path, "new")
    assert open(path).read() == "new"


def test_atomic_write_bytes_creates_file(tmp_path):
    path = str(tmp_path / "out.bin")
    PDFExtractor._atomic_write_bytes(path, b"\x01\x02\x03")
    assert open(path, "rb").read() == b"\x01\x02\x03"
    assert not os.path.exists(path + ".tmp")


def test_atomic_write_bytes_replaces_existing(tmp_path):
    path = str(tmp_path / "out.bin")
    with open(path, "wb") as f:
        f.write(b"\xff\xff")
    PDFExtractor._atomic_write_bytes(path, b"\x00")
    assert open(path, "rb").read() == b"\x00"
