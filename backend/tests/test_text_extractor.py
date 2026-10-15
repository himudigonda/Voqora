"""Tests for TextExtractor — TXT / DOCX / Markdown extraction.

Regression coverage for the bug where DOCX table content was silently
dropped: `doc.paragraphs` alone (python-docx) never includes table cells,
so a document with a table lost that content entirely on extraction with
no error and no signal to the user."""

from __future__ import annotations

import os
import tempfile

from docx import Document

from app.services.text_extractor import _WORDS_PER_PAGE, TextExtractor


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


def test_text_cover_wraps_long_titles_and_upgrades_stale_covers(monkeypatch, tmp_path):
    from PIL import Image

    from app.services.audiobook_store import AudiobookStore

    monkeypatch.setattr(
        AudiobookStore, "root_dir", classmethod(lambda cls: str(tmp_path))
    )
    os.makedirs(tmp_path / "b2")
    with open(AudiobookStore.source_file_path("b2", "md"), "w", encoding="utf-8") as f:
        f.write("Markets — equities, derivatives, and volatility.")
    AudiobookStore.write_meta(
        "b2",
        {
            "book_id": "b2",
            "title": "market_mechanics_crash_course.md",
            "file_ext": "md",
        },
    )
    out = AudiobookStore.cover_path("b2")
    Image.new("RGB", (10, 10)).save(out, format="JPEG")
    assert not TextExtractor.cover_is_current(out)

    TextExtractor.render_cover("b2")

    assert TextExtractor.cover_is_current(out)
    with Image.open(out) as cover:
        assert cover.size == (600, 840)
        right_margin = cover.crop((560, 0, 600, 200))
        assert all(
            max(right_margin.getpixel((x, y))) > 200
            for x in range(right_margin.width)
            for y in range(right_margin.height)
        ), "title text must stay inside the margins"


def test_docx_table_is_narrated_with_its_headers():
    from app.services.text_normalizer import strip_markdown_for_narration

    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "with_table.docx")
        _write_docx(path)

        narration = strip_markdown_for_narration(TextExtractor.read_text(path))

        assert "Name is Ada, Role is Engineer." in narration


def _big_paragraph(extra: int = 20) -> str:
    return " ".join(f"word{i}" for i in range(_WORDS_PER_PAGE + extra))


def test_read_outline_is_none_for_plain_text(tmp_path):
    path = tmp_path / "plain.txt"
    path.write_text("# Not a heading in a txt file.", encoding="utf-8")

    assert TextExtractor.read_outline(str(path)) is None
    assert TextExtractor.read_outline("/any/path") is None


def test_read_outline_docx_detects_heading_styles(tmp_path):
    doc = Document()
    doc.add_heading("Chapter One", level=1)
    doc.add_paragraph("Body text for chapter one.")
    doc.add_heading("Section 1.1", level=2)
    doc.add_paragraph("More body text here.")
    doc.add_heading("Chapter Two", level=1)
    doc.add_paragraph("Final body text.")
    path = str(tmp_path / "headings.docx")
    doc.save(path)

    assert TextExtractor.read_outline(path) == [
        {"title": "Chapter One", "start_page": 1, "level": 1},
        {"title": "Section 1.1", "start_page": 1, "level": 2},
        {"title": "Chapter Two", "start_page": 1, "level": 1},
    ]


def test_read_outline_docx_without_heading_styles_is_none(tmp_path):
    doc = Document()
    doc.add_paragraph("Just a plain paragraph.")
    doc.add_paragraph("Another plain paragraph.")
    path = str(tmp_path / "plain.docx")
    doc.save(path)

    assert TextExtractor.read_outline(path) is None


