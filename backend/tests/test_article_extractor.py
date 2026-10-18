from __future__ import annotations

from pathlib import Path

import pytest

from app.services.article_errors import ArticleError, ArticleFailure
from app.services.article_extractor import (
    MIN_ARTICLE_WORDS,
    extract_html,
    extract_text,
    title_from_url,
)
from app.services.article_reader import audiobook_source, read_article
from app.services.text_extractor import TextExtractor
from app.services.text_normalizer import strip_markdown_for_narration
from app.services.web_fetcher import FetchedPage

FIXTURES = Path(__file__).parent / "fixtures" / "articles"

PROSE = (
    "This sentence carries enough ordinary words to count as real article prose, "
    "with commas, clauses, and a steady rhythm that a reader would expect. "
)


def _fixture(name: str) -> bytes:
    return (FIXTURES / name).read_bytes()


def _page(body: str, head: str = "", attrs: str = "") -> bytes:
    return (
        f"<!doctype html><html {attrs}><head>{head}</head><body>{body}</body></html>"
    ).encode()


def _assert_clean(text: str) -> None:
    leaked = [marker for marker in text.split() if marker.endswith("_TEXT")]
    assert leaked == []


def test_news_article_metadata_and_body() -> None:
    article = extract_html(
        _fixture("news.html"), "https://www.coastalherald.example/news/bridge"
    )

    assert article.title == "Harbour bridge reopens after two years of repairs"
    assert article.byline == "Priya Natarajan"
    assert article.site_name == "The Coastal Herald"
    assert article.language == "en-gb"
    assert article.text.startswith("The harbour bridge reopened to traffic")
    assert "The reopened bridge at dawn on Wednesday." in article.text
    assert "We are proud to give the bridge back" in article.text
    assert article.word_count == len(article.text.split())
    _assert_clean(article.text)
    _assert_clean(article.markdown)


def test_news_markdown_keeps_structure_and_drops_title_duplicate() -> None:
    markdown = extract_html(
        _fixture("news.html"), "https://coastalherald.example/news/bridge"
    ).markdown

    assert markdown.startswith(
        "# Harbour bridge reopens after two years of repairs\n\nBy Priya Natarajan\n"
    )
    assert markdown.count("Harbour bridge reopens after two years") == 1
    assert "\n## A long road to reopening\n" in markdown
    assert "\n> We are proud to give the bridge back" in markdown
    assert "IMG_ALT_TEXT" not in markdown


def test_blog_with_sidebar_layout_keeps_content() -> None:
    article = extract_html(_fixture("blog.html"), "https://mossandfern.example/slow")

    assert article.title == "Notes from a slow garden"
    assert article.site_name == "Moss and Fern"
    assert article.language == "fr"
    assert article.byline is None
    assert "1. Three rows of broad beans along the fence." in article.text
    assert "\n1. Three rows of broad beans along the fence.\n2. A single pumpkin" in (
        article.markdown
    )
    assert "## What I planted anyway" in article.markdown
    assert "## What I would change" in article.markdown
    _assert_clean(article.text)


def test_docs_page_keeps_code_lists_and_tables() -> None:
    article = extract_html(_fixture("docs.html"), "https://sdk.example/docs/retries")

    assert article.title == "Configuring retries"
    assert article.site_name == "Widget SDK"
    assert '```\nclient = Client(retries=3)\nclient.get("/status")\n```' in (
        article.markdown
    )
    assert 'client = Client(retries=3)\nclient.get("/status")' in article.text
    assert "### Options" in article.markdown
    assert "- retries: the maximum number of attempts" in article.markdown
    assert "retries: the maximum number of attempts" in article.text
    assert "Option; Default" in article.text
    assert "backoff; 0.5" in article.text
    _assert_clean(article.text)


def test_heavy_chrome_page_keeps_only_the_recipe() -> None:
    article = extract_html(
        _fixture("heavy_chrome.html"), "https://www.soups.example/lentil"
    )

    assert article.title == "The only lentil soup recipe you need"
    assert article.site_name == "soups.example"
    assert article.language == "es"
    assert article.text.startswith("Lentil soup is the kind of dish")
    assert article.text.endswith("best part of the whole meal.")
    _assert_clean(article.text)
    assert "Accept" not in article.text


