"""Bounded, SSRF-safe download of a single public web page."""

from __future__ import annotations

import asyncio
import zlib
from dataclasses import dataclass
from typing import Literal, Protocol

import httpx

from app.core.config import settings
from app.core.logging import get_logger
from app.services.article_errors import ArticleError, ArticleFailure
from app.services.url_guard import (
    Resolver,
    parse_web_url,
    resolve_public_address,
    system_resolver,
)

log = get_logger(__name__)

PageKind = Literal["html", "text", "pdf"]

FETCH_TIMEOUT_SECONDS = 15.0
MAX_PAGE_BYTES = 10 * 1024 * 1024
MAX_REDIRECTS = 5
MAX_CONCURRENT_FETCHES = 4

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    f"(KHTML, like Gecko) Version/18.0 Safari/605.1.15 Voqora/{settings.VERSION}"
)
_ACCEPT = (
    "text/html,application/xhtml+xml,text/plain;q=0.9,application/pdf;q=0.8,"
    "*/*;q=0.1"
)
_REDIRECT_STATUSES = frozenset({301, 302, 303, 307, 308})
_PAYWALL_STATUSES = frozenset({401, 402, 403})
_KINDS: dict[str, PageKind] = {
    "text/html": "html",
    "application/xhtml+xml": "html",
    "text/plain": "text",
    "application/pdf": "pdf",
    "application/x-pdf": "pdf",
}
_SNIFFED_TYPES = frozenset({"", "application/octet-stream"})
_PDF_MAGIC = b"%PDF-"
_DECODE_STEP = 64 * 1024

_TOO_LARGE = f"This page is larger than {MAX_PAGE_BYTES // (1024 * 1024)} MB."
_UNSUPPORTED = "Voqora can read web pages, plain text, and PDFs from a link."


@dataclass(frozen=True)
class FetchedPage:
    url: str
    kind: PageKind
    body: bytes
    charset: str | None


@dataclass(frozen=True)
class _ContentType:
    mime: str
    charset: str | None


def _content_type(header: str) -> _ContentType:
    mime, *params = header.split(";")
    charset = None
    for param in params:
        name, _, value = param.partition("=")
        if name.strip().lower() == "charset" and value.strip():
            charset = value.strip().strip("\"'").lower()[:40] or None
    return _ContentType(mime.strip().lower(), charset)


class _Inflater(Protocol):
    unconsumed_tail: bytes

    def decompress(self, data: bytes, max_length: int = 0, /) -> bytes: ...


class _BoundedDecoder:
    def __init__(self, encoding: str, limit: int) -> None:
        self._limit = limit
        self._size = 0
        self._chunks: list[bytes] = []
        self._inflater = self._inflater_for(encoding)

    @staticmethod
    def _inflater_for(encoding: str) -> _Inflater | None:
        if encoding in {"", "identity"}:
            return None
        if encoding in {"gzip", "x-gzip", "deflate"}:
            return zlib.decompressobj(zlib.MAX_WBITS | 32)
        raise ArticleError(ArticleFailure.UNSUPPORTED_TYPE, _UNSUPPORTED)

    def feed(self, data: bytes) -> None:
        if self._inflater is None:
            self._append(data)
            return
        pending = data
        while pending:
            try:
                out = self._inflater.decompress(pending, _DECODE_STEP)
            except zlib.error as exc:
                raise ArticleError(
                    ArticleFailure.HTTP_ERROR, "The website sent a damaged page."
                ) from exc
            self._append(out)
            pending = self._inflater.unconsumed_tail

    def _append(self, data: bytes) -> None:
        self._size += len(data)
        if self._size > self._limit:
            raise ArticleError(ArticleFailure.TOO_LARGE, _TOO_LARGE)
        self._chunks.append(data)

    def result(self) -> bytes:
        return b"".join(self._chunks)


