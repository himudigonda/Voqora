"""Authenticated local transport contract."""

from __future__ import annotations

from unittest.mock import patch

from conftest import TEST_IPC_TOKEN
from fastapi.testclient import TestClient

from app.core.config import settings
from app.main import app
from app.services.engine_manager import EngineManager


def _client() -> TestClient:
    return TestClient(app)


@patch.object(EngineManager, "ensure_loaded")
def test_request_with_origin_header_is_rejected(mock_ensure) -> None:
    response = _client().get("/health", headers={"Origin": "https://evil.example.com"})
    assert response.status_code == 403


@patch.object(EngineManager, "ensure_loaded")
def test_request_without_ipc_token_is_rejected_before_route_work(mock_ensure) -> None:
    response = TestClient(app, headers={"X-Voqora-IPC-Token": ""}).get("/health")
    assert response.status_code == 401
    mock_ensure.assert_not_called()


@patch.object(EngineManager, "ensure_loaded")
def test_request_with_wrong_ipc_token_is_rejected_before_route_work(
    mock_ensure,
) -> None:
    response = TestClient(app, headers={"X-Voqora-IPC-Token": "wrong-token"}).get(
        "/health"
    )
    assert response.status_code == 401
    mock_ensure.assert_not_called()


@patch.object(EngineManager, "ensure_loaded")
def test_request_with_valid_ipc_token_is_allowed(mock_ensure) -> None:
    response = TestClient(app, headers={"X-Voqora-IPC-Token": TEST_IPC_TOKEN}).get(
        "/health"
    )
    assert response.status_code == 200


@patch.object(EngineManager, "ensure_loaded")
def test_backend_fails_closed_when_launch_token_is_missing(
    mock_ensure, monkeypatch
) -> None:
    monkeypatch.setattr(settings, "IPC_TOKEN", "")
    response = _client().get("/health")
    assert response.status_code == 503
    mock_ensure.assert_not_called()


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