def test_paywalled_page_is_reported_as_paywalled() -> None:
    with pytest.raises(ArticleError) as error:
        extract_html(_fixture("paywall.html"), "https://finance.example/markets")
    assert error.value.code is ArticleFailure.PAYWALLED


def test_paywall_class_marker_is_detected() -> None:
    document = _page('<article><p>Short teaser.</p><div class="paywall"></div>')
    with pytest.raises(ArticleError) as error:
        extract_html(document, "https://a.example/")
    assert error.value.code is ArticleFailure.PAYWALLED


def test_paywall_marker_does_not_block_a_full_article() -> None:
    body = f"<article><p>{PROSE * 5}</p></article><div class='premium-upsell'></div>"
    article = extract_html(_page(body), "https://a.example/")
    assert article.word_count > MIN_ARTICLE_WORDS


@pytest.mark.parametrize(
    "document",
    [
        b"",
        b"   ",
        b"<html></html>",
        _page("<nav><a href='/'>Home</a></nav><footer>Bye</footer>"),
        _page("<p>Too short.</p>"),
        _page("<script>var article = 'not text';</script>"),
    ],
)
def test_pages_without_readable_text_are_rejected(document: bytes) -> None:
    with pytest.raises(ArticleError) as error:
        extract_html(document, "https://a.example/")
    assert error.value.code is ArticleFailure.NO_READABLE_CONTENT


def test_title_falls_back_through_title_tag_and_h1() -> None:
    url = "https://a.example/"
    with_tag = _page(f"<p>{PROSE * 3}</p>", "<title>Plain Title | Site</title>")
    assert extract_html(with_tag, url).title == "Plain Title | Site"

    with_site = _page(
        f"<p>{PROSE * 3}</p>",
        "<title>Site :: Plain Title</title><meta property='og:site_name' content='Site'>",
    )
    assert extract_html(with_site, url).title == "Plain Title"

    with_h1 = _page(f"<h1>Heading Title</h1><p>{PROSE * 3}</p>")
    article = extract_html(with_h1, url)
    assert article.title == "Heading Title"
    assert "Heading Title" not in article.text

    bare = _page(f"<p>{PROSE * 3}</p>")
    assert extract_html(bare, "https://www.bare.example/x").title == "bare.example"


@pytest.mark.parametrize(
    ("attrs", "head", "expected"),
    [
        ('lang="pt_BR"', "", "pt-br"),
        ('xml:lang="it"', "", "it"),
        ("", '<meta property="og:locale" content="hi_IN">', "hi-in"),
        ('lang="not a language!"', "", None),
        ('lang=""', "", None),
        ("", "", None),
    ],
)
def test_language_is_normalized_from_html_lang(
    attrs: str, head: str, expected: str | None
) -> None:
    article = extract_html(_page(f"<p>{PROSE * 3}</p>", head, attrs), "https://a/")
    assert article.language == expected


@pytest.mark.parametrize(
    ("head", "body", "expected"),
    [
        ('<meta name="author" content="By Sam Lee">', "", "Sam Lee"),
        (
            '<meta property="article:author" content="https://a.example/sam">',
            '<span rel="author">Written by Ana Ruiz</span>',
            "Ana Ruiz",
        ),
        ('<meta property="article:author" content="Kim Park">', "", "Kim Park"),
        ("", '<span itemprop="author">Lou Reed</span>', "Lou Reed"),
        ("", "", None),
    ],
)
def test_byline_sources(head: str, body: str, expected: str | None) -> None:
    document = _page(f"{body}<p>{PROSE * 3}</p>", head)
    assert extract_html(document, "https://a.example/").byline == expected


def test_declared_charset_is_honoured() -> None:
    body = f"<p>Café crème. {PROSE * 3}</p>"
    document = _page(body).replace(b"<head>", b"<head><meta charset='latin-1'>")
    latin = document.decode().encode("latin-1")
    assert "Café crème." in extract_html(latin, "https://a/").text
    assert "Café" in extract_html(latin, "https://a/", "iso-8859-1").text
    assert extract_html(_page(body), "https://a/", "no-such-codec").word_count > 0


