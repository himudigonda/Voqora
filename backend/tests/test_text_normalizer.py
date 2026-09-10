"""Tests for strip_markdown_for_narration — the local-first (no-Gemini)
audiobook cleanup path's Markdown-to-prose stripping.

Regression coverage for the bug where raw Markdown syntax (#, **, *, `, >,
|, [text](url)) reached the TTS phonemizer verbatim and got read aloud as
literal symbols instead of natural narration."""

from __future__ import annotations

import pytest

from app.services.text_normalizer import (
    has_residual_markup,
    strip_markdown_for_narration,
)


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


# ---------------------------------------------------------------------------
# Gap coverage. Each case below was a real defect: the "before" behavior is
# quoted in the comment so a future change that reintroduces it is obvious.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "name,source,forbidden,required",
    [
        # was: unchanged -- "**" narrated as "asterisk" (the reported bug)
        ("bold across a line break", "This is **bold\ntext** here.", "**", "bold"),
        # was: unchanged -- "=====" narrated as a run of "equals"
        ("setext heading", "My Title\n========\n\nBody.", "=", "My Title"),
        # was: unchanged -- brackets narrated, raw URL read aloud
        (
            "reference link and definition",
            "See [the guide][g].\n\n[g]: https://example.com",
            "[",
            "the guide",
        ),
        # was: unchanged -- "[^1]" narrated as "caret one"
        ("footnote", "Important[^1].\n\n[^1]: The body.", "[^", "The body"),
        # was: "First, [ ] Buy milk." -- checkbox brackets narrated
        ("task list checkbox", "- [ ] Buy milk\n- [x] Walk dog", "[", "Buy milk"),
        # was: unchanged -- "#" narrated as "hash" (the rule required a space)
        ("heading with no space", "#NoSpaceHeading", "#", "NoSpaceHeading"),
        # was: unchanged -- no strikethrough rule existed at all
        ("strikethrough", "This is ~~deleted~~ text.", "~~", "deleted"),
        # was: " --- ---" -- an orphaned separator narrated as "dash dash dash"
        ("orphaned table separator", "| Name | Age |\n| --- | --- |", "|", "Name"),
        # was: "\not italic\" -- markers obeyed, backslashes left behind
        ("escaped emphasis", r"A \*literal\* word.", "*", "literal"),
        # was: only the top level converted; nested "-" narrated as "dash"
        ("nested list item", "- Top\n    - Nested", "-", "Nested"),
        # was: "title: My Doc" narrated as the book's opening sentence
        (
            "yaml front matter",
            "---\ntitle: My Doc\n---\n\nReal body.",
            "title:",
            "Real body",
        ),
        # was: the code body narrated as prose
        (
            "indented code block",
            "Prose.\n\n    def foo():\n        return 1\n\nMore.",
            "def foo",
            "More.",
        ),
    ],
)
def test_markdown_construct_is_not_narratable(name, source, forbidden, required):
    out = strip_markdown_for_narration(source)
    assert forbidden not in out, f"{name}: {forbidden!r} survived in {out!r}"
    assert required in out, f"{name}: content {required!r} was lost from {out!r}"


@pytest.mark.parametrize(
    "name,source,must_survive",
    [
        # Removing too much is the worse failure: a deleted sentence is silent
        # and undetectable, while a spoken "asterisk" announces itself.
        # was: "If x b, stop." -- _HTML_TAG_RE's [^>] also matched newlines, so
        # everything from the first "<" to the next ">" anywhere was deleted.
        (
            "inequalities in prose",
            "If x < y then swap them. Otherwise if a > b, stop.",
            ["swap them", "stop", "<", ">"],
        ),
        (
            "inequalities across paragraphs",
            "Revenue is under < 100 in Q1.\n\nProfit exceeded > 50 in Q2.",
            ["Q1", "Q2", "Profit"],
        ),
        # was: "Use List and Map." -- generic types read as HTML tags
        (
            "generic type syntax",
            "Use List<int> and Map<String, Value> here.",
            ["List<int>", "Map<String, Value>"],
        ),
        # was: "Call getusername and maxretrycount."
        (
            "snake_case identifiers",
            "Call get_user_name and max_retry_count.",
            ["get_user_name", "max_retry_count"],
        ),
        # was: "valuea and valueb" -- the first "_" on a line paired with the
        # nearest later one, merging unrelated tokens.
        (
            "underscores in separate words",
            "value_a and value_b",
            ["value_a", "value_b"],
        ),
        # was: "5 3 and 4 8" -- multiplication operators silently deleted
        ("multiplication signs", "5 * 3 and 4 * 8", ["5 * 3", "4 * 8"]),
        ("contractions", "It's Jane's book, isn't it?", ["It's", "Jane's", "isn't"]),
    ],
)
def test_real_content_is_preserved(name, source, must_survive):
    out = strip_markdown_for_narration(source)
    for fragment in must_survive:
        assert fragment in out, f"{name}: lost {fragment!r} from {out!r}"


