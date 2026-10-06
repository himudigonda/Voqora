"""Tests for TextExtractor — TXT / DOCX / Markdown extraction.

Regression coverage for the bug where DOCX table content was silently
dropped: `doc.paragraphs` alone (python-docx) never includes table cells,
so a document with a table lost that content entirely on extraction with
no error and no signal to the user."""

from __future__ import annotations

import os
import tempfile

from docx import Document

from app.services.text_extractor import TextExtractor


def _write_docx(path: str) -> None:
    doc = Document()
    doc.add_paragraph("Introduction paragraph before the table.")
    table = doc.add_table(rows=2, cols=2)
    table.rows[0].cells[0].text = "Name"
    table.rows[0].cells[1].text = "Role"
    table.rows[1].cells[0].text = "Ada"
    table.rows[1].cells[1].text = "Engineer"
    doc.add_paragraph("Closing paragraph after the table.")
    doc.save(path)


def test_docx_table_content_is_not_silently_dropped():
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "with_table.docx")
        _write_docx(path)

        text = TextExtractor.read_text(path)

        assert "Introduction paragraph before the table." in text
        assert "Closing paragraph after the table." in text
        assert "Ada" in text
        assert "Engineer" in text
        assert "Name" in text and "Role" in text


def test_docx_document_order_paragraph_table_paragraph_is_preserved():
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "with_table.docx")
        _write_docx(path)

        text = TextExtractor.read_text(path)

        intro_idx = text.index("Introduction paragraph")
        table_idx = text.index("Ada")
        closing_idx = text.index("Closing paragraph")
        assert intro_idx < table_idx < closing_idx


def test_docx_without_tables_still_works():
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "plain.docx")
        doc = Document()
        doc.add_paragraph("Just a plain paragraph.")
        doc.add_paragraph("Another plain paragraph.")
        doc.save(path)

        text = TextExtractor.read_text(path)

        assert "Just a plain paragraph." in text
        assert "Another plain paragraph." in text


def test_docx_empty_paragraphs_are_skipped():
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "with_blanks.docx")
        doc = Document()
        doc.add_paragraph("First.")
        doc.add_paragraph("")
        doc.add_paragraph("Second.")
        doc.save(path)

        text = TextExtractor.read_text(path)

        # No stray blank blocks collapsing into unexpected extra separators.
        assert "First." in text and "Second." in text


def test_txt_and_md_read_verbatim():
    with tempfile.TemporaryDirectory() as tmp:
        for ext in (".txt", ".md"):
            path = os.path.join(tmp, f"sample{ext}")
            content = "# Heading\n\nSome **bold** prose."
            with open(path, "w", encoding="utf-8") as f:
                f.write(content)
            assert TextExtractor.read_text(path) == content


def test_text_cover_renders_title_and_first_page_on_paper(monkeypatch, tmp_path):
    from PIL import Image

    from app.services.audiobook_store import AudiobookStore

    monkeypatch.setattr(
        AudiobookStore, "root_dir", classmethod(lambda cls: str(tmp_path))
    )
    os.makedirs(tmp_path / "b1")
    with open(AudiobookStore.source_file_path("b1", "md"), "w", encoding="utf-8") as f:
        f.write("# Notes\n\nThe opening paragraph of the document.")
    AudiobookStore.write_meta(
        "b1", {"book_id": "b1", "title": "Notes.md", "file_ext": "md"}
    )

    TextExtractor.render_cover("b1")

    with Image.open(AudiobookStore.cover_path("b1")) as cover:
        assert cover.size == (600, 840)
        assert min(cover.getpixel((5, 5))) > 230
        band = cover.crop((56, 60, 544, 120))
        dark_pixels = sum(
            1
            for x in range(band.width)
            for y in range(band.height)
            if max(band.getpixel((x, y))) < 80
        )
        assert dark_pixels > 200, "the title must be drawn at a readable size"
        body = cover.crop((56, 150, 544, 260))
        text_pixels = sum(
            1
            for x in range(body.width)
            for y in range(body.height)
            if max(body.getpixel((x, y))) < 200
        )
        assert (
            text_pixels > 100
        ), "the opening text comes from the source before pages exist"


def test_hard_wrapped_text_without_blank_lines_is_paged():
    from app.services.text_extractor import _WORDS_PER_PAGE

    text = "\n".join("one two three four five six seven eight." for _ in range(5000))
    pages = TextExtractor.split_pages(text)
    assert len(pages) > 1
    assert max(len(p.split()) for p in pages) <= _WORDS_PER_PAGE
    assert sum(len(p.split()) for p in pages) == 40000


def test_single_unpunctuated_line_is_paged_by_words():
    from app.services.text_extractor import _WORDS_PER_PAGE

    pages = TextExtractor.split_pages(" ".join(["word"] * 3000))
    assert max(len(p.split()) for p in pages) <= _WORDS_PER_PAGE
    assert sum(len(p.split()) for p in pages) == 3000


def test_unterminated_fence_does_not_swallow_the_document():
    text = "Intro.\n\n```\n" + "\n\n".join(["Real prose follows here."] * 200)
    pages = TextExtractor.split_pages(text)
    assert len(pages) > 1
    assert not any("```" in p for p in pages)


def test_terminated_fence_with_blank_lines_stays_on_one_page():
    text = "Before.\n\n```\nline one\n\nline two\n```\n\nAfter."
    assert TextExtractor.split_pages(text) == [
        "Before.\n\n```\nline one\n\nline two\n```\n\nAfter."
    ]
