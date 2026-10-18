"""Local API gateway: key auth, origin rules, CORS, rate limit, body caps."""

from __future__ import annotations

import hmac
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient

from app.api import public_middleware
from app.api.public_app import create_public_app
from app.api.public_middleware import is_extension_origin
from app.core.config import settings
from app.services.rate_limit import TokenBucket

API_KEY = "test-local-api-key-0123456789abcdef"
AUTH = {"Authorization": f"Bearer {API_KEY}"}


def _client(**headers: str) -> TestClient:
    return TestClient(create_public_app(API_KEY), headers=headers or None)


def test_missing_key_is_rejected() -> None:
    response = _client().get("/v1/models")
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"
    assert response.json()["error"]["type"] == "authentication_error"


@pytest.mark.parametrize(
    "header",
    [
        "Bearer wrong-key",
        f"Bearer {API_KEY}x",
        f"Basic {API_KEY}",
        API_KEY,
        "Bearer ",
        "",
    ],
)
def test_wrong_key_is_rejected(header: str) -> None:
    response = _client().get("/v1/models", headers={"Authorization": header})
    assert response.status_code == 401


def test_correct_key_is_accepted_with_any_scheme_case() -> None:
    client = _client()
    assert client.get("/v1/models", headers=AUTH).status_code == 200
    lower = {"Authorization": f"bearer {API_KEY}"}
    assert client.get("/v1/models", headers=lower).status_code == 200


def test_key_comparison_is_timing_safe() -> None:
    with patch.object(
        public_middleware.hmac, "compare_digest", wraps=hmac.compare_digest
    ) as compare:
        _client().get("/v1/models", headers={"Authorization": "Bearer nope"})
    compare.assert_called_once_with(b"nope", API_KEY.encode())


def test_unauthenticated_request_does_not_reach_routes() -> None:
    with patch("app.api.openai_compat.voice_list") as voice_list:
        response = _client().get("/v1/voices")
    assert response.status_code == 401
    voice_list.assert_not_called()


@pytest.mark.parametrize(
    "origin",
    [
        "https://evil.example.com",
        "http://localhost:3000",
        "null",
        "chrome-extension://",
        "file://",
        "chrome-extension://abc, https://evil.example.com",
        "chrome-extension://" + "a" * 300,
    ],
)
def test_web_origins_are_rejected_even_with_key(origin: str) -> None:
    response = _client().get("/v1/models", headers={**AUTH, "Origin": origin})
    assert response.status_code == 403
    assert "access-control-allow-origin" not in response.headers


@pytest.mark.parametrize(
    "origin",
    [
        "chrome-extension://abcdefghijklmnop",
        "moz-extension://1b2c3d4e-0000-4000-8000-000000000000",
        "safari-web-extension://ABCDEF12-3456",
    ],
)
def test_extension_origins_are_allowed_with_key(origin: str) -> None:
    response = _client().get("/v1/models", headers={**AUTH, "Origin": origin})
    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == origin
    assert "Origin" in response.headers["vary"]


def test_extension_origin_still_requires_key() -> None:
    origin = "chrome-extension://abcdefghijklmnop"
    response = _client().get("/v1/models", headers={"Origin": origin})
    assert response.status_code == 401
    assert response.headers["access-control-allow-origin"] == origin


def test_preflight_is_answered_for_extension_origin_without_key() -> None:
    origin = "moz-extension://abc"
    response = _client().options(
        "/v1/audio/speech",
        headers={
            "Origin": origin,
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "authorization, content-type",
        },
    )
    assert response.status_code == 204
    assert response.headers["access-control-allow-origin"] == origin
    assert "POST" in response.headers["access-control-allow-methods"]
    assert "Authorization" in response.headers["access-control-allow-headers"]


def test_preflight_from_web_origin_is_rejected() -> None:
    response = _client().options(
        "/v1/audio/speech",
        headers={
            "Origin": "https://evil.example.com",
            "Access-Control-Request-Method": "POST",
        },
    )
    assert response.status_code == 403
    assert "access-control-allow-origin" not in response.headers


def test_options_without_preflight_headers_needs_key() -> None:
    response = _client().options(
        "/v1/models", headers={"Origin": "chrome-extension://abc"}
    )
    assert response.status_code == 401


