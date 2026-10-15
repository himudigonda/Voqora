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
    LLMBillingError,
    LLMConfigError,
    LLMCredential,
    LLMError,
    LLMIncompleteError,
    LLMModelListUnavailableError,
    LLMModelNotFoundError,
    LLMRateLimitError,
    LLMRequestRejectedError,
    LLMUnreachableError,
    complete,
    list_model_ids,
    list_models,
    redact,
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


def _complete(credential: LLMCredential, handler):
    transport, seen = _transport(handler)
    outcome = complete(
        credential, system="S", text="t", max_output_tokens=5, transport=transport
    )
    return outcome, seen


def _error_reply(status: int, message: str, code: str = "") -> httpx.Response:
    return httpx.Response(status, json={"error": {"message": message, "code": code}})


def test_provider_error_message_is_included_and_sanitized() -> None:
    long_message = "model is   not\nenabled " + "x" * 400
    outcome, _ = _complete(
        LLMCredential("xai", api_key="xai-secretsecret1"),
        lambda _r: _error_reply(400, long_message + " xai-secretsecret1"),
    )
    with pytest.raises(LLMRequestRejectedError) as raised:
        _run(outcome)
    text = raised.value.user_message
    assert text.startswith("xAI rejected the request (400). (model is not enabled")
    assert "\n" not in text and "secretsecret" not in text
    assert len(text) < 240


def test_401_is_a_bad_key_with_the_provider_reason() -> None:
    outcome, _ = _complete(
        LLMCredential("openai", api_key="sk-test"),
        lambda _r: _error_reply(401, "Incorrect API key provided", "invalid_api_key"),
    )
    with pytest.raises(LLMAuthError, match="rejected the API key.*Incorrect API key"):
        _run(outcome)


def test_403_is_access_denied_for_the_model_not_a_bad_key() -> None:
    outcome, _ = _complete(
        LLMCredential("openai", api_key="sk-test"),
        lambda _r: _error_reply(403, "Project lacks access"),
    )
    with pytest.raises(LLMAuthError) as raised:
        _run(outcome)
    assert "denied this key access to gpt-6-luna" in raised.value.user_message
    assert "rejected the API key" not in raised.value.user_message


@pytest.mark.parametrize(
    "response",
    [
        _error_reply(402, "Payment required"),
        _error_reply(429, "You exceeded your current quota", "insufficient_quota"),
        _error_reply(400, "Your credit balance is too low to access the API"),
    ],
)
def test_billing_problems_are_non_retryable_and_say_so(response) -> None:
    outcome, _ = _complete(
        LLMCredential("anthropic", api_key="sk-ant-test"), lambda _r: response
    )
    with pytest.raises(LLMBillingError) as raised:
        _run(outcome)
    assert raised.value.retryable is False
    assert "credit or quota" in raised.value.user_message


def test_plain_429_stays_retryable() -> None:
    outcome, _ = _complete(
        LLMCredential("groq", api_key="gsk_test"),
        lambda _r: _error_reply(429, "Rate limit reached for requests"),
    )
    with pytest.raises(LLMRateLimitError) as raised:
        _run(outcome)
    assert raised.value.retryable is True
    assert "Rate limit reached" in raised.value.user_message


def test_chat_404_is_model_not_found_and_not_retryable() -> None:
    outcome, _ = _complete(
        LLMCredential("openai", api_key="sk-test", model="gpt-nope"),
        lambda _r: _error_reply(404, "The model `gpt-nope` does not exist"),
    )
    with pytest.raises(LLMModelNotFoundError) as raised:
        _run(outcome)
    assert raised.value.retryable is False
    assert raised.value.user_message.startswith("OpenAI has no model named gpt-nope.")


def test_non_json_error_body_does_not_leak_html() -> None:
    outcome, _ = _complete(
        LLMCredential("groq", api_key="gsk_test"),
        lambda _r: httpx.Response(502, text="<html>bad gateway</html>"),
    )
    with pytest.raises(LLMRateLimitError) as raised:
        _run(outcome)
    assert "<html>" not in raised.value.user_message


