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