def test_is_extension_origin_rejects_whitespace() -> None:
    assert not is_extension_origin("chrome-extension://abc def")
    assert is_extension_origin("chrome-extension://abc")


def test_rate_limit_returns_429_with_retry_after() -> None:
    with (
        patch.object(settings, "LOCAL_API_RATE_LIMIT_BURST", 3),
        patch.object(settings, "LOCAL_API_RATE_LIMIT_PER_SECOND", 0.01),
    ):
        client = _client()
    statuses = [client.get("/v1/models", headers=AUTH).status_code for _ in range(4)]
    assert statuses == [200, 200, 200, 429]
    limited = client.get("/v1/models", headers=AUTH)
    assert limited.status_code == 429
    assert int(limited.headers["retry-after"]) >= 1
    assert limited.json()["error"]["type"] == "rate_limit_error"


def test_rate_limit_does_not_consume_tokens_for_bad_keys() -> None:
    with (
        patch.object(settings, "LOCAL_API_RATE_LIMIT_BURST", 1),
        patch.object(settings, "LOCAL_API_RATE_LIMIT_PER_SECOND", 0.01),
    ):
        client = _client()
    for _ in range(5):
        client.get("/v1/models", headers={"Authorization": "Bearer nope"})
    assert client.get("/v1/models", headers=AUTH).status_code == 200


def test_declared_body_over_cap_is_rejected() -> None:
    with patch.object(settings, "LOCAL_API_MAX_BODY_BYTES", 64):
        client = _client()
    response = client.post(
        "/v1/voqora/speak", headers=AUTH, content=b"{" + b" " * 100 + b"}"
    )
    assert response.status_code == 413


def test_streamed_body_over_cap_is_rejected() -> None:
    with patch.object(settings, "LOCAL_API_MAX_BODY_BYTES", 64):
        client = _client()

    def chunks():
        yield b'{"text": "'
        yield b"a" * 100
        yield b'"}'

    response = client.post(
        "/v1/voqora/speak",
        headers={**AUTH, "Content-Type": "application/json"},
        content=chunks(),
    )
    assert response.status_code == 413
    assert response.json()["error"]["message"].startswith("Request body exceeds")


def test_streamed_body_over_cap_is_rejected_on_mcp() -> None:
    with patch.object(settings, "LOCAL_API_MAX_BODY_BYTES", 64):
        client = _client()

    def chunks():
        yield b"{" + b" " * 100 + b"}"

    response = client.post("/mcp", headers=AUTH, content=chunks())
    assert response.status_code == 413


def test_docs_and_openapi_are_not_served() -> None:
    client = _client()
    for path in ("/docs", "/redoc", "/openapi.json"):
        assert client.get(path, headers=AUTH).status_code == 404


def test_private_ipc_routes_are_not_on_public_app() -> None:
    client = _client()
    for path in ("/health", "/integrations/local-api", "/integrations/events"):
        assert client.get(path, headers=AUTH).status_code == 404


class _Clock:
    def __init__(self) -> None:
        self.now = 100.0

    def __call__(self) -> float:
        return self.now


def test_token_bucket_refills_over_time() -> None:
    clock = _Clock()
    bucket = TokenBucket(2, 1.0, clock=clock)
    assert bucket.try_acquire()
    assert bucket.try_acquire()
    assert not bucket.try_acquire()
    assert bucket.retry_after_seconds() == 1
    clock.now += 1.0
    assert bucket.try_acquire()
    assert not bucket.try_acquire()


def test_token_bucket_never_exceeds_capacity() -> None:
    clock = _Clock()
    bucket = TokenBucket(2, 10.0, clock=clock)
    clock.now += 1000
    assert [bucket.try_acquire() for _ in range(3)] == [True, True, False]


def test_token_bucket_tolerates_clock_going_backwards() -> None:
    clock = _Clock()
    bucket = TokenBucket(1, 1.0, clock=clock)
    assert bucket.try_acquire()
    clock.now -= 50
    assert not bucket.try_acquire()


@pytest.mark.parametrize("capacity,rate", [(0, 1.0), (1, 0.0), (1, -1.0)])
def test_token_bucket_rejects_invalid_configuration(capacity: int, rate: float) -> None:
    with pytest.raises(ValueError):
        TokenBucket(capacity, rate)
