"""FastAPI middleware: assigns a correlation id per request (S1-G1).

The id is taken from the `X-Correlation-ID` header if present, otherwise
generated. It is echoed back to the client in the response header and
attached to every log record emitted while the handler runs.
"""

from __future__ import annotations

import hmac
import time

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import PlainTextResponse

from app.core.config import settings
from app.core.logging import get_logger, set_correlation_id

log = get_logger("voqora.http")


class IPCAuthenticationMiddleware(BaseHTTPMiddleware):
    """Reject every request that is not from the app-owned local client.

    Loopback limits access to this Mac, not access to Voqora's data: a browser
    or another local process can otherwise call this server. The parent app
    supplies a unique, non-persistent token only to this child and attaches it
    to every URLSession request. This middleware is installed outermost, before
    request bodies are parsed or correlation logging runs.
    """

    _HEADER = "x-voqora-ipc-token"

    async def dispatch(self, request: Request, call_next):
        expected = settings.IPC_TOKEN
        # A packaged backend without a launch token is a configuration error,
        # not an unauthenticated development mode. Returning a generic status
        # avoids leaking process/configuration details to a local attacker.
        if not expected:
            return PlainTextResponse("Local backend unavailable.", status_code=503)

        provided = request.headers.get(self._HEADER, "")
        if not provided or not hmac.compare_digest(provided, expected):
            return PlainTextResponse("Unauthorized local client.", status_code=401)
        return await call_next(request)


class RejectBrowserOriginMiddleware(BaseHTTPMiddleware):
    """Reject any request carrying an `Origin` header.

    This remains defence in depth. The token middleware is the access-control
    boundary; rejecting browser origins prevents an accidental future route
    from becoming useful to browser JavaScript if token handling regresses.
    """

    async def dispatch(self, request: Request, call_next):
        if request.headers.get("origin") is not None:
            return PlainTextResponse(
                "Cross-origin requests are not permitted.", status_code=403
            )
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
                    "route": request.url.path,
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
                    "route": request.url.path,
                    "status": response.status_code,
                    "duration_ms": duration_ms,
                },
            )
        response.headers["X-Correlation-ID"] = cid
        return response