def test_read_outline_docx_heading_position_matches_pagination(tmp_path):
    doc = Document()
    doc.add_paragraph(_big_paragraph())
    doc.add_heading("Chapter Two Starts Here", level=1)
    doc.add_paragraph("Body text.")
    path = str(tmp_path / "page_two.docx")
    doc.save(path)

    assert TextExtractor.read_outline(path) == [
        {"title": "Chapter Two Starts Here", "start_page": 2, "level": 1}
    ]
    pages = TextExtractor.split_pages(TextExtractor.read_text(path))
    assert "Chapter Two Starts Here" in pages[1]
    assert "Chapter Two Starts Here" not in pages[0]


def test_read_outline_docx_heading_position_survives_embedded_double_break(tmp_path):
    doc = Document()
    paragraph = doc.add_paragraph()
    paragraph.add_run(" ".join(f"a{i}" for i in range(50)))
    break_run = paragraph.add_run()
    break_run.add_break()
    break_run.add_break()
    paragraph.add_run(" ".join(f"b{i}" for i in range(400)))
    assert "\n\n" in paragraph.text
    doc.add_heading("Real Chapter Two", level=1)
    doc.add_paragraph("Body text after the heading.")
    path = str(tmp_path / "double_break.docx")
    doc.save(path)

    headings = TextExtractor.read_outline(path)
    pages = TextExtractor.split_pages(TextExtractor.read_text(path))

    assert headings == [{"title": "Real Chapter Two", "start_page": 3, "level": 1}]
    assert "Real Chapter Two" in pages[2]


def test_read_outline_docx_heading_position_accounts_for_tables(tmp_path):
    doc = Document()
    doc.add_paragraph(" ".join(f"w{i}" for i in range(_WORDS_PER_PAGE - 5)))
    table = doc.add_table(rows=2, cols=2)
    for row in table.rows:
        for cell in row.cells:
            cell.text = "alpha beta gamma"
    doc.add_heading("After The Table", level=1)
    doc.add_paragraph("Body.")
    path = str(tmp_path / "table_then_heading.docx")
    doc.save(path)

    headings = TextExtractor.read_outline(path)
    pages = TextExtractor.split_pages(TextExtractor.read_text(path))

    assert headings == [{"title": "After The Table", "start_page": 2, "level": 1}]
    assert "After The Table" in pages[1]
    assert "After The Table" not in pages[0]


def test_read_outline_docx_style_named_heading_defaults_to_level_one(tmp_path):
    from docx.enum.style import WD_STYLE_TYPE

    doc = Document()
    style = doc.styles.add_style("Heading", WD_STYLE_TYPE.PARAGRAPH)
    doc.add_paragraph("Untitled-level heading").style = style
    path = str(tmp_path / "custom.docx")
    doc.save(path)

    assert TextExtractor.read_outline(path) == [
        {"title": "Untitled-level heading", "start_page": 1, "level": 1}
    ]


def test_read_outline_docx_corrupt_or_missing_is_none(tmp_path):
    corrupt = tmp_path / "corrupt.docx"
    corrupt.write_bytes(b"not a real docx")

    assert TextExtractor.read_outline(str(tmp_path / "missing.docx")) is None
    assert TextExtractor.read_outline(str(corrupt)) is None


def test_read_outline_md_detects_h1_and_h2(tmp_path):
    path = tmp_path / "headers.md"
    path.write_text(
        "# Chapter One\n\nBody.\n\n## Section 1.1\n\nMore.\n\n"
        "# Chapter Two\n\nFinal.\n",
        encoding="utf-8",
    )

    assert TextExtractor.read_outline(str(path)) == [
        {"title": "Chapter One", "start_page": 1, "level": 1},
        {"title": "Section 1.1", "start_page": 1, "level": 2},
        {"title": "Chapter Two", "start_page": 1, "level": 1},
    ]


def test_read_outline_md_without_h1_or_h2_is_none(tmp_path):
    path = tmp_path / "deep.md"
    path.write_text(
        "Plain paragraph.\n\n### Level three only.\n\nAnother.\n", encoding="utf-8"
    )

    assert TextExtractor.read_outline(str(path)) is None


