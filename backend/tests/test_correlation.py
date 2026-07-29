"""Correlation middleware contract.

Every response from the backend must carry an X-Correlation-ID header
that either echoes the inbound value or supplies a fresh UUID. This is
the only way we can pin a Swift-side error report back to a backend log
line. The contract has to hold across 2xx, 4xx, and 5xx paths.
"""

from __future__ import annotations

import re
from unittest.mock import patch

from fastapi.testclient import TestClient

from app.main import app
from app.services.engine_manager import EngineManager

_UUID_RE = re.compile(r"^[0-9a-f-]{32,40}$", re.IGNORECASE)


def _client() -> TestClient:
    return TestClient(app)


@patch.object(EngineManager, "ensure_loaded")
def test_correlation_header_is_generated_when_absent(mock_ensure) -> None:
    response = _client().get("/health")
    cid = response.headers.get("X-Correlation-ID")
    assert cid, "response must carry X-Correlation-ID"
    assert _UUID_RE.match(cid) or len(cid) >= 8


@patch.object(EngineManager, "ensure_loaded")
def test_correlation_header_is_echoed_when_present(mock_ensure) -> None:
    inbound = "ab12cd34-supplied-by-client"
    response = _client().get("/health", headers={"X-Correlation-ID": inbound})
    assert response.headers["X-Correlation-ID"] == inbound


@patch.object(EngineManager, "ensure_loaded")
def test_correlation_header_lowercase_inbound_is_echoed(mock_ensure) -> None:
    inbound = "lowercase-header-key"
    response = _client().get("/health", headers={"x-correlation-id": inbound})
    assert response.headers["X-Correlation-ID"] == inbound


@patch.object(EngineManager, "ensure_loaded")
def test_correlation_header_present_on_404(mock_ensure) -> None:
    response = _client().get("/this-route-does-not-exist")
    assert response.status_code == 404
    assert response.headers.get("X-Correlation-ID"), (
        "4xx responses must still carry the correlation id — otherwise "
        "client-side error reports can't be cross-referenced to logs"
    )


@patch.object(EngineManager, "ensure_loaded")
def test_each_request_gets_a_fresh_id_when_not_supplied(mock_ensure) -> None:
    c = _client()
    first = c.get("/health").headers["X-Correlation-ID"]
    second = c.get("/health").headers["X-Correlation-ID"]
    assert first != second, "without an inbound id, each request gets a fresh one"


@patch.object(EngineManager, "ensure_loaded")
def test_correlation_id_does_not_leak_between_requests(mock_ensure) -> None:
    """Regression guard: contextvar state must not bleed across requests."""
    c = _client()
    a = c.get("/health", headers={"X-Correlation-ID": "first"}).headers[
        "X-Correlation-ID"
    ]
    b = c.get("/health").headers["X-Correlation-ID"]
    assert a == "first"
    assert b != "first"
