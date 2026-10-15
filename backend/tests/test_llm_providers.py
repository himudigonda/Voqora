from __future__ import annotations

import asyncio
import base64
import json

import httpx
import pytest

from app.services.llm_cleaner import LLMCleaner
from app.services.llm_providers import (
    PROVIDERS,
    UNLISTED_MODEL_PRICE,
    LLMAuthError,
    LLMBadResponseError,
    LLMCredential,
    LLMIncompleteError,
    LLMRateLimitError,
    LLMUnreachableError,
    complete,
    list_models,
)


def _run(coro):
    return asyncio.run(coro)


def _transport(handler):
    seen: list[httpx.Request] = []

    def record(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return handler(request)

    return httpx.MockTransport(record), seen


def _openai_reply(text: str, finish: str = "stop") -> httpx.Response:
    return httpx.Response(
        200,
        json={
            "choices": [{"message": {"content": text}, "finish_reason": finish}],
            "usage": {"prompt_tokens": 12, "completion_tokens": 7},
        },
    )


def test_every_provider_shown_in_the_app_is_registered() -> None:
    assert list(PROVIDERS) == [
        "openai",
        "anthropic",
        "xai",
        "groq",
        "cerebras",
        "google",
        "openrouter",
        "ollama",
        "lmstudio",
        "custom",
    ]


def test_openai_compatible_request_shape_and_usage() -> None:
    transport, seen = _transport(lambda _r: _openai_reply("clean text"))
    credential = LLMCredential("groq", api_key="gsk-test")
    result = _run(
        complete(
            credential,
            system="SYS",
            text="raw",
            max_output_tokens=100,
            transport=transport,
        )
    )
    assert (result.text, result.input_tokens, result.output_tokens) == (
        "clean text",
        12,
        7,
    )
    request = seen[0]
    assert str(request.url) == "https://api.groq.com/openai/v1/chat/completions"
    assert request.headers["authorization"] == "Bearer gsk-test"
    body = json.loads(request.content)
    assert body["model"] == "openai/gpt-oss-120b"
    assert body["max_tokens"] == 100
    assert body["messages"] == [
        {"role": "system", "content": "SYS"},
        {"role": "user", "content": "raw"},
    ]


def test_openai_uses_completion_token_field_and_no_temperature() -> None:
    transport, seen = _transport(lambda _r: _openai_reply("ok"))
    _run(
        complete(
            LLMCredential("openai", api_key="sk"),
            system="S",
            text="t",
            max_output_tokens=50,
            transport=transport,
        )
    )
    body = json.loads(seen[0].content)
    assert body["max_completion_tokens"] == 50
    assert "max_tokens" not in body and "temperature" not in body


def test_image_is_sent_as_data_url() -> None:
    transport, seen = _transport(lambda _r: _openai_reply("page"))
    _run(
        complete(
            LLMCredential("openai", api_key="sk"),
            system="S",
            image_jpeg=b"jpeg",
            max_output_tokens=10,
            transport=transport,
        )
    )
    content = json.loads(seen[0].content)["messages"][1]["content"]
    encoded = base64.b64encode(b"jpeg").decode()
    assert content[0]["image_url"]["url"] == f"data:image/jpeg;base64,{encoded}"


def test_local_provider_sends_no_authorization_and_honors_custom_url() -> None:
    transport, seen = _transport(lambda _r: _openai_reply("ok"))
    credential = LLMCredential(
        "custom", model="m", base_url="http://127.0.0.1:9000/v1/"
    )
    _run(
        complete(
            credential, system="S", text="t", max_output_tokens=5, transport=transport
        )
    )
    assert str(seen[0].url) == "http://127.0.0.1:9000/v1/chat/completions"
    assert "authorization" not in seen[0].headers


def test_anthropic_request_shape() -> None:
    def reply(_request):
        return httpx.Response(
            200,
            json={
                "content": [{"type": "text", "text": "done"}],
                "stop_reason": "end_turn",
                "usage": {"input_tokens": 3, "output_tokens": 4},
            },
        )

    transport, seen = _transport(reply)
    result = _run(
        complete(
            LLMCredential("anthropic", api_key="sk-ant"),
            system="SYS",
            text="raw",
            max_output_tokens=64,
            transport=transport,
        )
    )
    assert (result.text, result.input_tokens, result.output_tokens) == ("done", 3, 4)
    request = seen[0]
    assert str(request.url) == "https://api.anthropic.com/v1/messages"
    assert request.headers["x-api-key"] == "sk-ant"
    assert request.headers["anthropic-version"] == "2023-06-01"
    body = json.loads(request.content)
    assert body["system"] == "SYS"
    assert body["model"] == "claude-haiku-5-5"
    assert body["max_tokens"] == 64


@pytest.mark.parametrize(
    ("status", "error"),
    [
        (401, LLMAuthError),
        (403, LLMAuthError),
        (404, LLMBadResponseError),
        (429, LLMRateLimitError),
        (503, LLMRateLimitError),
        (400, LLMBadResponseError),
    ],
)
def test_http_errors_are_typed(status: int, error: type[Exception]) -> None:
    transport, _ = _transport(lambda _r: httpx.Response(status, json={}))
    with pytest.raises(error):
        _run(
            complete(
                LLMCredential("xai", api_key="k"),
                system="S",
                text="t",
                max_output_tokens=5,
                transport=transport,
            )
        )


def test_filtered_completion_is_incomplete_not_silent() -> None:
    reply = httpx.Response(
        200,
        json={
            "choices": [
                {"message": {"content": None}, "finish_reason": "content_filter"}
            ]
        },
    )
    transport, _ = _transport(lambda _r: reply)
    with pytest.raises(LLMIncompleteError):
        _run(
            complete(
                LLMCredential("openai", api_key="k"),
                system="S",
                text="t",
                max_output_tokens=5,
                transport=transport,
            )
        )


def test_empty_reply_for_real_text_is_retryable_not_silence() -> None:
    from unittest.mock import AsyncMock, patch

    from app.services import llm_providers as providers
    from app.services.llm_providers import Completion

    with patch.object(
        providers, "complete", new=AsyncMock(return_value=Completion("", 1, 0))
    ):
        with pytest.raises(LLMBadResponseError):
            _run(
                LLMCleaner._async_clean(
                    LLMCredential("groq", api_key="k"), "a real page", None
                )
            )


def test_cloud_connection_blip_is_retried_not_fatal() -> None:
    def refuse(request):
        raise httpx.ConnectError("reset", request=request)

    transport, _ = _transport(refuse)
    with pytest.raises(LLMRateLimitError):
        _run(
            complete(
                LLMCredential("anthropic", api_key="k"),
                system="S",
                text="t",
                max_output_tokens=5,
                transport=transport,
            )
        )


@pytest.mark.parametrize(
    ("url", "free"),
    [
        ("http://localhost:8000/v1", True),
        ("http://127.0.0.1:8000/v1", True),
        ("http://192.168.1.20:8000/v1", True),
        ("https://api.together.xyz/v1", False),
    ],
)
def test_custom_server_on_this_network_is_free(url: str, free: bool) -> None:
    credential = LLMCredential("custom", model="m", base_url=url)
    assert (credential.price.cost(10**6, 10**6) == 0) is free
    assert credential.is_priced is free


def test_section_reservation_applies_long_context_rate_per_chunk() -> None:
    credential = LLMCredential("xai", api_key="k")
    one_chunk = LLMCleaner.section_reservation_cost_usd(
        480_000, 1, tier="standard", credential=credential
    )
    two_chunks = LLMCleaner.section_reservation_cost_usd(
        960_000, 2, tier="standard", credential=credential
    )
    assert two_chunks == pytest.approx(2 * one_chunk)


def test_gemini_variant_is_not_reported_as_priced() -> None:
    assert LLMCleaner.is_priced(LLMCredential.gemini("k")) is True
    other = LLMCredential("google", api_key="k", model="gemini-9-pro")
    assert LLMCleaner.is_priced(other) is False
    assert LLMCleaner.clean_reservation_cost_usd(
        4000, tier="standard", credential=other
    ) > LLMCleaner.clean_reservation_cost_usd(4000, tier="standard")


def test_truncated_completion_is_incomplete() -> None:
    transport, _ = _transport(lambda _r: _openai_reply("half", finish="length"))
    with pytest.raises(LLMIncompleteError):
        _run(
            complete(
                LLMCredential("cerebras", api_key="k"),
                system="S",
                text="t",
                max_output_tokens=5,
                transport=transport,
            )
        )


def test_unreachable_local_server_names_the_app() -> None:
    def refuse(request):
        raise httpx.ConnectError("refused", request=request)

    transport, _ = _transport(refuse)
    with pytest.raises(LLMUnreachableError, match="Make sure it is running"):
        _run(
            complete(
                LLMCredential("ollama", model="qwen3"),
                system="S",
                text="t",
                max_output_tokens=5,
                transport=transport,
            )
        )


def test_list_models_filters_non_chat_models() -> None:
    payload = {
        "data": [
            {"id": "gpt-6-luna"},
            {"id": "text-embedding-3-small"},
            {"id": "whisper-1"},
            {"id": "gpt-6-astra"},
        ]
    }
    transport, seen = _transport(lambda _r: httpx.Response(200, json=payload))
    models = _run(list_models(LLMCredential("openai", api_key="sk"), transport))
    assert models == ["gpt-6-astra", "gpt-6-luna"]
    assert str(seen[0].url) == "https://api.openai.com/v1/models"


def test_openrouter_checks_the_key_endpoint() -> None:
    transport, seen = _transport(lambda _r: httpx.Response(200, json={"data": {}}))
    models = _run(list_models(LLMCredential("openrouter", api_key="or"), transport))
    assert models == []
    assert str(seen[0].url) == "https://openrouter.ai/api/v1/key"


def test_local_and_listed_models_are_priced_unlisted_ones_are_budgeted() -> None:
    assert LLMCredential("ollama", model="anything").price.cost(10**6, 10**6) == 0
    assert LLMCredential("openai").price.cost(10**6, 10**6) == pytest.approx(0.60)
    assert LLMCredential("openai", model="gpt-x").price == UNLISTED_MODEL_PRICE
    assert LLMCredential("cerebras").price == UNLISTED_MODEL_PRICE


def test_anthropic_long_prompt_uses_long_context_rate() -> None:
    price = LLMCredential("anthropic").price
    assert price.cost(100_000, 0) == pytest.approx(0.01)
    assert price.cost(200_000, 0) == pytest.approx(0.10)


def test_cost_estimate_follows_the_chosen_provider() -> None:
    chars = 4_000_000
    local = LLMCleaner.estimate_max_cost_usd(chars, LLMCredential("lmstudio"))
    gemini = LLMCleaner.estimate_max_cost_usd(chars)
    assert local == 0
    assert gemini > 0


def test_credential_repr_never_contains_the_key() -> None:
    assert "secret" not in repr(LLMCredential("openai", api_key="secret"))


def test_text_only_models_are_known() -> None:
    assert LLMCredential("groq").spec.supports_vision("openai/gpt-oss-120b") is False
    assert LLMCredential("openai").spec.supports_vision("gpt-6-luna") is True
    assert LLMCredential("ollama").spec.supports_vision("llava") is None