class WebFetcher:
    _active = 0

    def __init__(
        self,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
        resolver: Resolver = system_resolver,
        timeout_seconds: float = FETCH_TIMEOUT_SECONDS,
        max_bytes: int = MAX_PAGE_BYTES,
        max_redirects: int = MAX_REDIRECTS,
    ) -> None:
        self._transport = transport
        self._resolver = resolver
        self._timeout_seconds = timeout_seconds
        self._max_bytes = max_bytes
        self._max_redirects = max_redirects

    async def fetch(self, raw_url: str) -> FetchedPage:
        url = parse_web_url(raw_url)
        if WebFetcher._active >= MAX_CONCURRENT_FETCHES:
            raise ArticleError(
                ArticleFailure.BUSY,
                "Voqora is already reading several pages. Try again in a moment.",
            )
        WebFetcher._active += 1
        try:
            async with asyncio.timeout(self._timeout_seconds):
                return await self._follow(url)
        except TimeoutError as exc:
            raise self._timed_out() from exc
        finally:
            WebFetcher._active -= 1

    @staticmethod
    def _timed_out() -> ArticleError:
        log.info("article.fetch_failed", extra={"failure_code": "fetch_timeout"})
        return ArticleError(
            ArticleFailure.TIMEOUT, "The website took too long to respond."
        )

    def _client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            transport=self._transport,
            timeout=httpx.Timeout(self._timeout_seconds),
            follow_redirects=False,
            trust_env=False,
            limits=httpx.Limits(max_keepalive_connections=0),
        )

    async def _follow(self, url: httpx.URL) -> FetchedPage:
        async with self._client() as client:
            for _ in range(self._max_redirects + 1):
                request = await self._pinned_request(url)
                response = await self._send(client, request)
                try:
                    location = self._redirect_target(response)
                    if location is None:
                        return await self._read(url, response)
                finally:
                    await response.aclose()
                url = parse_web_url(str(url.join(location)))
        log.info("article.fetch_failed", extra={"failure_code": "too_many_redirects"})
        raise ArticleError(
            ArticleFailure.TOO_MANY_REDIRECTS, "The website redirected too many times."
        )

    async def _pinned_request(self, url: httpx.URL) -> httpx.Request:
        address = await resolve_public_address(url, self._resolver)
        extensions: dict[str, str] = {}
        if url.scheme == "https":
            extensions["sni_hostname"] = url.raw_host.decode("ascii")
        return httpx.Request(
            "GET",
            url.copy_with(host=str(address)),
            headers={
                "Host": url.netloc.decode("ascii"),
                "User-Agent": USER_AGENT,
                "Accept": _ACCEPT,
                "Accept-Encoding": "identity",
            },
            extensions=extensions,
        )

    @staticmethod
    async def _send(
        client: httpx.AsyncClient, request: httpx.Request
    ) -> httpx.Response:
        try:
            return await client.send(request, stream=True)
        except httpx.TimeoutException as exc:
            raise WebFetcher._timed_out() from exc
        except httpx.HTTPError as exc:
            log.info(
                "article.fetch_failed",
                extra={"failure_code": "fetch_unreachable"},
            )
            raise ArticleError(
                ArticleFailure.UNREACHABLE,
                "Voqora couldn't connect to that website.",
            ) from exc

    @staticmethod
    def _redirect_target(response: httpx.Response) -> str | None:
        if response.status_code not in _REDIRECT_STATUSES:
            return None
        location = response.headers.get("location", "").strip()
        if not location:
            raise ArticleError(
                ArticleFailure.HTTP_ERROR, "The website sent a broken redirect."
            )
        return location

    async def _read(self, url: httpx.URL, response: httpx.Response) -> FetchedPage:
        self._raise_for_status(response.status_code)
        content_type = _content_type(response.headers.get("content-type", ""))
        if content_type.mime not in _KINDS and content_type.mime not in _SNIFFED_TYPES:
            raise ArticleError(ArticleFailure.UNSUPPORTED_TYPE, _UNSUPPORTED)
        self._check_declared_length(response)
        body = await self._read_body(response)
        return FetchedPage(
            url=str(url),
            kind=self._kind(content_type.mime, body),
            body=body,
            charset=content_type.charset,
        )

    @staticmethod
    def _raise_for_status(status: int) -> None:
        if 200 <= status < 300:
            return
        log.info(
            "article.fetch_failed",
            extra={"failure_code": "fetch_http_status", "status": status},
        )
        if status in _PAYWALL_STATUSES:
            raise ArticleError(
                ArticleFailure.PAYWALLED,
                "This page needs a sign-in or subscription, so Voqora can't read it.",
            )
        if status in {404, 410}:
            raise ArticleError(
                ArticleFailure.NOT_FOUND, "The website says this page doesn't exist."
            )
        raise ArticleError(
            ArticleFailure.HTTP_ERROR,
            f"The website returned an error (HTTP {status}).",
        )

    def _check_declared_length(self, response: httpx.Response) -> None:
        try:
            declared = int(response.headers.get("content-length", "0"))
        except ValueError:
            return
        if declared > self._max_bytes:
            raise ArticleError(ArticleFailure.TOO_LARGE, _TOO_LARGE)

    async def _read_body(self, response: httpx.Response) -> bytes:
        encoding = response.headers.get("content-encoding", "").strip().lower()
        decoder = _BoundedDecoder(encoding, self._max_bytes)
        try:
            async for chunk in response.aiter_raw():
                decoder.feed(chunk)
        except httpx.TimeoutException as exc:
            raise self._timed_out() from exc
        except httpx.HTTPError as exc:
            raise ArticleError(
                ArticleFailure.UNREACHABLE, "The connection to the website dropped."
            ) from exc
        return decoder.result()

    @staticmethod
    def _kind(mime: str, body: bytes) -> PageKind:
        if mime in _KINDS:
            return _KINDS[mime]
        if body.startswith(_PDF_MAGIC):
            return "pdf"
        raise ArticleError(ArticleFailure.UNSUPPORTED_TYPE, _UNSUPPORTED)


def web_fetcher() -> WebFetcher:
    return WebFetcher()
