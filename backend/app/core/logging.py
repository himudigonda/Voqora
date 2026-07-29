"""Structured JSON logging for the Voqora backend (S1-G1).

Uses stdlib only — no new dependency. Bundled PyInstaller binaries stay slim.

Usage:
    from app.core.logging import get_logger
    log = get_logger(__name__)
    log.info("speak.start", extra={"chars": len(text), "voice": voice})

Correlation id flows via a contextvar set by the FastAPI middleware in
`app.api.middleware`. Falls back to `-` when no request is active.
"""

from __future__ import annotations

import json
import logging
import sys
import time
import uuid
from contextvars import ContextVar
from typing import Any

# Correlation id is request-scoped; set by middleware on each incoming request.
_correlation_id: ContextVar[str] = ContextVar("voqora_correlation_id", default="-")


def set_correlation_id(value: str | None = None) -> str:
    cid = value or uuid.uuid4().hex[:12]
    _correlation_id.set(cid)
    return cid


def current_correlation_id() -> str:
    return _correlation_id.get()


def _is_jsonable(v: Any) -> bool:
    try:
        json.dumps(v)
        return True
    except TypeError:
        return False


class _JsonFormatter(logging.Formatter):
    """Render LogRecord as a single-line JSON object."""

    # Reserved top-level keys we set ourselves. User-supplied `extra={...}`
    # MUST NOT override these — a caller passing `extra={"cid": None}` was
    # previously able to null out the correlation ID. Caught by hypothesis.
    _PROTECTED_KEYS = frozenset({"ts", "level", "logger", "msg", "cid"})

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created))
            + f".{int(record.msecs):03d}Z",
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
            "cid": _correlation_id.get(),
        }
        # Include the standard "extra" fields, skipping the noise.
        skip = {
            "args",
            "asctime",
            "created",
            "exc_info",
            "exc_text",
            "filename",
            "funcName",
            "levelname",
            "levelno",
            "lineno",
            "module",
            "msecs",
            "message",
            "msg",
            "name",
            "pathname",
            "process",
            "processName",
            "relativeCreated",
            "stack_info",
            "thread",
            "threadName",
            "taskName",
        }
        for k, v in record.__dict__.items():
            if k in skip or k.startswith("_"):
                continue
            if k in self._PROTECTED_KEYS:
                # Keep the reserved value; expose the caller's collision under a
                # namespaced key so the data isn't silently dropped.
                payload[f"x_{k}"] = v if _is_jsonable(v) else repr(v)
                continue
            try:
                json.dumps(v)
                payload[k] = v
            except TypeError:
                payload[k] = repr(v)

        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info).splitlines()[-1]

        return json.dumps(payload, separators=(",", ":"))


_configured = False


def configure(level: int = logging.INFO) -> None:
    """Idempotent root-logger setup. Call once on app startup."""
    global _configured
    if _configured:
        return
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(_JsonFormatter())
    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(level)

    # Quiet down chatty libs by default; keep our own loggers verbose.
    for name in ("uvicorn", "uvicorn.access", "uvicorn.error", "httpx", "httpcore"):
        logging.getLogger(name).setLevel(logging.WARNING)

    _configured = True


def get_logger(name: str) -> logging.Logger:
    """Return a logger; configures the root once if not done."""
    if not _configured:
        configure()
    return logging.getLogger(name)
