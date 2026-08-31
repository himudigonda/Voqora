"""Tests for strip_markdown_for_narration — the local-first (no-Gemini)
audiobook cleanup path's Markdown-to-prose stripping.

Regression coverage for the bug where raw Markdown syntax (#, **, *, `, >,
|, [text](url)) reached the TTS phonemizer verbatim and got read aloud as
literal symbols instead of natural narration."""

from __future__ import annotations

from app.services.text_normalizer import strip_markdown_for_narration


def test_empty_and_none_like_input():
    assert strip_markdown_for_narration("") == ""


def test_headers_are_stripped():
    out = strip_markdown_for_narration("# Chapter One\n\nSome text.")
    assert "#" not in out
    assert "Chapter One" in out
    assert "Some text." in out


def test_bold_and_italic_markers_are_stripped_but_words_kept():
    out = strip_markdown_for_narration(
        "This is **bold** and *italic* and __also bold__ and _also italic_."
    )
    assert "*" not in out
    assert "_" not in out
    assert "bold" in out
    assert "italic" in out
    assert "also bold" in out
    assert "also italic" in out


def test_links_keep_label_drop_url():
    out = strip_markdown_for_narration(
        "See [the docs](https://example.com/x) for more."
    )
    assert "https://example.com" not in out
    assert "[" not in out and "]" not in out and "(" not in out
    assert "the docs" in out


def test_images_keep_alt_text():
    out = strip_markdown_for_narration("![a diagram of the pipeline](img.png)")
    assert "a diagram of the pipeline" in out
    assert ".png" not in out


def test_inline_code_keeps_content_drops_backticks():
    out = strip_markdown_for_narration("Run `make verify` before committing.")
    assert "`" not in out
    assert "make verify" in out


def test_code_fence_block_is_dropped():
    out = strip_markdown_for_narration("Before.\n```python\nprint('hi')\n```\nAfter.")
    assert "```" not in out
    assert "Before." in out
    assert "After." in out


def test_blockquote_marker_stripped():
    out = strip_markdown_for_narration("> This is quoted wisdom.")
    assert not out.startswith(">")
    assert "This is quoted wisdom." in out


def test_horizontal_rule_dropped():
    out = strip_markdown_for_narration("Section one.\n\n---\n\nSection two.")
    assert "---" not in out
    assert "Section one." in out
    assert "Section two." in out


def test_unordered_list_markers_stripped():
    out = strip_markdown_for_narration("- first item\n- second item")
    assert not out.startswith("-")
    assert "first item" in out
    assert "second item" in out


def test_ordered_list_markers_stripped():
    out = strip_markdown_for_narration("1. first item\n2. second item")
    assert "1." not in out
    assert "first item" in out
    assert "second item" in out


def test_pipe_table_pipes_removed_and_separator_row_dropped():
    out = strip_markdown_for_narration("| Name | Age |\n| --- | --- |\n| Alice | 30 |")
    assert "|" not in out
    assert "Name" in out and "Age" in out and "Alice" in out and "30" in out


def test_html_entities_are_unescaped():
    out = strip_markdown_for_narration("Rock &amp; Roll &mdash; it&#39;s loud.")
    assert "&amp;" not in out and "&#39;" not in out and "&mdash;" not in out
    assert "Rock" in out and "Roll" in out


def test_plain_prose_with_no_markdown_is_left_essentially_unchanged():
    text = "This is just a normal sentence. It has punctuation, like this!"
    out = strip_markdown_for_narration(text)
    assert out == text


def test_ordinary_apostrophes_in_contractions_are_preserved():
    out = strip_markdown_for_narration("It's a nice day, isn't it?")
    assert "It's" in out
    assert "isn't" in out


def test_header_immediately_followed_by_text_gets_a_forced_paragraph_break():
    """Source Markdown with no blank line between a heading and its body text
    still reads as two separate paragraphs in the narrated output, matching
    the Gemini cleanup path's script-style formatting."""
    out = strip_markdown_for_narration("# Chapter One\nThe story begins here.")
    assert out.split("\n\n") == ["Chapter One", "The story begins here."]


def test_list_immediately_followed_by_text_gets_a_forced_paragraph_break():
    out = strip_markdown_for_narration("- first item\n- second item\nAfter the list.")
    paragraphs = out.split("\n\n")
    assert len(paragraphs) == 2
    assert "first item" in paragraphs[0]
    assert paragraphs[1] == "After the list."


def test_header_at_end_of_document_has_no_trailing_blank_line():
    out = strip_markdown_for_narration("Intro.\n\n# The End")
    assert out == "Intro.\n\nThe End"
