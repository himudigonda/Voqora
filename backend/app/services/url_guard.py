"""Validation of user-supplied web URLs and the addresses they resolve to."""

from __future__ import annotations

import asyncio
import ipaddress
import socket
from collections.abc import Awaitable, Callable

import httpx

from app.services.article_errors import ArticleError, ArticleFailure

IPAddress = ipaddress.IPv4Address | ipaddress.IPv6Address
Resolver = Callable[[str, int], Awaitable[list[str]]]

MAX_URL_CHARS = 2048
_SCHEMES = frozenset({"http", "https"})
_DEFAULT_PORTS = {"http": 80, "https": 443}
_NAT64_PREFIX = ipaddress.IPv6Network("64:ff9b::/96")

_INVALID_URL = "Enter a full web address that starts with http:// or https://."
_BLOCKED = "Voqora only reads public websites, not local or private addresses."
_NO_HOST = "Voqora couldn't find that website. Check the address and try again."


def parse_web_url(raw: str) -> httpx.URL:
    candidate = raw.strip()
    if not candidate or len(candidate) > MAX_URL_CHARS:
        raise ArticleError(ArticleFailure.INVALID_URL, _INVALID_URL)
    try:
        url = httpx.URL(candidate)
    except (httpx.InvalidURL, ValueError, TypeError) as exc:
        raise ArticleError(ArticleFailure.INVALID_URL, _INVALID_URL) from exc
    if url.scheme not in _SCHEMES or not url.raw_host:
        raise ArticleError(ArticleFailure.INVALID_URL, _INVALID_URL)
    if url.port is not None and not 0 < url.port < 65536:
        raise ArticleError(ArticleFailure.INVALID_URL, _INVALID_URL)
    if url.userinfo:
        raise ArticleError(
            ArticleFailure.INVALID_URL,
            "Web addresses with a user name or password aren't supported.",
        )
    return url.copy_with(fragment=None)


def url_port(url: httpx.URL) -> int:
    return url.port or _DEFAULT_PORTS[url.scheme]


def _embedded_ipv4(address: ipaddress.IPv6Address) -> ipaddress.IPv4Address | None:
    if address.ipv4_mapped is not None:
        return address.ipv4_mapped
    if address.sixtofour is not None:
        return address.sixtofour
    if address.teredo is not None:
        return address.teredo[1]
    if address in _NAT64_PREFIX:
        return ipaddress.IPv4Address(int(address) & 0xFFFFFFFF)
    return None


def _is_public(address: IPAddress) -> bool:
    return not (
        address.is_loopback
        or address.is_link_local
        or address.is_private
        or address.is_multicast
        or address.is_reserved
        or address.is_unspecified
        or not address.is_global
    )


def is_public_address(address: IPAddress) -> bool:
    if isinstance(address, ipaddress.IPv6Address):
        embedded = _embedded_ipv4(address)
        if embedded is not None and not _is_public(embedded):
            return False
    return _is_public(address)


def _parse_address(value: str) -> IPAddress | None:
    try:
        return ipaddress.ip_address(value.strip("[]"))
    except ValueError:
        return None


async def system_resolver(host: str, port: int) -> list[str]:
    loop = asyncio.get_running_loop()
    infos = await loop.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    return [str(info[4][0]) for info in infos]


async def resolve_public_address(url: httpx.URL, resolver: Resolver) -> IPAddress:
    host = url.raw_host.decode("ascii")
    literal = _parse_address(host)
    if literal is not None:
        if not is_public_address(literal):
            raise ArticleError(ArticleFailure.BLOCKED_ADDRESS, _BLOCKED)
        return literal
    try:
        answers = await resolver(host, url_port(url))
    except (OSError, UnicodeError) as exc:
        raise ArticleError(ArticleFailure.UNREACHABLE, _NO_HOST) from exc
    if not answers:
        raise ArticleError(ArticleFailure.UNREACHABLE, _NO_HOST)
    parsed = [_parse_address(answer) for answer in answers]
    public = [
        address
        for address in parsed
        if address is not None and is_public_address(address)
    ]
    if len(public) != len(parsed):
        raise ArticleError(ArticleFailure.BLOCKED_ADDRESS, _BLOCKED)
    return public[0]