def test_every_llm_error_has_a_user_message() -> None:
    for cls in (
        LLMError,
        LLMConfigError,
        LLMAuthError,
        LLMBillingError,
        LLMUnreachableError,
        LLMRateLimitError,
        LLMBadResponseError,
        LLMRequestRejectedError,
        LLMModelNotFoundError,
        LLMModelListUnavailableError,
        LLMIncompleteError,
    ):
        assert cls("message").user_message == "message"


def test_provider_failures_are_logged_without_the_key(caplog) -> None:
    key = "sk-supersecretvalue99"
    outcome, _ = _complete(
        LLMCredential("openai", api_key=key),
        lambda _r: _error_reply(401, f"Incorrect API key provided: {key}"),
    )
    with caplog.at_level("WARNING"), pytest.raises(LLMAuthError):
        _run(outcome)
    record = next(
        r for r in caplog.records if r.getMessage() == "llm.provider_call_failed"
    )
    assert (record.provider, record.model, record.http_status) == (
        "openai",
        "gpt-6-luna",
        401,
    )
    assert record.error_type == "LLMAuthError"
    assert key not in str(record.__dict__)
    assert len(record.provider_message) <= 200


@pytest.mark.parametrize(
    "secret",
    [
        "AIzaSyA1234567890abcdef",
        "sk-proj-abcdefghijkl",
        "sk-ant-api03-abcdef",
        "xai-abcdefghij",
        "gsk_abcdefghij",
        "csk-abcdefghij",
        "sk-or-v1-abcdefghij",
    ],
)
def test_redact_removes_common_key_shapes(secret: str) -> None:
    assert secret not in redact(f"bad key {secret} here")
    assert secret not in redact(f"https://x/?key={secret}&a=1")


def test_redact_leaves_ordinary_words_alone() -> None:
    assert redact("task-management is risk-free") == "task-management is risk-free"


def test_redirects_are_never_followed() -> None:
    def redirect(request):
        if request.url.host == "evil.example":
            raise AssertionError("redirect was followed")
        return httpx.Response(302, headers={"location": "https://evil.example/x"})

    outcome, seen = _complete(
        LLMCredential("custom", model="m", base_url="http://127.0.0.1:9000/v1"),
        redirect,
    )
    with pytest.raises(LLMBadResponseError, match="redirect"):
        _run(outcome)
    assert len(seen) == 1


def test_redirect_on_model_list_is_not_followed() -> None:
    transport, seen = _transport(
        lambda _r: httpx.Response(307, headers={"location": "http://10.0.0.1/"})
    )
    with pytest.raises(LLMBadResponseError):
        _run(list_model_ids(LLMCredential("openai", api_key="sk-test"), transport))
    assert len(seen) == 1


@pytest.mark.parametrize("provider", ["openai", "anthropic", "xai", "groq", "google"])
def test_supplied_base_url_is_ignored_for_hosted_providers(provider: str) -> None:
    credential = LLMCredential(
        provider, api_key="k", base_url="https://attacker.example/v1"
    )
    assert "attacker" not in credential.resolved_base_url
    assert credential.resolved_base_url == PROVIDERS[provider].base_url.rstrip("/")


def test_hosted_key_is_never_sent_to_a_supplied_host() -> None:
    transport, seen = _transport(lambda _r: _openai_reply("ok"))
    _run(
        complete(
            LLMCredential("openai", api_key="sk-live", base_url="http://127.0.0.1:1"),
            system="S",
            text="t",
            max_output_tokens=5,
            transport=transport,
        )
    )
    assert seen[0].url.host == "api.openai.com"


@pytest.mark.parametrize("provider", ["custom", "ollama", "lmstudio"])
def test_local_style_providers_honor_a_supplied_base_url(provider: str) -> None:
    credential = LLMCredential(provider, base_url="http://192.168.1.5:8000/v1/")
    assert credential.resolved_base_url == "http://192.168.1.5:8000/v1"


