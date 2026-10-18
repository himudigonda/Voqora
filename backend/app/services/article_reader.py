"""Turn a fetched web page into a readable article or an audiobook source file."""

from __future__ import annotations

from dataclasses import dataclass

from app.services.article_errors import ArticleError, ArticleFailure
from app.services.article_extractor import (
    Article,
    extract_html,
    extract_text,
    title_from_url,
)
from app.services.web_fetcher import FetchedPage


@dataclass(frozen=True)
class AudiobookSource:
    file_ext: str
    title: str
    content: bytes
    author: str | None = None


def read_article(page: FetchedPage) -> Article:
    if page.kind == "pdf":
        raise ArticleError(
            ArticleFailure.PDF_DOCUMENT,
            "This link is a PDF. Add it to Library as an audiobook instead.",
        )
    if page.kind == "text":
        return extract_text(page.body, page.url, page.charset)
    return extract_html(page.body, page.url, page.charset)


def audiobook_source(page: FetchedPage) -> AudiobookSource:
    if page.kind == "pdf":
        return AudiobookSource("pdf", title_from_url(page.url), page.body)
    article = read_article(page)
    if page.kind == "text":
        return AudiobookSource(
            "txt", article.title, article.text.encode("utf-8"), article.byline
        )
    return AudiobookSource(
        "md", article.title, article.markdown.encode("utf-8"), article.byline
    )
