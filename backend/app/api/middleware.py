"""FastAPI middleware: assigns a correlation id per request (S1-G1).

The id is taken from the `X-Correlation-ID` header if present, otherwise
generated. It is echoed back to the client in the response header and
attached to every log record emitted while the handler runs.
"""

from __future__ import annotations

import time

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import PlainTextResponse

from app.core.logging import get_logger, set_correlation_id

log = get_logger("voqora.http")


class RejectBrowserOriginMiddleware(BaseHTTPMiddleware):
    """Reject any request carrying an `Origin` header.

    This server binds to 127.0.0.1 as its only access control (see
    core/config.py HARD-004), but that stops other machines, not other
    *processes on this machine* — any webpage the user has open can still
    reach a localhost port from JavaScript via fetch/XHR, and the browser
    happily completes the request even though it then blocks the page from
    reading a cross-origin response body. Without this check, that's enough
    for any site to silently trigger real TTS inference (CPU/battery cost,
    repeatable indefinitely) or a Gemini API call on the user's behalf.
    The bundled Swift client talks to this process over URLSession, which
    never sets `Origin` — only a browser does, on every fetch/XHR/form POST
    it issues, same-origin or not. So Origin's presence is a reliable
    signal to block, not a heuristic that risks false positives.
    """

    async def dispatch(self, request: Request, call_next):
        if request.headers.get("origin") is not None:
            return PlainTextResponse("Cross-origin requests are not permitted.", status_code=403)
        return await call_next(request)


class CorrelationMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        cid = request.headers.get("x-correlation-id") or None
        cid = set_correlation_id(cid)
        start = time.perf_counter()
        try:
            response = await call_next(request)
        except Exception:
            log.exception(
                "http.request.failed",
                extra={
                    "method": request.method,
                    "path": request.url.path,
                    "duration_ms": round((time.perf_counter() - start) * 1000, 1),
                },
            )
            raise
        duration_ms = round((time.perf_counter() - start) * 1000, 1)
        # Skip noisy health pings.
        if request.url.path != "/health":
            log.info(
                "http.request",
                extra={
                    "method": request.method,
                    "path": request.url.path,
                    "status": response.status_code,
                    "duration_ms": duration_ms,
                },
            )
        response.headers["X-Correlation-ID"] = cid
        return response
