"""FastAPI middleware: assigns a correlation id per request (S1-G1).

The id is taken from the `X-Correlation-ID` header if present, otherwise
generated. It is echoed back to the client in the response header and
attached to every log record emitted while the handler runs.
"""

from __future__ import annotations

import time

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request

from app.core.logging import get_logger, set_correlation_id

log = get_logger("voqora.http")


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
