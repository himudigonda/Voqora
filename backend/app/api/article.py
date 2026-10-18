"""Web article HTTP surface: readable text from a link or from a page's HTML."""

import asyncio
from collections.abc import Callable
from typing import TypeVar

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from app.core.logging import get_logger
from app.services.article_errors import ArticleError, ArticleFailure
from app.services.article_extractor import Article, extract_html
from app.services.article_reader import read_article
from app.services.url_guard import MAX_URL_CHARS, parse_web_url
from app.services.web_fetcher import FetchedPage, WebFetcher, web_fetcher

router = APIRouter()
log = get_logger(__name__)

MAX_ARTICLE_HTML_BYTES = 5 * 1024 * 1024

_T = TypeVar("_T")

ARTICLE_ERROR_STATUS: dict[ArticleFailure, int] = {
    ArticleFailure.INVALID_URL: 422,
    ArticleFailure.BLOCKED_ADDRESS: 403,
    ArticleFailure.UNREACHABLE: 502,
    ArticleFailure.TIMEOUT: 504,
    ArticleFailure.TOO_MANY_REDIRECTS: 502,
    ArticleFailure.HTTP_ERROR: 502,
    ArticleFailure.NOT_FOUND: 502,
    ArticleFailure.PAYWALLED: 422,
    ArticleFailure.UNSUPPORTED_TYPE: 415,
    ArticleFailure.PDF_DOCUMENT: 415,
    ArticleFailure.TOO_LARGE: 413,
    ArticleFailure.NO_READABLE_CONTENT: 422,
    ArticleFailure.BUSY: 429,
}


class ArticleURLRequest(BaseModel):
    url: str = Field(min_length=1, max_length=MAX_URL_CHARS)


class ArticleHTMLRequest(BaseModel):
    url: str = Field(min_length=1, max_length=MAX_URL_CHARS)
    html: str = Field(min_length=1, max_length=MAX_ARTICLE_HTML_BYTES)


class ArticleResponse(BaseModel):
    url: str
    title: str
    byline: str | None
    site_name: str | None
    language: str | None
    text: str
    markdown: str
    word_count: int


def article_error_response(error: ArticleError) -> JSONResponse:
    return JSONResponse(
        status_code=ARTICLE_ERROR_STATUS[error.code],
        content={"detail": error.message, "code": error.code.value},
    )


async def run_reader(reader: Callable[..., _T], *args: object) -> _T:
    try:
        return await asyncio.get_running_loop().run_in_executor(None, reader, *args)
    except ArticleError:
        raise
    except Exception as exc:
        log.warning(
            "article.extract_failed",
            extra={"failure_code": "article_extract_failed"},
            exc_info=True,
        )
        raise ArticleError(
            ArticleFailure.NO_READABLE_CONTENT,
            "Voqora couldn't read this page.",
        ) from exc


def _response(article: Article, url: str) -> ArticleResponse:
    return ArticleResponse(
        url=url,
        title=article.title,
        byline=article.byline,
        site_name=article.site_name,
        language=article.language,
        text=article.text,
        markdown=article.markdown,
        word_count=article.word_count,
    )


async def _read_link(fetcher: WebFetcher, url: str) -> tuple[FetchedPage, Article]:
    page = await fetcher.fetch(url)
    return page, await run_reader(read_article, page)


@router.post("/article/extract", response_model=ArticleResponse)
async def extract_article(
    body: ArticleURLRequest, fetcher: WebFetcher = Depends(web_fetcher)
):
    """Fetch a public web page and return its readable article text."""
    try:
        page, article = await _read_link(fetcher, body.url)
    except ArticleError as error:
        return article_error_response(error)
    log.info("article.extracted", extra={"word_count": article.word_count})
    return _response(article, page.url)


@router.post("/article/extract-html", response_model=ArticleResponse)
async def extract_article_html(body: ArticleHTMLRequest):
    """Return the readable article from HTML the client already has. No fetch."""
    try:
        url = str(parse_web_url(body.url))
        document = body.html.encode("utf-8", errors="replace")
        if len(document) > MAX_ARTICLE_HTML_BYTES:
            raise ArticleError(
                ArticleFailure.TOO_LARGE,
                f"This page is larger than {MAX_ARTICLE_HTML_BYTES // (1024 * 1024)} MB.",
            )
        article = await run_reader(extract_html, document, url, "utf-8")
    except ArticleError as error:
        return article_error_response(error)
    log.info("article.extracted", extra={"word_count": article.word_count})
    return _response(article, url)
