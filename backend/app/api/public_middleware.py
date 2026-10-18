from __future__ import annotations

import hmac

from fastapi import HTTPException
from starlette.datastructures import Headers, MutableHeaders
from starlette.responses import Response
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.api.public_errors import error_response
from app.core.logging import get_logger
from app.services.rate_limit import TokenBucket

log = get_logger("voqora.local_api")

EXTENSION_ORIGIN_SCHEMES = (
    "chrome-extension://",
    "moz-extension://",
    "safari-web-extension://",
)
_MAX_ORIGIN_CHARS = 256
_ALLOWED_METHODS = "GET, POST, OPTIONS"
_ALLOWED_HEADERS = (
    "Authorization, Content-Type, Accept, MCP-Protocol-Version, Mcp-Session-Id"
)
_PREFLIGHT_MAX_AGE_SECONDS = "600"
_BEARER_PREFIX = "bearer "


def is_extension_origin(origin: str) -> bool:
    if len(origin) > _MAX_ORIGIN_CHARS or any(c.isspace() or c == "," for c in origin):
        return False
    return any(
        origin.startswith(scheme) and len(origin) > len(scheme)
        for scheme in EXTENSION_ORIGIN_SCHEMES
    )


class ExtensionOriginMiddleware:
    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        headers = Headers(scope=scope)
        origin = headers.get("origin")
        if origin is None:
            await self.app(scope, receive, send)
            return
        if not is_extension_origin(origin):
            response = error_response(403, "Cross-origin requests are not permitted.")
            await response(scope, receive, send)
            return
        if _is_preflight(scope, headers):
            await _preflight_response(origin)(scope, receive, send)
            return
        await self.app(scope, receive, _with_cors_headers(send, origin))


def _is_preflight(scope: Scope, headers: Headers) -> bool:
    return scope["method"] == "OPTIONS" and "access-control-request-method" in headers


def _preflight_response(origin: str) -> Response:
    return Response(
        status_code=204,
        headers={
            "Access-Control-Allow-Origin": origin,
            "Access-Control-Allow-Methods": _ALLOWED_METHODS,
            "Access-Control-Allow-Headers": _ALLOWED_HEADERS,
            "Access-Control-Max-Age": _PREFLIGHT_MAX_AGE_SECONDS,
            "Vary": "Origin",
        },
    )


def _with_cors_headers(send: Send, origin: str) -> Send:
    async def send_with_cors(message: Message) -> None:
        if message["type"] == "http.response.start":
            headers = MutableHeaders(scope=message)
            headers["Access-Control-Allow-Origin"] = origin
            headers.append("Vary", "Origin")
        await send(message)

    return send_with_cors


class BearerAuthMiddleware:
    def __init__(self, app: ASGIApp, api_key: str) -> None:
        self.app = app
        self._expected = api_key.encode()

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        if not self._is_authorized(Headers(scope=scope)):
            response = error_response(
                401,
                "Missing or invalid API key.",
                headers={"WWW-Authenticate": "Bearer"},
            )
            await response(scope, receive, send)
            return
        await self.app(scope, receive, send)

    def _is_authorized(self, headers: Headers) -> bool:
        provided = _bearer_token(headers.get("authorization", ""))
        return hmac.compare_digest(provided.encode(), self._expected)


def _bearer_token(value: str) -> str:
    if value[: len(_BEARER_PREFIX)].lower() != _BEARER_PREFIX:
        return ""
    return value[len(_BEARER_PREFIX) :].strip()


class RateLimitMiddleware:
    def __init__(self, app: ASGIApp, bucket: TokenBucket) -> None:
        self.app = app
        self._bucket = bucket

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or self._bucket.try_acquire():
            await self.app(scope, receive, send)
            return
        log.warning("local_api.rate_limited", extra={"failure_code": "rate_limited"})
        retry_after = str(self._bucket.retry_after_seconds())
        response = error_response(
            429,
            "Too many requests. Slow down and try again.",
            headers={"Retry-After": retry_after},
        )
        await response(scope, receive, send)


class BodyLimitMiddleware:
    def __init__(self, app: ASGIApp, max_bytes: int) -> None:
        self.app = app
        self._max_bytes = max_bytes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        if _declared_length(Headers(scope=scope)) > self._max_bytes:
            await self._too_large()(scope, receive, send)
            return
        await self.app(scope, self._counting(receive), send)

    def _too_large(self) -> Response:
        return error_response(413, f"Request body exceeds {self._max_bytes} bytes.")

    def _counting(self, receive: Receive) -> Receive:
        received = 0

        async def counting_receive() -> Message:
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > self._max_bytes:
                    raise HTTPException(
                        status_code=413,
                        detail=f"Request body exceeds {self._max_bytes} bytes.",
                    )
            return message

        return counting_receive


def _declared_length(headers: Headers) -> int:
    try:
        return int(headers.get("content-length", "0"))
    except ValueError:
        return 0