def test_hidden_and_interactive_elements_are_removed() -> None:
    body = (
        f"<div class='main-col'><p>{PROSE * 3}</p>"
        "<p hidden>HIDDEN_TEXT</p><p aria-hidden='true'>ARIA_TEXT</p>"
        "<p style='visibility: hidden'>STYLE_TEXT</p>"
        "<form><input value='INPUT_TEXT'><textarea>AREA_TEXT</textarea></form>"
        "<svg><text>SVG_TEXT</text></svg><template><p>TEMPLATE_TEXT</p></template>"
        "<noscript>NOSCRIPT_TEXT</noscript></div>"
    )
    _assert_clean(extract_html(_page(body), "https://a/").text)


def test_link_heavy_blocks_inside_content_are_dropped() -> None:
    body = (
        "<article>"
        f"<p>{PROSE * 3}</p>"
        "<ul><li><a href='/1'>LINK_TEXT one</a></li><li><a href='/2'>two</a></li></ul>"
        "<p><a href='/more'>LINKONLY_TEXT read more</a></p>"
        "<ul><li>Plain item with <a href='/x'>a</a> short link inside it</li></ul>"
        "</article>"
    )
    article = extract_html(_page(body), "https://a/")
    _assert_clean(article.text)
    assert "Plain item with a short link inside it" in article.text


def test_line_breaks_split_paragraphs_in_layout_tables() -> None:
    body = (
        "<table><tr><td><font>"
        f"{PROSE * 2}<br><br>{PROSE * 2}<br>Still the second paragraph."
        "</font></td></tr></table>"
    )
    article = extract_html(_page(body), "https://essays.example/e.html")
    paragraphs = article.text.split("\n\n")
    assert len(paragraphs) == 2
    assert paragraphs[1].endswith("\nStill the second paragraph.")


def test_scored_content_merges_sibling_paragraphs() -> None:
    body = (
        "<div id='wrap'>"
        f"<div class='part'><p>{PROSE * 2}</p><p>{PROSE}</p></div>"
        f"<p>Sibling paragraph that continues the story with plenty of words, {PROSE}</p>"
        "<div class='x'><p>tiny</p></div>"
        "</div>"
    )
    article = extract_html(_page(body), "https://a/")
    assert "Sibling paragraph that continues the story" in article.text


def test_markdown_escapes_text_that_would_become_structure() -> None:
    body = (
        f"<article><p>{PROSE * 3}</p>"
        "<p># not a heading but a hashtag line</p>"
        "<p>- not a list</p><p>12. not ordered</p>"
        "<p>&gt; not a quote</p><p>| not | a table</p><p>``` not a fence</p>"
        "<pre>uses ``` inside</pre>"
        "</article>"
    )
    markdown = extract_html(_page(body), "https://a/").markdown
    assert "\n\\# not a heading" in markdown
    assert "\n\\- not a list" in markdown
    assert "\n12\\. not ordered" in markdown
    assert "\n\\> not a quote" in markdown
    assert "\n\\| not | a table" in markdown
    assert "\n\\``` not a fence" in markdown
    assert "~~~\nuses ``` inside\n~~~" in markdown
    narrated = strip_markdown_for_narration(markdown)
    assert "not a heading but a hashtag line" in narrated
    assert "12. not ordered" in narrated


def test_markdown_headings_become_audiobook_sections(tmp_path) -> None:
    article = extract_html(_fixture("news.html"), "https://a.example/")
    source = tmp_path / "source.md"
    source.write_text(article.markdown, encoding="utf-8")
    titles = [heading["title"] for heading in TextExtractor.read_outline(str(source))]
    assert titles == [
        "Harbour bridge reopens after two years of repairs",
        "A long road to reopening",
    ]


def test_ordered_list_start_attribute() -> None:
    body = (
        f"<article><p>{PROSE * 3}</p><ol start='4'><li>four</li><li>five</li></ol>"
        "<ol start='bad'><li>one</li></ol></article>"
    )
    markdown = extract_html(_page(body), "https://a/").markdown
    assert "4. four\n5. five" in markdown
    assert "\n1. one" in markdown