@pytest.mark.parametrize(
    ("provider", "url", "problem"),
    [
        ("custom", "http://example.com/v1", "needs an https:// address"),
        ("custom", "http://169.254.169.254/latest", "link-local"),
        ("custom", "https://169.254.169.254/latest", "link-local"),
        ("ollama", "http://169.254.1.1:11434/v1", "link-local"),
        ("custom", "ftp://example.com/v1", "Enter a server URL"),
        ("custom", "file:///etc/passwd", "Enter a server URL"),
        ("custom", "example.com/v1", "Enter a server URL"),
    ],
)
def test_unsafe_custom_urls_are_rejected(provider: str, url: str, problem: str) -> None:
    credential = LLMCredential(provider, model="m", base_url=url)
    assert problem in (credential.problem() or "")


@pytest.mark.parametrize(
    "url",
    [
        "https://api.together.xyz/v1",
        "http://localhost:8000/v1",
        "http://127.0.0.1:8000/v1",
        "http://192.168.1.20:8000/v1",
        "http://10.0.0.4/v1",
        "http://studio.local:1234/v1",
        "http://[::1]:8000/v1",
    ],
)
def test_acceptable_custom_urls_pass(url: str) -> None:
    assert LLMCredential("custom", model="m", base_url=url).problem() is None


def test_link_local_server_is_never_contacted() -> None:
    credential = LLMCredential("custom", model="m", base_url="http://169.254.169.254")
    outcome, seen = _complete(credential, lambda _r: _openai_reply("x"))
    with pytest.raises(LLMConfigError, match="link-local"):
        _run(outcome)
    assert seen == []


@pytest.mark.parametrize("reason", ["end_turn", "eos", "stop_sequence", "STOP", None])
def test_benign_openai_finish_reasons_are_accepted(reason) -> None:
    transport, _ = _transport(lambda _r: _openai_reply("fine", finish=reason))
    result = _run(
        complete(
            LLMCredential("groq", api_key="k"),
            system="S",
            text="t",
            max_output_tokens=5,
            transport=transport,
        )
    )
    assert result.text == "fine"


@pytest.mark.parametrize("reason", ["length", "content_filter", "max_tokens"])
def test_length_style_finish_reasons_stay_incomplete(reason: str) -> None:
    transport, _ = _transport(lambda _r: _openai_reply("half", finish=reason))
    with pytest.raises(LLMIncompleteError):
        _run(
            complete(
                LLMCredential("groq", api_key="k"),
                system="S",
                text="t",
                max_output_tokens=5,
                transport=transport,
            )
        )


@pytest.mark.parametrize(
    ("reason", "ok"),
    [
        ("end_turn", True),
        ("stop_sequence", True),
        (None, True),
        ("eos", True),
        ("max_tokens", False),
        ("refusal", False),
    ],
)
def test_anthropic_stop_reasons(reason, ok: bool) -> None:
    def reply(_request):
        return httpx.Response(
            200,
            json={"content": [{"type": "text", "text": "x"}], "stop_reason": reason},
        )

    transport, _ = _transport(reply)
    call = complete(
        LLMCredential("anthropic", api_key="k"),
        system="S",
        text="t",
        max_output_tokens=5,
        transport=transport,
    )
    if ok:
        assert _run(call).text == "x"
    else:
        with pytest.raises(LLMIncompleteError):
            _run(call)


@pytest.mark.parametrize(
    "response",
    [
        httpx.Response(404, json={"error": "no such route"}),
        httpx.Response(405, text="method not allowed"),
        httpx.Response(501, text="not implemented"),
        httpx.Response(200, text="<html>hello</html>"),
        httpx.Response(200, json={"models": []}),
    ],
)
def test_servers_without_a_model_list_report_it_as_unavailable(response) -> None:
    transport, _ = _transport(lambda _r: response)
    credential = LLMCredential("custom", base_url="http://127.0.0.1:9/v1")
    with pytest.raises(LLMModelListUnavailableError):
        _run(list_model_ids(credential, transport))


