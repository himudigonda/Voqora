from __future__ import annotations

import asyncio
import ipaddress

import httpx
import pytest

from app.services.article_errors import ArticleError, ArticleFailure
from app.services.url_guard import (
    MAX_URL_CHARS,
    is_public_address,
    parse_web_url,
    resolve_public_address,
    system_resolver,
    url_port,
)


def _resolver(*answers: str):
    async def resolve(host: str, port: int) -> list[str]:
        return list(answers)

    return resolve


def _code(error: pytest.ExceptionInfo[ArticleError]) -> ArticleFailure:
    return error.value.code


@pytest.mark.parametrize(
    "raw",
    [
        "https://example.com/story",
        "http://example.com",
        "  https://example.com/a?b=1  ",
        "https://bücher.example/kapitel",
        "https://example.com:8443/x",
    ],
)
def test_parse_accepts_http_and_https(raw: str) -> None:
    url = parse_web_url(raw)
    assert url.scheme in {"http", "https"}


def test_parse_drops_fragment() -> None:
    assert parse_web_url("https://example.com/a#section").fragment == ""


@pytest.mark.parametrize(
    "raw",
    [
        "",
        "   ",
        "example.com/story",
        "ftp://example.com/file",
        "file:///etc/passwd",
        "javascript:alert(1)",
        "data:text/html,hello",
        "gopher://example.com",
        "https://",
        "http://[::1",
        "https://example.com:99999/",
        "https://example.com/" + "a" * MAX_URL_CHARS,
    ],
)
def test_parse_rejects_invalid_urls(raw: str) -> None:
    with pytest.raises(ArticleError) as error:
        parse_web_url(raw)
    assert _code(error) is ArticleFailure.INVALID_URL


@pytest.mark.parametrize(
    "raw",
    [
        "https://user:secret@example.com/",
        "https://user@example.com/",
        "https://:secret@example.com/",
    ],
)
def test_parse_rejects_credentials(raw: str) -> None:
    with pytest.raises(ArticleError) as error:
        parse_web_url(raw)
    assert _code(error) is ArticleFailure.INVALID_URL
    assert "password" in error.value.message


def test_url_port_defaults() -> None:
    assert url_port(httpx.URL("http://example.com/")) == 80
    assert url_port(httpx.URL("https://example.com/")) == 443
    assert url_port(httpx.URL("https://example.com:8443/")) == 8443


@pytest.mark.parametrize(
    "address",
    [
        "127.0.0.1",
        "127.1.2.3",
        "10.0.0.1",
        "172.16.5.4",
        "192.168.1.1",
        "169.254.169.254",
        "100.64.0.1",
        "0.0.0.0",
        "224.0.0.1",
        "239.255.255.250",
        "240.0.0.1",
        "255.255.255.255",
        "192.0.2.1",
        "198.18.0.1",
        "::1",
        "::",
        "fe80::1",
        "fe80::1%en0",
        "fc00::1",
        "fd12:3456::1",
        "ff02::1",
        "2001:db8::1",
        "::ffff:127.0.0.1",
        "::ffff:10.0.0.1",
        "::ffff:169.254.169.254",
        "64:ff9b::7f00:1",
        "64:ff9b::a00:1",
        "2002:7f00:1::1",
        "2002:a00:1::1",
        "2001:0:4136:e378:8000:63bf:80ff:fffe",
    ],
)
def test_non_public_addresses_are_blocked(address: str) -> None:
    assert not is_public_address(ipaddress.ip_address(address))


@pytest.mark.parametrize(
    "address", ["93.184.216.34", "8.8.8.8", "1.1.1.1", "2606:4700:4700::1111"]
)
def test_public_addresses_are_allowed(address: str) -> None:
    assert is_public_address(ipaddress.ip_address(address))


@pytest.mark.parametrize(
    "raw",
    [
        "http://127.0.0.1/",
        "http://[::1]/",
        "http://[::ffff:127.0.0.1]/",
        "http://10.1.2.3:8080/admin",
        "http://169.254.169.254/latest/meta-data/",
    ],
)
def test_literal_private_hosts_are_blocked_without_resolving(raw: str) -> None:
    async def never(host: str, port: int) -> list[str]:
        raise AssertionError("literal addresses must not be resolved")

    with pytest.raises(ArticleError) as error:
        asyncio.run(resolve_public_address(parse_web_url(raw), never))
    assert _code(error) is ArticleFailure.BLOCKED_ADDRESS


def test_literal_public_host_is_returned() -> None:
    address = asyncio.run(
        resolve_public_address(parse_web_url("http://93.184.216.34/"), _resolver())
    )
    assert str(address) == "93.184.216.34"


@pytest.mark.parametrize(
    "answers",
    [
        ("127.0.0.1",),
        ("93.184.216.34", "10.0.0.1"),
        ("::1",),
        ("2606:4700:4700::1111", "fe80::1"),
        ("not-an-address",),
    ],
)
def test_any_non_public_answer_blocks_the_host(answers: tuple[str, ...]) -> None:
    url = parse_web_url("https://rebind.example/")
    with pytest.raises(ArticleError) as error:
        asyncio.run(resolve_public_address(url, _resolver(*answers)))
    assert _code(error) is ArticleFailure.BLOCKED_ADDRESS


@pytest.mark.parametrize("host", ["localhost", "2130706433", "0x7f.1", "localhost."])
def test_hostnames_that_resolve_to_loopback_are_blocked(host: str) -> None:
    url = parse_web_url(f"http://{host}/")
    with pytest.raises(ArticleError) as error:
        asyncio.run(resolve_public_address(url, _resolver("127.0.0.1")))
    assert _code(error) is ArticleFailure.BLOCKED_ADDRESS


def test_first_public_answer_is_pinned() -> None:
    url = parse_web_url("https://example.com/")
    address = asyncio.run(
        resolve_public_address(url, _resolver("93.184.216.34", "1.1.1.1"))
    )
    assert str(address) == "93.184.216.34"


def test_resolver_receives_idna_host_and_port() -> None:
    seen: list[tuple[str, int]] = []

    async def resolve(host: str, port: int) -> list[str]:
        seen.append((host, port))
        return ["93.184.216.34"]

    asyncio.run(
        resolve_public_address(parse_web_url("https://bücher.example:8443/"), resolve)
    )
    assert seen == [("xn--bcher-kva.example", 8443)]


def test_resolution_failure_is_unreachable() -> None:
    async def fail(host: str, port: int) -> list[str]:
        raise OSError("nodename nor servname provided")

    with pytest.raises(ArticleError) as error:
        asyncio.run(
            resolve_public_address(parse_web_url("https://nope.example/"), fail)
        )
    assert _code(error) is ArticleFailure.UNREACHABLE
    assert "nodename" not in error.value.message


def test_empty_resolution_is_unreachable() -> None:
    with pytest.raises(ArticleError) as error:
        asyncio.run(
            resolve_public_address(parse_web_url("https://empty.example/"), _resolver())
        )
    assert _code(error) is ArticleFailure.UNREACHABLE


def test_system_resolver_returns_addresses() -> None:
    answers = asyncio.run(system_resolver("127.0.0.1", 80))
    assert "127.0.0.1" in answers