def test_rules_and_stray_list_children_split_blocks() -> None:
    body = (
        f"<article><p>{PROSE * 3}</p>"
        "<div>before rule<hr>after rule</div>"
        "<ul><li>real item</li><div>stray child</div></ul>"
        "</article>"
    )
    article = extract_html(_page(body), "https://a/")
    assert "before rule\n\nafter rule" in article.text
    assert "- real item\n\nstray child" in article.markdown


def test_multi_paragraph_list_items_are_marked_once() -> None:
    body = (
        f"<article><p>{PROSE * 3}</p>"
        "<ul><li><p>First part of item.</p><p>Second part of item.</p></li></ul>"
        "</article>"
    )
    markdown = extract_html(_page(body), "https://a/").markdown
    assert "- First part of item.\n\nSecond part of item." in markdown


def test_deep_nesting_is_flattened_not_recursed() -> None:
    body = (
        f"<article><p>{PROSE * 3}</p>"
        + "<div>" * 230
        + "<p>Deeply nested closing words.</p>"
        + "</div>" * 230
        + "</article>"
    )
    article = extract_html(_page(body), "https://a/")
    assert article.text.endswith("Deeply nested closing words.")


def test_pathological_nesting_fails_cleanly() -> None:
    body = "<div>" * 3000 + f"<p>{PROSE * 3}</p>" + "</div>" * 3000
    with pytest.raises(ArticleError) as error:
        extract_html(_page(body), "https://a/")
    assert error.value.code is ArticleFailure.NO_READABLE_CONTENT


def test_plain_text_documents() -> None:
    text = f"{PROSE * 2}\n\n\n{PROSE}\r\nwrapped line\n# looks like a heading".encode()
    article = extract_text(text, "https://a.example/files/field-notes_2026.txt")
    assert article.title == "field notes 2026"
    assert article.site_name == "a.example"
    assert article.language is None
    assert article.text.count("\n\n") == 1
    assert "\\# looks like a heading" in article.markdown
    assert article.markdown.startswith("# field notes 2026\n\n")


def test_plain_text_charset_and_short_text() -> None:
    latin = f"Café {PROSE * 3}".encode("latin-1")
    assert extract_text(latin, "https://a/", "latin-1").text.startswith("Café")
    with pytest.raises(ArticleError) as error:
        extract_text(b"tiny", "https://a/")
    assert error.value.code is ArticleFailure.NO_READABLE_CONTENT


@pytest.mark.parametrize(
    ("url", "expected"),
    [
        ("https://a.example/papers/On%20Rates.pdf", "On Rates"),
        ("https://www.a.example/", "a.example"),
        ("https://a.example/reports/2026/", "2026"),
    ],
)
def test_title_from_url(url: str, expected: str) -> None:
    assert title_from_url(url) == expected


def _fetched(kind: str, body: bytes, url: str = "https://a.example/doc") -> FetchedPage:
    return FetchedPage(url=url, kind=kind, body=body, charset=None)


def test_reader_routes_pages_by_kind() -> None:
    html = _fetched("html", _fixture("news.html"))
    assert read_article(html).title.startswith("Harbour bridge")
    source = audiobook_source(html)
    assert source.file_ext == "md"
    assert source.content.decode().startswith("# Harbour bridge")

    text = _fetched("text", (PROSE * 3).encode(), "https://a.example/notes.txt")
    assert audiobook_source(text).file_ext == "txt"
    assert audiobook_source(text).title == "notes"

    pdf = _fetched("pdf", b"%PDF-1.4 body", "https://a.example/Annual%20Report.pdf")
    assert audiobook_source(pdf).file_ext == "pdf"
    assert audiobook_source(pdf).title == "Annual Report"
    assert audiobook_source(pdf).content == b"%PDF-1.4 body"
    with pytest.raises(ArticleError) as error:
        read_article(pdf)
    assert error.value.code is ArticleFailure.PDF_DOCUMENT