def test_model_list_auth_failure_is_still_an_auth_error() -> None:
    transport, _ = _transport(lambda _r: _error_reply(401, "bad key"))
    with pytest.raises(LLMAuthError):
        _run(list_model_ids(LLMCredential("openai", api_key="sk-test"), transport))


def test_anthropic_model_list_requests_a_large_page_and_follows_pagination() -> None:
    pages = {
        None: {
            "data": [{"id": "claude-a"}, {"id": "claude-b"}],
            "has_more": True,
            "last_id": "claude-b",
        },
        "claude-b": {
            "data": [{"id": "claude-c"}],
            "has_more": False,
            "last_id": "claude-c",
        },
    }

    def reply(request):
        assert request.url.params["limit"] == "1000"
        return httpx.Response(200, json=pages[request.url.params.get("after_id")])

    transport, seen = _transport(reply)
    ids = _run(
        list_model_ids(LLMCredential("anthropic", api_key="sk-ant-test"), transport)
    )
    assert ids == ["claude-a", "claude-b", "claude-c"]
    assert len(seen) == 2


def test_raw_model_ids_keep_models_the_chat_filter_hides() -> None:
    payload = {"data": [{"id": "gpt-image-1"}, {"id": "gpt-6-luna"}]}
    transport, _ = _transport(lambda _r: httpx.Response(200, json=payload))
    credential = LLMCredential("openai", api_key="sk-test")
    assert _run(list_model_ids(credential, transport)) == ["gpt-image-1", "gpt-6-luna"]
    assert _run(list_models(credential, transport)) == ["gpt-6-luna"]


def test_unknown_or_empty_provider_is_rejected_by_the_verify_endpoint() -> None:
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    empty = client.post("/llm/verify", json={"provider": ""})
    unknown = client.post("/llm/verify", json={"provider": "nope"})
    assert (empty.status_code, empty.json()["detail"]) == (
        400,
        "Choose an AI provider.",
    )
    assert (unknown.status_code, unknown.json()["detail"]) == (
        400,
        "Unknown AI provider.",
    )


@pytest.mark.parametrize(
    "url",
    [
        "https://user:pass@example.com/v1",
        "https://user@example.com/v1",
        "http://:secret@127.0.0.1:8000/v1",
    ],
)
def test_server_urls_with_userinfo_are_rejected(url: str) -> None:
    credential = LLMCredential("custom", model="m", base_url=url)
    assert credential.problem() == "Put the credential in API Key, not the address."


def test_userinfo_url_is_never_contacted_or_echoed() -> None:
    credential = LLMCredential(
        "custom", model="m", base_url="https://user:hunter2@example.com/v1"
    )
    outcome, seen = _complete(credential, lambda _r: _openai_reply("x"))
    with pytest.raises(LLMConfigError) as raised:
        _run(outcome)
    assert "hunter2" not in raised.value.user_message
    assert seen == []


def test_unreachable_message_shows_only_scheme_host_and_port() -> None:
    credential = LLMCredential(
        "custom",
        model="m",
        base_url="https://llm.example.com:8443/private/path/v1?token=abc",
    )
    message = _unreachable_message(credential)
    assert (
        message
        == "Voqora could not reach Custom Provider at https://llm.example.com:8443."
    )
    assert "private" not in message and "token" not in message


def _unreachable_message(credential: LLMCredential) -> str:
    def refuse(request):
        raise httpx.ConnectError("refused", request=request)

    outcome, _ = _complete(credential, refuse)
    with pytest.raises(LLMUnreachableError) as raised:
        _run(outcome)
    return raised.value.user_message


