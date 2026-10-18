from __future__ import annotations

import asyncio
import gzip
import zlib
from collections.abc import AsyncIterator, Callable

import httpx
import pytest

from app.services.article_errors import ArticleError, ArticleFailure
from app.services.web_fetcher import (
    MAX_CONCURRENT_FETCHES,
    USER_AGENT,
    WebFetcher,
    web_fetcher,
)

PUBLIC_IP = "93.184.216.34"
HTML = b"<html><body><p>Hello</p></body></html>"

Handler = Callable[[httpx.Request], httpx.Response]


def _resolver(table: dict[str, list[str]] | None = None):
    calls: list[str] = []

    async def resolve(host: str, port: int) -> list[str]:
        calls.append(host)
        if table is not None and host in table:
            return table[host]
        return [PUBLIC_IP]

    return resolve, calls


async def _chunks(body: bytes) -> AsyncIterator[bytes]:
    for start in range(0, len(body), 4096):
        yield body[start : start + 4096]


def _streamed(response: httpx.Response) -> httpx.Response:
    if not isinstance(response.stream, httpx.ByteStream):
        return response
    return httpx.Response(
        response.status_code,
        headers=response.headers,
        content=_chunks(b"".join(response.stream)),
    )


def _fetcher(handler: Handler, table: dict[str, list[str]] | None = None, **kwargs):
    seen: list[httpx.Request] = []

    def record(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return _streamed(handler(request))

    resolve, calls = _resolver(table)
    fetcher = WebFetcher(
        transport=httpx.MockTransport(record), resolver=resolve, **kwargs
    )
    return fetcher, seen, calls


def _html(_request: httpx.Request) -> httpx.Response:
    return httpx.Response(
        200, content=HTML, headers={"content-type": "text/html; charset=UTF-8"}
    )


def _fetch(fetcher: WebFetcher, url: str):
    return asyncio.run(fetcher.fetch(url))


def _failure(fetcher: WebFetcher, url: str) -> ArticleError:
    with pytest.raises(ArticleError) as error:
        _fetch(fetcher, url)
    return error.value


def test_fetch_html_pins_the_validated_address() -> None:
    fetcher, seen, calls = _fetcher(_html)
    page = _fetch(fetcher, "https://news.example/story?id=7#top")

    assert page.kind == "html"
    assert page.body == HTML
    assert page.charset == "utf-8"
    assert page.url == "https://news.example/story?id=7"
    assert calls == ["news.example"]
    request = seen[0]
    assert request.url.host == PUBLIC_IP
    assert request.url.path == "/story"
    assert request.headers["host"] == "news.example"
    assert request.extensions["sni_hostname"] == "news.example"
    assert request.headers["user-agent"] == USER_AGENT
    assert "Voqora/" in USER_AGENT
    assert request.headers["accept-encoding"] == "identity"


def test_plain_http_has_no_sni_and_keeps_port_in_host_header() -> None:
    fetcher, seen, _ = _fetcher(_html)
    _fetch(fetcher, "http://news.example:8080/a")
    request = seen[0]
    assert "sni_hostname" not in request.extensions
    assert request.headers["host"] == "news.example:8080"
    assert request.url.port == 8080


def test_ipv6_answer_is_pinned_in_brackets() -> None:
    fetcher, seen, _ = _fetcher(_html, {"v6.example": ["2606:4700:4700::1111"]})
    _fetch(fetcher, "https://v6.example/")
    assert seen[0].url.host == "2606:4700:4700::1111"
    assert seen[0].headers["host"] == "v6.example"


def test_dns_rebinding_cannot_change_the_connected_address() -> None:
    answers = iter([[PUBLIC_IP], ["127.0.0.1"]])

    async def rebinding(host: str, port: int) -> list[str]:
        return next(answers)

    seen: list[httpx.Request] = []

    def record(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return _streamed(_html(request))

    fetcher = WebFetcher(transport=httpx.MockTransport(record), resolver=rebinding)
    _fetch(fetcher, "https://rebind.example/")
    assert [request.url.host for request in seen] == [PUBLIC_IP]


@pytest.mark.parametrize(
    "url",
    [
        "http://127.0.0.1/",
        "http://[::1]:8000/",
        "http://169.254.169.254/latest/meta-data/",
        "http://192.168.1.1/admin",
        "http://[::ffff:10.0.0.1]/",
    ],
)
def test_blocked_literal_addresses_never_reach_the_network(url: str) -> None:
    fetcher, seen, _ = _fetcher(_html)
    assert _failure(fetcher, url).code is ArticleFailure.BLOCKED_ADDRESS
    assert seen == []


def test_hostname_resolving_to_private_address_is_blocked() -> None:
    fetcher, seen, _ = _fetcher(_html, {"intranet.example": ["10.0.0.5"]})
    assert (
        _failure(fetcher, "https://intranet.example/").code
        is ArticleFailure.BLOCKED_ADDRESS
    )
    assert seen == []


def test_invalid_url_is_rejected_before_any_work() -> None:
    fetcher, seen, calls = _fetcher(_html)
    assert _failure(fetcher, "ftp://example.com/").code is ArticleFailure.INVALID_URL
    assert seen == [] and calls == []


def _redirect(location: str, status: int = 302) -> httpx.Response:
    return httpx.Response(status, headers={"location": location})


def test_redirects_are_followed_and_each_hop_is_revalidated() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.headers["host"] == "short.example":
            return _redirect("https://news.example/full")
        if request.url.path == "/full":
            return _redirect("/final", 301)
        return _html(request)

    fetcher, seen, calls = _fetcher(handler)
    page = _fetch(fetcher, "http://short.example/x")
    assert page.url == "https://news.example/final"
    assert calls == ["short.example", "news.example", "news.example"]
    assert [request.headers["host"] for request in seen] == [
        "short.example",
        "news.example",
        "news.example",
    ]


@pytest.mark.parametrize(
    "location",
    [
        "http://127.0.0.1/admin",
        "http://[::1]/",
        "http://internal.example/",
        "http://169.254.169.254/latest/meta-data/",
    ],
)
def test_redirect_to_blocked_address_is_refused(location: str) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.headers["host"] == "public.example":
            return _redirect(location)
        raise AssertionError("blocked hop must not be requested")

    fetcher, seen, _ = _fetcher(handler, {"internal.example": ["192.168.0.10"]})
    assert (
        _failure(fetcher, "https://public.example/").code
        is ArticleFailure.BLOCKED_ADDRESS
    )
    assert len(seen) == 1


def test_redirect_to_unsupported_scheme_is_invalid() -> None:
    fetcher, _, _ = _fetcher(lambda _r: _redirect("file:///etc/passwd"))
    assert _failure(fetcher, "https://a.example/").code is ArticleFailure.INVALID_URL


def test_redirect_with_credentials_is_invalid() -> None:
    fetcher, _, _ = _fetcher(lambda _r: _redirect("https://user:pw@b.example/"))
    assert _failure(fetcher, "https://a.example/").code is ArticleFailure.INVALID_URL


def test_redirect_limit_is_enforced() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        hop = int(request.url.path.strip("/") or 0)
        return _redirect(f"/{hop + 1}")

    fetcher, seen, _ = _fetcher(handler)
    error = _failure(fetcher, "https://loop.example/0")
    assert error.code is ArticleFailure.TOO_MANY_REDIRECTS
    assert len(seen) == 6


def test_five_redirects_are_allowed() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        hop = int(request.url.path.strip("/") or 0)
        return _redirect(f"/{hop + 1}") if hop < 5 else _html(request)

    fetcher, seen, _ = _fetcher(handler)
    assert _fetch(fetcher, "https://chain.example/0").url.endswith("/5")
    assert len(seen) == 6


def test_redirect_without_location_is_an_error() -> None:
    fetcher, _, _ = _fetcher(lambda _r: httpx.Response(302))
    assert _failure(fetcher, "https://a.example/").code is ArticleFailure.HTTP_ERROR


@pytest.mark.parametrize(
    ("status", "code"),
    [
        (401, ArticleFailure.PAYWALLED),
        (402, ArticleFailure.PAYWALLED),
        (403, ArticleFailure.PAYWALLED),
        (404, ArticleFailure.NOT_FOUND),
        (410, ArticleFailure.NOT_FOUND),
        (500, ArticleFailure.HTTP_ERROR),
        (503, ArticleFailure.HTTP_ERROR),
        (304, ArticleFailure.HTTP_ERROR),
    ],
)
def test_upstream_status_codes_map_to_clear_errors(
    status: int, code: ArticleFailure
) -> None:
    fetcher, _, _ = _fetcher(lambda _r: httpx.Response(status, content=b"nope"))
    error = _failure(fetcher, "https://a.example/")
    assert error.code is code
    assert "nope" not in error.message


@pytest.mark.parametrize(
    ("content_type", "kind"),
    [
        ("text/html", "html"),
        ("application/xhtml+xml; charset=utf-8", "html"),
        ("TEXT/PLAIN; charset=ISO-8859-1", "text"),
        ("application/pdf", "pdf"),
        ("application/x-pdf", "pdf"),
    ],
)
def test_supported_content_types(content_type: str, kind: str) -> None:
    body = b"%PDF-1.4 x" if kind == "pdf" else b"hello"
    fetcher, _, _ = _fetcher(
        lambda _r: httpx.Response(
            200, content=body, headers={"content-type": content_type}
        )
    )
    assert _fetch(fetcher, "https://a.example/").kind == kind


def test_charset_is_parsed_from_content_type() -> None:
    fetcher, _, _ = _fetcher(
        lambda _r: httpx.Response(
            200,
            content=b"x",
            headers={
                "content-type": 'text/plain; format=flowed; charset="Windows-1252"'
            },
        )
    )
    assert _fetch(fetcher, "https://a.example/").charset == "windows-1252"


@pytest.mark.parametrize(
    "content_type",
    ["image/png", "application/json", "video/mp4", "application/zip", "text/css"],
)
def test_unsupported_content_types_are_rejected(content_type: str) -> None:
    fetcher, _, _ = _fetcher(
        lambda _r: httpx.Response(
            200, content=b"data", headers={"content-type": content_type}
        )
    )
    assert (
        _failure(fetcher, "https://a.example/").code is ArticleFailure.UNSUPPORTED_TYPE
    )


@pytest.mark.parametrize("content_type", ["application/octet-stream", None])
def test_untyped_pdf_is_sniffed(content_type: str | None) -> None:
    headers = {"content-type": content_type} if content_type else {}
    fetcher, _, _ = _fetcher(
        lambda _r: httpx.Response(200, content=b"%PDF-1.7\nbody", headers=headers)
    )
    assert _fetch(fetcher, "https://a.example/doc").kind == "pdf"


def test_untyped_non_pdf_is_unsupported() -> None:
    fetcher, _, _ = _fetcher(
        lambda _r: httpx.Response(
            200,
            content=b"\x89PNG....",
            headers={"content-type": "application/octet-stream"},
        )
    )
    assert (
        _failure(fetcher, "https://a.example/").code is ArticleFailure.UNSUPPORTED_TYPE
    )


def test_declared_length_over_limit_is_rejected_before_reading() -> None:
    async def never_read() -> AsyncIterator[bytes]:
        raise AssertionError("body must not be read")
        yield b""

    fetcher, _, _ = _fetcher(
        lambda _r: httpx.Response(
            200,
            content=never_read(),
            headers={"content-type": "text/html", "content-length": "20000000"},
        )
    )
    assert _failure(fetcher, "https://a.example/").code is ArticleFailure.TOO_LARGE


def test_streamed_body_over_limit_is_cut_off() -> None:
    sent: list[int] = []

    async def endless() -> AsyncIterator[bytes]:
        for _ in range(1000):
            sent.append(1)
            yield b"x" * 1024

    fetcher, _, _ = _fetcher(
        lambda _r: httpx.Response(
            200, content=endless(), headers={"content-type": "text/html"}
        ),
        max_bytes=10 * 1024,
    )
    assert _failure(fetcher, "https://a.example/").code is ArticleFailure.TOO_LARGE
    assert len(sent) <= 12


def test_invalid_content_length_header_is_ignored() -> None:
    fetcher, _, _ = _fetcher(
        lambda _r: httpx.Response(
            200,
            content=HTML,
            headers={"content-type": "text/html", "content-length": "abc"},
        )
    )
    assert _fetch(fetcher, "https://a.example/").body == HTML


def test_gzip_body_is_decoded() -> None:
    fetcher, _, _ = _fetcher(
        lambda _r: httpx.Response(
            200,
            content=gzip.compress(HTML),
            headers={"content-type": "text/html", "content-encoding": "gzip"},
        )
    )
    assert _fetch(fetcher, "https://a.example/").body == HTML


def test_deflate_body_is_decoded() -> None:
    fetcher, _, _ = _fetcher(
        lambda _r: httpx.Response(
            200,
            content=zlib.compress(HTML),
            headers={"content-type": "text/html", "content-encoding": "deflate"},
        )
    )
    assert _fetch(fetcher, "https://a.example/").body == HTML


def test_compression_bomb_is_bounded() -> None:
    bomb = gzip.compress(b"\0" * (50 * 1024 * 1024))
    fetcher, _, _ = _fetcher(
        lambda _r: httpx.Response(
            200,
            content=bomb,
            headers={"content-type": "text/html", "content-encoding": "gzip"},
        ),
        max_bytes=1024 * 1024,
    )
    assert _failure(fetcher, "https://a.example/").code is ArticleFailure.TOO_LARGE


def test_corrupt_gzip_is_an_error() -> None:
    fetcher, _, _ = _fetcher(
        lambda _r: httpx.Response(
            200,
            content=_chunks(b"not gzip at all"),
            headers={"content-type": "text/html", "content-encoding": "gzip"},
        )
    )
    assert _failure(fetcher, "https://a.example/").code is ArticleFailure.HTTP_ERROR


def test_unknown_content_encoding_is_unsupported() -> None:
    fetcher, _, _ = _fetcher(
        lambda _r: httpx.Response(
            200,
            content=b"\x0b\x02",
            headers={"content-type": "text/html", "content-encoding": "br"},
        )
    )
    assert (
        _failure(fetcher, "https://a.example/").code is ArticleFailure.UNSUPPORTED_TYPE
    )


@pytest.mark.parametrize(
    ("exc", "code"),
    [
        (httpx.ConnectTimeout("slow"), ArticleFailure.TIMEOUT),
        (httpx.ReadTimeout("slow"), ArticleFailure.TIMEOUT),
        (httpx.ConnectError("refused"), ArticleFailure.UNREACHABLE),
        (httpx.RemoteProtocolError("bad"), ArticleFailure.UNREACHABLE),
    ],
)
def test_transport_errors_map_to_clear_errors(
    exc: Exception, code: ArticleFailure
) -> None:
    def handler(_request: httpx.Request) -> httpx.Response:
        raise exc

    fetcher, _, _ = _fetcher(handler)
    error = _failure(fetcher, "https://a.example/")
    assert error.code is code
    assert str(exc) not in error.message


def test_body_stream_failure_is_unreachable() -> None:
    async def broken() -> AsyncIterator[bytes]:
        yield b"<html>"
        raise httpx.ReadError("reset")

    fetcher, _, _ = _fetcher(
        lambda _r: httpx.Response(
            200, content=broken(), headers={"content-type": "text/html"}
        )
    )
    assert _failure(fetcher, "https://a.example/").code is ArticleFailure.UNREACHABLE


def test_body_stream_timeout_is_timeout() -> None:
    async def stalled() -> AsyncIterator[bytes]:
        yield b"<html>"
        raise httpx.ReadTimeout("stalled")

    fetcher, _, _ = _fetcher(
        lambda _r: httpx.Response(
            200, content=stalled(), headers={"content-type": "text/html"}
        )
    )
    assert _failure(fetcher, "https://a.example/").code is ArticleFailure.TIMEOUT


def test_overall_deadline_covers_slow_resolution() -> None:
    async def slow(host: str, port: int) -> list[str]:
        await asyncio.sleep(5)
        return [PUBLIC_IP]

    fetcher = WebFetcher(
        transport=httpx.MockTransport(lambda r: _streamed(_html(r))),
        resolver=slow,
        timeout_seconds=0.05,
    )
    assert _failure(fetcher, "https://slow.example/").code is ArticleFailure.TIMEOUT


def test_overall_deadline_covers_slow_body() -> None:
    async def trickle() -> AsyncIterator[bytes]:
        while True:
            await asyncio.sleep(0.01)
            yield b"x"

    fetcher, _, _ = _fetcher(
        lambda _r: httpx.Response(
            200, content=trickle(), headers={"content-type": "text/html"}
        ),
        timeout_seconds=0.1,
    )
    assert _failure(fetcher, "https://a.example/").code is ArticleFailure.TIMEOUT


def test_concurrent_fetches_are_bounded_and_slots_are_released() -> None:
    async def scenario() -> None:
        release = asyncio.Event()
        started = 0

        async def gated(host: str, port: int) -> list[str]:
            nonlocal started
            started += 1
            await release.wait()
            return [PUBLIC_IP]

        fetcher = WebFetcher(
            transport=httpx.MockTransport(lambda r: _streamed(_html(r))), resolver=gated
        )
        running = [
            asyncio.create_task(fetcher.fetch(f"https://a.example/{n}"))
            for n in range(MAX_CONCURRENT_FETCHES)
        ]
        while started < MAX_CONCURRENT_FETCHES:
            await asyncio.sleep(0)
        with pytest.raises(ArticleError) as error:
            await fetcher.fetch("https://a.example/extra")
        assert error.value.code is ArticleFailure.BUSY
        release.set()
        pages = await asyncio.gather(*running)
        assert len(pages) == MAX_CONCURRENT_FETCHES
        assert WebFetcher._active == 0
        assert (await fetcher.fetch("https://a.example/after")).kind == "html"

    asyncio.run(scenario())


def test_failed_fetch_releases_its_slot() -> None:
    fetcher, _, _ = _fetcher(lambda _r: httpx.Response(500))
    for _ in range(MAX_CONCURRENT_FETCHES + 2):
        _failure(fetcher, "https://a.example/")
    assert WebFetcher._active == 0


def test_dependency_returns_a_default_fetcher() -> None:
    assert isinstance(web_fetcher(), WebFetcher)
