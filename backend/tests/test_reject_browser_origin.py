"""RejectBrowserOriginMiddleware contract.

This backend binds to 127.0.0.1, but that only stops other machines — any
webpage the user has open in a browser can still reach a localhost port
from JavaScript. The bundled Swift client talks to this process over
URLSession, which never sets an `Origin` header; only a browser does, on
every fetch/XHR/form POST it issues, same-origin or not. So any request
carrying `Origin` must be rejected before it reaches a real route.
"""

from __future__ import annotations

from unittest.mock import patch

from fastapi.testclient import TestClient

from app.main import app
from app.services.engine_manager import EngineManager


def _client() -> TestClient:
    return TestClient(app)


@patch.object(EngineManager, "ensure_loaded")
def test_request_with_origin_header_is_rejected(mock_ensure) -> None:
    response = _client().get("/health", headers={"Origin": "https://evil.example.com"})
    assert response.status_code == 403


@patch.object(EngineManager, "ensure_loaded")
def test_request_without_origin_header_is_allowed(mock_ensure) -> None:
    response = _client().get("/health")
    assert response.status_code == 200


@patch.object(EngineManager, "ensure_loaded")
def test_same_origin_looking_header_is_still_rejected(mock_ensure) -> None:
    """A browser sends Origin even for a same-origin-looking fetch to this
    port — the app itself never has an origin of its own, so there is no
    legitimate value of Origin to allow-list. Presence alone is the signal.
    """
    response = _client().get("/health", headers={"Origin": "http://127.0.0.1:10101"})
    assert response.status_code == 403


@patch.object(EngineManager, "ensure_loaded")
def test_post_speak_with_origin_header_is_rejected_before_reaching_the_route(
    mock_ensure,
) -> None:
    response = _client().post(
        "/speak",
        json={"text": "hello", "voice": "af_bella"},
        headers={"Origin": "https://evil.example.com"},
    )
    assert response.status_code == 403