def test_display_base_url_handles_ipv6_and_missing_port() -> None:
    assert (
        LLMCredential("custom", base_url="http://[::1]:9000/v1").display_base_url
        == "http://[::1]:9000"
    )
    assert (
        LLMCredential("custom", base_url="https://example.com/v1").display_base_url
        == "https://example.com"
    )


@pytest.mark.parametrize(
    "key",
    ["sk-test\nInjected: 1", "sk-test\r", "sk-\x00abc", "sk-café", "a" * 513],
)
def test_malformed_keys_are_rejected_by_the_credential(key: str) -> None:
    credential = LLMCredential("openai", api_key=key)
    assert credential.problem() in (
        "The API key contains characters that aren't allowed.",
        "The API key is too long.",
    )


def test_key_at_the_length_limit_is_accepted() -> None:
    assert LLMCredential("openai", api_key="a" * 512).problem() is None


@pytest.mark.parametrize("key", ["sk-bad\nkey", "sk-café", "a" * 513])
def test_verify_endpoint_rejects_malformed_keys_without_echoing_them(key: str) -> None:
    from fastapi.testclient import TestClient

    from app.main import app

    response = TestClient(app).post(
        "/llm/verify", json={"provider": "openai", "api_key": key}
    )
    assert response.status_code == 400
    assert key not in response.text
    assert "API key" in response.json()["detail"]


def test_key_header_with_non_ascii_is_rejected_without_echo() -> None:
    from fastapi import HTTPException

    from app.api.audiobook import _provider_credential

    with pytest.raises(HTTPException) as raised:
        _provider_credential("openai", "sk-cafésecret", "", "")
    assert raised.value.status_code == 400
    assert "secret" not in str(raised.value.detail)


def test_log_failure_never_logs_a_malformed_key(caplog) -> None:
    from app.services.llm_providers import log_failure

    key = "sk-evil\nkey-with-newline-123"
    credential = LLMCredential("openai", api_key=key)
    with caplog.at_level("WARNING"):
        log_failure("llm.test", credential, ValueError(f"bad header {key!r} / {key}"))
    record = caplog.records[-1]
    blob = str(record.__dict__)
    assert "evil" not in blob and "key-with-newline" not in blob


def test_redact_hides_escaped_forms_of_a_key() -> None:
    key = "abc\ndef-secret-value"
    assert "secret-value" not in redact(f"value={key!r}", key)
    assert "secret-value" not in redact(f"value={key}", key)


@pytest.mark.parametrize(
    ("provider", "url", "key", "allowed"),
    [
        ("custom", "http://example.com/v1", "k-secret", False),
        ("custom", "http://192.168.1.20:8000/v1", "k-secret", False),
        ("custom", "http://studio.local:1234/v1", "k-secret", False),
        ("lmstudio", "http://192.168.1.20:1234/v1", "k-secret", False),
        ("custom", "https://192.168.1.20:8000/v1", "k-secret", True),
        ("custom", "http://localhost:8000/v1", "k-secret", True),
        ("custom", "http://127.0.0.1:8000/v1", "k-secret", True),
        ("custom", "http://127.5.5.5:8000/v1", "k-secret", True),
        ("custom", "http://[::1]:8000/v1", "k-secret", True),
        ("custom", "http://192.168.1.20:8000/v1", "", True),
        ("ollama", "http://192.168.1.20:11434/v1", "", True),
    ],
)
def test_plain_http_with_a_key_needs_a_loopback_host(
    provider: str, url: str, key: str, allowed: bool
) -> None:
    credential = LLMCredential(provider, api_key=key, model="m", base_url=url)
    assert (credential.problem() is None) is allowed


def test_key_is_never_sent_over_plain_http_to_a_lan_host() -> None:
    credential = LLMCredential(
        "custom", api_key="k-secret", model="m", base_url="http://192.168.1.20:8000/v1"
    )
    outcome, seen = _complete(credential, lambda _r: _openai_reply("x"))
    with pytest.raises(LLMConfigError, match="https://"):
        _run(outcome)
    assert seen == []