def test_read_outline_md_heading_position_matches_pagination(tmp_path):
    path = tmp_path / "page_two.md"
    path.write_text(
        f"{_big_paragraph()}\n\n# Chapter Two Starts Here\n\nBody.\n",
        encoding="utf-8",
    )

    assert TextExtractor.read_outline(str(path)) == [
        {"title": "Chapter Two Starts Here", "start_page": 2, "level": 1}
    ]
    pages = TextExtractor.split_pages(TextExtractor.read_text(str(path)))
    assert "Chapter Two Starts Here" in pages[1]


def test_read_outline_md_heading_inside_oversized_block_uses_its_chunk_page(tmp_path):
    path = tmp_path / "oversized.md"
    path.write_text(
        f"# First\n{_big_paragraph(2 * _WORDS_PER_PAGE)}\n\n# Last\n\nEnd.\n",
        encoding="utf-8",
    )

    headings = TextExtractor.read_outline(str(path))
    pages = TextExtractor.split_pages(TextExtractor.read_text(str(path)))

    assert headings[0] == {"title": "First", "start_page": 1, "level": 1}
    assert headings[1]["title"] == "Last"
    assert "# Last" in pages[headings[1]["start_page"] - 1]


def test_read_outline_md_heading_directly_after_text_is_found(tmp_path):
    path = tmp_path / "tight.md"
    path.write_text("Intro line.\n# Tight Heading\nBody.\n", encoding="utf-8")

    assert TextExtractor.read_outline(str(path)) == [
        {"title": "Tight Heading", "start_page": 1, "level": 1}
    ]


def test_read_outline_md_ignores_headings_inside_fences(tmp_path):
    path = tmp_path / "fenced.md"
    path.write_text(
        "Intro.\n\n```\n# not a heading\n\n## also not\n```\n\n# Real\n",
        encoding="utf-8",
    )

    assert TextExtractor.read_outline(str(path)) == [
        {"title": "Real", "start_page": 1, "level": 1}
    ]


def test_read_outline_md_missing_file_is_none(tmp_path):
    assert TextExtractor.read_outline(str(tmp_path / "missing.md")) is None


def test_parse_md_header_rules():
    assert TextExtractor._parse_md_header("#nospace") is None
    assert TextExtractor._parse_md_header("some #hashtag inline") is None
    assert TextExtractor._parse_md_header("### too deep") is None
    assert TextExtractor._parse_md_header("# Valid Header") == (1, "Valid Header")
    assert TextExtractor._parse_md_header("## Valid H2 ##") == (2, "Valid H2")
    assert TextExtractor._parse_md_header("# Learning F#") == (1, "Learning F#")
    assert TextExtractor._parse_md_header("## C# and F#") == (2, "C# and F#")
    assert TextExtractor._parse_md_header("# Single Closer #") == (1, "Single Closer")


def test_paginate_start_pages_agree_with_split_pages():
    paragraphs = TextExtractor._paragraphs(
        f"{_big_paragraph()}\n\nsecond block\n\n{_big_paragraph(5)}\n\nlast"
    )
    pages, start_pages = TextExtractor._paginate(paragraphs)

    assert pages == TextExtractor.split_pages(
        f"{_big_paragraph()}\n\nsecond block\n\n{_big_paragraph(5)}\n\nlast"
    )
    assert len(start_pages) == len(paragraphs)
    for paragraph, start_page in zip(paragraphs, start_pages, strict=True):
        assert paragraph in pages[start_page - 1]


def test_atomic_writes_leave_no_tmp_files(tmp_path):
    target = str(tmp_path / "pages" / "001.txt")
    TextExtractor._atomic_write(target, "text")
    TextExtractor._atomic_write_bytes(target + ".bin", b"bytes")

    assert sorted(os.listdir(tmp_path / "pages")) == ["001.txt", "001.txt.bin"]