@pytest.mark.parametrize(
    "source",
    [
        "## Heading\n\n**Bold** and `code`.",
        "| a | b |\n| --- | --- |\n| 1 | 2 |",
        "- one\n- two\n- three",
        "> quoted line",
        "If x < y then stop.",
        "Call get_user_name here.",
        r"A \*literal\* word.",
        "```python\ncode()\n```\n\nAfter.",
        "---\ntitle: Doc\n---\n\nBody.",
        "Plain prose with nothing to strip.",
    ],
)
def test_strip_is_idempotent(source):
    """f(f(x)) == f(x).

    Load-bearing, not academic: this now runs as a final pass over every
    branch of the audiobook cleaning phase, including branches whose text
    Gemini already cleaned. If a second pass mutated already-clean text, the
    invariant would corrupt exactly the output it is meant to protect.
    """
    once = strip_markdown_for_narration(source)
    assert strip_markdown_for_narration(once) == once


def test_has_residual_markup_flags_markdown_and_clears_on_clean_prose():
    assert has_residual_markup("## Heading with **bold**") != []
    assert has_residual_markup("A clean narration sentence.") == []
    # Must not false-positive on ordinary prose that merely contains symbols.
    assert has_residual_markup("If x < y then stop, and 5 * 3 is 15.") == []


# ---------------------------------------------------------------------------
# Structure. Newlines cost nothing in audio (TTSEngine._split_segments flattens
# them before synthesis), so line structure is purely what the reader sees --
# and joining everything into run-on blocks is what made the transcript
# unreadable.
# ---------------------------------------------------------------------------


def test_list_items_get_one_line_each():
    """Was: all items joined into a single sentence, so a five-item list
    rendered as one dense paragraph blob."""
    out = strip_markdown_for_narration("- alpha\n- beta\n- gamma")
    assert out.split("\n") == [
        "First, alpha.",
        "Second, beta.",
        "Third, gamma.",
    ], out


def test_table_rows_get_one_line_each():
    """Was: the whole table joined into one run-on line."""
    src = "| Tier | Price |\n| --- | --- |\n| Starter | $99 |\n| Pro | $299 |"
    assert strip_markdown_for_narration(src).split("\n") == [
        "The following is a table.",
        "Tier is Starter, Price is $99.",
        "Tier is Pro, Price is $299.",
        "End of table.",
    ]


def test_soft_wrapped_prose_is_rejoined():
    """A source that hard-wraps prose must not show mid-sentence breaks."""
    src = "The mechanism underneath both stories, and the one\nworth understanding, is this."
    out = strip_markdown_for_narration(src)
    assert "\n" not in out, out
    assert "one worth understanding" in out


def test_reflow_does_not_merge_completed_sentences_on_separate_lines():
    """The rule that rejoins soft wraps must not also flatten structure.

    Told apart by how the previous line ends: mid-sentence (a word or comma)
    means a soft wrap, terminal punctuation means a deliberate break.
    """
    src = "First, alpha.\nSecond, beta."
    assert strip_markdown_for_narration(src).split("\n") == [
        "First, alpha.",
        "Second, beta.",
    ]


def test_headings_are_separated_from_surrounding_prose():
    out = strip_markdown_for_narration("Body before.\n## The heading\nBody after.")
    assert out.split("\n") == [
        "Body before.",
        "",
        "The heading",
        "",
        "Body after.",
    ], out


def test_structured_output_survives_a_second_pass():
    """The reflow rule is what keeps this true: a naive 'join consecutive
    lines' would merge the list items this pass just separated."""
    src = "## Title\n\n- alpha\n- beta\n\n| a | b |\n| --- | --- |\n| 1 | 2 |"
    once = strip_markdown_for_narration(src)
    assert strip_markdown_for_narration(once) == once
