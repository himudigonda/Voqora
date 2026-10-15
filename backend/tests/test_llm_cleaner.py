from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, patch

import pytest

from app.services import llm_providers
from app.services.llm_cleaner import (
    LLMAuthError,
    LLMBadResponseError,
    LLMBillingError,
    LLMCapacityError,
    LLMCleaner,
    LLMIncompleteError,
    LLMModelNotFoundError,
    LLMRateLimitError,
    LLMRequestRejectedError,
)
from app.services.llm_cleaner import types as gemini_types
from app.services.llm_providers import LLMCredential


@pytest.mark.parametrize(
    "msg",
    [
        "API key not valid",
        "Invalid api key supplied",
        "401 unauthorized",
        "permission denied for project",
        "credentials invalid",
    ],
)
def test_reraise_typed_classifies_auth_errors(msg: str) -> None:
    with pytest.raises(LLMAuthError):
        LLMCleaner._reraise_typed(RuntimeError(msg))


@pytest.mark.parametrize(
    "msg",
    [
        "429 too many requests",
        "rate limit exceeded",
        "quota exceeded",
        "RESOURCE_EXHAUSTED",
    ],
)
def test_reraise_typed_classifies_rate_limit_errors(msg: str) -> None:
    with pytest.raises(LLMRateLimitError):
        LLMCleaner._reraise_typed(RuntimeError(msg))


@pytest.mark.parametrize(
    "msg",
    [
        "model gemini-2.5-flash-fake not found",
        "404 not found",
        "model does not exist",
    ],
)
def test_reraise_typed_classifies_model_not_found_as_bad_response(msg: str) -> None:
    with pytest.raises(LLMBadResponseError):
        LLMCleaner._reraise_typed(RuntimeError(msg))


def test_reraise_typed_falls_through_to_bad_response() -> None:
    with pytest.raises(LLMBadResponseError):
        LLMCleaner._reraise_typed(RuntimeError("unspecified server error"))


@pytest.mark.parametrize(
    "msg",
    ["503 UNAVAILABLE. The model is overloaded", "service unavailable", "at capacity"],
)
def test_reraise_typed_classifies_capacity_errors(msg: str) -> None:
    with pytest.raises(LLMCapacityError):
        LLMCleaner._reraise_typed(RuntimeError(msg))


def test_reraise_typed_classifies_capacity_by_error_code() -> None:
    class FakeApiError(Exception):
        code = 503

    with pytest.raises(LLMCapacityError):
        LLMCleaner._reraise_typed(FakeApiError("server error"))


def test_with_retry_never_silently_falls_back_to_standard_after_capacity_errors(
    monkeypatch,
) -> None:
    monkeypatch.setattr(LLMCleaner, "_BACKOFF_BASE", 0.0)
    seen_tiers: list = []

    async def always_capacity_limited(tier):
        seen_tiers.append(tier)
        raise LLMCapacityError("503 UNAVAILABLE")

    with pytest.raises(LLMCapacityError):
        asyncio.run(LLMCleaner._with_retry("test", always_capacity_limited))
    assert seen_tiers == [gemini_types.ServiceTier.FLEX] * LLMCleaner._MAX_RETRIES


def test_with_retry_never_falls_back_below_flex_fallback_threshold(monkeypatch) -> None:
    monkeypatch.setattr(LLMCleaner, "_BACKOFF_BASE", 0.0)
    seen_tiers: list = []

    async def one_flex_failure_then_ok(tier):
        seen_tiers.append(tier)
        if len(seen_tiers) == 1:
            raise LLMCapacityError("503 UNAVAILABLE")
        return "ok"

    result = asyncio.run(LLMCleaner._with_retry("test", one_flex_failure_then_ok))
    assert result == "ok"
    assert seen_tiers == [gemini_types.ServiceTier.FLEX, gemini_types.ServiceTier.FLEX]


def _response(reason, text: str = "partial page"):
    class Candidate:
        finish_reason = reason

    class Response:
        candidates = [Candidate()]
        usage_metadata = None

    Response.text = text
    return Response()


@pytest.mark.parametrize(
    "reason",
    [
        gemini_types.FinishReason.MAX_TOKENS,
        gemini_types.FinishReason.RECITATION,
        gemini_types.FinishReason.SAFETY,
    ],
)
def test_truncated_page_is_rejected_instead_of_narrated(reason) -> None:
    with pytest.raises(LLMIncompleteError):
        LLMCleaner._require_complete(_response(reason))


def test_finished_or_unreported_page_is_accepted() -> None:
    LLMCleaner._require_complete(_response(gemini_types.FinishReason.STOP))
    LLMCleaner._require_complete(_response(None))


def test_with_retry_does_not_pay_again_for_a_deterministic_cutoff(monkeypatch) -> None:
    monkeypatch.setattr(LLMCleaner, "_BACKOFF_BASE", 0.0)
    calls = 0

    async def cut_off(tier):
        nonlocal calls
        calls += 1
        raise LLMIncompleteError("Gemini stopped early: RECITATION")

    with pytest.raises(LLMIncompleteError):
        asyncio.run(LLMCleaner._with_retry("test", cut_off))
    assert calls == 1


@pytest.mark.parametrize("chars,expected", [(0, 1), (4, 1), (40, 10), (4000, 1000)])
def test_estimate_tokens_rough_heuristic(chars: int, expected: int) -> None:
    assert LLMCleaner.estimate_tokens(chars) == expected


def test_estimate_cost_is_monotonic_in_chars() -> None:
    small = LLMCleaner.estimate_cost_usd(1000)
    large = LLMCleaner.estimate_cost_usd(1_000_000)
    assert 0 < small < large


def test_estimate_cost_is_nonzero_for_one_token() -> None:
    assert LLMCleaner.estimate_cost_usd(1) > 0


def test_usage_receipt_includes_thinking_tokens_in_billable_output() -> None:
    class FakeUsage:
        prompt_token_count = 101
        candidates_token_count = 17
        thoughts_token_count = 23

    class FakeResponse:
        usage_metadata = FakeUsage()

    receipt = LLMCleaner._usage_from_response(
        FakeResponse(), gemini_types.ServiceTier.FLEX
    )
    assert receipt is not None
    assert receipt.input_tokens == 101
    assert receipt.output_tokens == 40
    assert receipt.tier == "flex"


def test_reservation_envelope_is_conservative_for_image_input() -> None:
    text_only = LLMCleaner.clean_reservation_cost_usd(500, tier="flex")
    image = LLMCleaner.clean_reservation_cost_usd(500, tier="flex", image_input=True)
    assert image > text_only > 0


def test_parse_sections_strips_markdown_fences() -> None:
    raw = '```json\n{"sections":[{"title":"Intro","start_page":1,"end_page":3}]}\n```'
    out = LLMCleaner._parse_sections_json(raw, max_page=10)
    assert out == [{"title": "Intro", "start_page": 1, "end_page": 3}]


def test_parse_sections_clamps_end_page_to_max() -> None:
    raw = '{"sections":[{"title":"X","start_page":1,"end_page":999}]}'
    out = LLMCleaner._parse_sections_json(raw, max_page=10)
    assert out == [{"title": "X", "start_page": 1, "end_page": 10}]


def test_parse_sections_rejects_invalid_shapes() -> None:
    assert LLMCleaner._parse_sections_json("not json", max_page=10) == []
    assert LLMCleaner._parse_sections_json("[]", max_page=10) == []
    assert (
        LLMCleaner._parse_sections_json(
            '{"sections":[{"title":"","start_page":1,"end_page":2}]}', max_page=10
        )
        == []
    )
    assert (
        LLMCleaner._parse_sections_json(
            '{"sections":[{"title":"X","start_page":"a","end_page":"b"}]}',
            max_page=10,
        )
        == []
    )


def test_parse_sections_drops_items_starting_after_max_page() -> None:
    raw = '{"sections":[{"title":"OOB","start_page":99,"end_page":100}]}'
    assert LLMCleaner._parse_sections_json(raw, max_page=10) == []


def test_parse_sections_drops_inverted_ranges() -> None:
    raw = '{"sections":[{"title":"BadRange","start_page":5,"end_page":3}]}'
    assert LLMCleaner._parse_sections_json(raw, max_page=10) == []


def test_stitch_sections_inserts_front_matter_if_first_section_starts_late() -> None:
    sections = [{"title": "Chapter 1", "start_page": 5, "end_page": 10}]
    out = LLMCleaner._stitch_sections(sections, page_count=10)
    assert out[0]["title"] == "Front Matter"
    assert out[0]["start_page"] == 1
    assert out[0]["end_page"] == 4
    assert out[1]["title"] == "Chapter 1"


def test_stitch_sections_dedupes_overlapping_chunks() -> None:
    sections = [
        {"title": "A", "start_page": 1, "end_page": 5},
        {"title": "A", "start_page": 1, "end_page": 5},
        {"title": "B", "start_page": 6, "end_page": 10},
    ]
    out = LLMCleaner._stitch_sections(sections, page_count=10)
    assert [s["title"] for s in out] == ["A", "B"]


def test_stitch_sections_end_page_extends_to_doc_end_for_last_section() -> None:
    sections = [
        {"title": "A", "start_page": 1, "end_page": 3},
        {"title": "B", "start_page": 4, "end_page": 6},
    ]
    out = LLMCleaner._stitch_sections(sections, page_count=20)
    assert out[-1]["end_page"] == 20


def test_stitch_sections_returns_empty_list_for_empty_input() -> None:
    assert LLMCleaner._stitch_sections([], page_count=10) == []


def test_clean_page_empty_input_returns_dash_without_calling_api() -> None:
    result = asyncio.run(LLMCleaner.clean_page(LLMCredential.gemini("anything"), "   "))
    assert result == "-"


def test_clean_page_does_not_retry_on_auth_error() -> None:
    call_count = {"n": 0}

    async def fail_auth(*_args, **_kwargs):
        call_count["n"] += 1
        raise LLMAuthError("API key not valid")

    with patch.object(LLMCleaner, "_async_clean", side_effect=fail_auth):
        with pytest.raises(LLMAuthError):
            asyncio.run(LLMCleaner.clean_page("bad-key", "hello"))
    assert call_count["n"] == 1, "auth errors must short-circuit, never retry"


def test_clean_page_retries_on_rate_limit_then_succeeds(monkeypatch) -> None:
    monkeypatch.setattr(LLMCleaner, "_BACKOFF_BASE", 0.0)
    attempt = {"n": 0}

    async def flaky(*_args, **_kwargs):
        attempt["n"] += 1
        if attempt["n"] < 2:
            raise LLMRateLimitError("429")
        return "cleaned text"

    with patch.object(LLMCleaner, "_async_clean", side_effect=flaky):
        result = asyncio.run(LLMCleaner.clean_page("k", "hello"))
    assert result == "cleaned text"
    assert attempt["n"] == 2


def test_clean_page_exhausts_retries_then_raises(monkeypatch) -> None:
    monkeypatch.setattr(LLMCleaner, "_BACKOFF_BASE", 0.0)
    attempt = {"n": 0}

    async def always_bad(*_args, **_kwargs):
        attempt["n"] += 1
        raise LLMBadResponseError("nope")

    with patch.object(LLMCleaner, "_async_clean", side_effect=always_bad):
        with pytest.raises(LLMBadResponseError):
            asyncio.run(LLMCleaner.clean_page("k", "hello"))
    assert attempt["n"] == LLMCleaner._MAX_RETRIES


GOOD = LLMCredential.gemini("good")


def test_verify_true_on_success() -> None:
    with patch.object(LLMCleaner, "_async_clean", new=AsyncMock(return_value="ok")):
        assert asyncio.run(LLMCleaner.verify(GOOD)).ok is True


def test_verify_false_on_auth_failure() -> None:
    with patch.object(
        LLMCleaner, "_async_clean", new=AsyncMock(side_effect=LLMAuthError("bad"))
    ):
        result = asyncio.run(LLMCleaner.verify(LLMCredential.gemini("bad")))
    assert (result.ok, result.error) == (False, "bad")


def test_verify_false_on_any_other_exception(monkeypatch) -> None:
    monkeypatch.setattr(LLMCleaner, "_BACKOFF_BASE", 0.0)
    with patch.object(
        LLMCleaner,
        "_async_clean",
        new=AsyncMock(side_effect=RuntimeError("network")),
    ):
        assert asyncio.run(LLMCleaner.verify(GOOD)).ok is False


def test_verify_uses_standard_tier_not_flex() -> None:
    seen_tiers: list = []

    async def capture_tier(_credential, _text, tier):
        seen_tiers.append(tier)
        return "ok"

    with patch.object(LLMCleaner, "_async_clean", side_effect=capture_tier):
        assert asyncio.run(LLMCleaner.verify(GOOD)).ok is True

    assert seen_tiers == [gemini_types.ServiceTier.STANDARD]


def test_verify_rejects_missing_key_without_a_request() -> None:
    with patch.object(LLMCleaner, "_async_clean", new=AsyncMock()) as call:
        result = asyncio.run(LLMCleaner.verify(LLMCredential("openai")))
    assert (result.ok, result.error) == (False, "Missing API key for OpenAI.")
    call.assert_not_called()


def test_verify_lists_models_and_flags_an_unknown_model() -> None:
    credential = LLMCredential("ollama", model="llama9")
    missing = LLMModelNotFoundError("nope")
    with (
        patch.object(
            llm_providers,
            "list_model_ids",
            new=AsyncMock(return_value=["qwen3", "gemma4"]),
        ),
        patch.object(llm_providers, "complete", new=AsyncMock(side_effect=missing)),
    ):
        result = asyncio.run(LLMCleaner.verify(credential))
    assert result.ok is False
    assert result.models == ["gemma4", "qwen3"]
    assert result.error == "Ollama has no model named llama9. Choose one from the list."


def test_verify_local_provider_without_model_returns_choices() -> None:
    with patch.object(
        llm_providers, "list_model_ids", new=AsyncMock(return_value=["qwen3"])
    ):
        result = asyncio.run(LLMCleaner.verify(LLMCredential("lmstudio")))
    assert (result.ok, result.models) == (False, ["qwen3"])
    assert result.error == "Choose a model for LM Studio."


def test_verify_key_times_out_instead_of_hanging_forever(monkeypatch) -> None:
    monkeypatch.setattr(LLMCleaner, "_VERIFY_KEY_TIMEOUT_S", 0.05)
    monkeypatch.setattr(LLMCleaner, "_BACKOFF_BASE", 0.0)

    async def hang_forever(*_args, **_kwargs):
        await asyncio.sleep(10)
        return "ok"

    with patch.object(LLMCleaner, "_async_clean", side_effect=hang_forever):
        result = asyncio.run(asyncio.wait_for(LLMCleaner.verify(GOOD), timeout=2.0))
    assert result.ok is False


def _api_error(code: int, status: str, message: str, details: list | None = None):
    from google.genai import errors

    body = {"error": {"code": code, "status": status, "message": message}}
    if details is not None:
        body["error"]["details"] = details
    cls = errors.ClientError if code < 500 else errors.ServerError
    return cls(code, body)


KEY_INVALID = _api_error(
    400,
    "INVALID_ARGUMENT",
    "API key not valid. Please pass a valid API key.",
    [{"reason": "API_KEY_INVALID"}],
)
FREE_TIER_ZERO = _api_error(
    429,
    "RESOURCE_EXHAUSTED",
    "You exceeded your current quota. Quota exceeded for metric "
    "generate_content_free_tier_requests, limit: 0, model: gemini-3.8-flash",
)
PER_MINUTE = _api_error(
    429,
    "RESOURCE_EXHAUSTED",
    "Quota exceeded for GenerateRequestsPerMinutePerProjectPerModel-FreeTier",
)
DAILY_QUOTA = _api_error(
    429,
    "RESOURCE_EXHAUSTED",
    "You exceeded your current quota, please check your plan and billing details. "
    "GenerateRequestsPerDayPerProjectPerModel-FreeTier",
)
BARE_EXHAUSTED = _api_error(
    429, "RESOURCE_EXHAUSTED", "Resource has been exhausted (e.g. check quota)."
)
BARE_EXCEEDED = _api_error(
    429,
    "RESOURCE_EXHAUSTED",
    "You exceeded your current quota, please check your plan and billing details.",
)


@pytest.mark.parametrize(
    ("error", "expected", "message"),
    [
        (BARE_EXHAUSTED, LLMRateLimitError, "Google is rate limiting this key"),
        (BARE_EXCEEDED, LLMRateLimitError, "Google is rate limiting this key"),
        (KEY_INVALID, LLMAuthError, "Google rejected the API key"),
        (
            _api_error(401, "UNAUTHENTICATED", "bad creds"),
            LLMAuthError,
            "Google rejected the API key",
        ),
        (
            _api_error(403, "PERMISSION_DENIED", "no access to gemini-3.8-flash"),
            LLMAuthError,
            "Google denied this key access to gemini-3.8-flash",
        ),
        (
            _api_error(404, "NOT_FOUND", "models/x is not found"),
            LLMModelNotFoundError,
            "Google has no model named gemini-3.8-flash for this key.",
        ),
        (
            FREE_TIER_ZERO,
            LLMBillingError,
            "Google's free tier has no quota for gemini-3.8-flash",
        ),
        (
            DAILY_QUOTA,
            LLMBillingError,
            "Google's quota for gemini-3.8-flash is used up or not enabled for this key.",
        ),
        (PER_MINUTE, LLMRateLimitError, "Google is rate limiting this key"),
        (
            _api_error(400, "INVALID_ARGUMENT", "Unsupported thinking budget"),
            LLMRequestRejectedError,
            "Google rejected the request: Unsupported thinking budget",
        ),
        (
            _api_error(503, "UNAVAILABLE", "The model is overloaded"),
            LLMCapacityError,
            "Google is busy right now",
        ),
        (
            _api_error(500, "INTERNAL", "boom"),
            LLMRateLimitError,
            "Google had a server problem (500)",
        ),
    ],
)
def test_gemini_api_errors_are_classified_by_code_and_status(
    error, expected, message
) -> None:
    with pytest.raises(expected) as raised:
        LLMCleaner._reraise_typed(error, LLMCredential.gemini("k"))
    assert message in raised.value.user_message
    assert raised.value.__cause__ is error


def test_gemini_message_naming_a_model_is_not_a_model_error() -> None:
    error = _api_error(
        403, "PERMISSION_DENIED", "Permission denied for model gemini-3.8-flash"
    )
    with pytest.raises(LLMAuthError):
        LLMCleaner._reraise_typed(error, LLMCredential.gemini("k"))


def test_gemini_timeout_is_a_retryable_timeout_message() -> None:
    with pytest.raises(LLMRateLimitError, match="Google didn't answer in time"):
        LLMCleaner._reraise_typed(TimeoutError(), LLMCredential.gemini("k"))


@pytest.mark.parametrize(
    "error", [LLMRequestRejectedError("bad"), LLMModelNotFoundError("x")]
)
def test_with_retry_does_not_retry_a_rejected_request(error, monkeypatch) -> None:
    monkeypatch.setattr(LLMCleaner, "_BACKOFF_BASE", 0.0)
    calls = 0

    async def rejected(tier):
        nonlocal calls
        calls += 1
        raise error

    with pytest.raises(type(error)):
        asyncio.run(LLMCleaner._with_retry("test", rejected))
    assert calls == 1


def test_with_retry_does_not_retry_billing_errors(monkeypatch) -> None:
    monkeypatch.setattr(LLMCleaner, "_BACKOFF_BASE", 0.0)
    calls = 0

    async def broke(tier):
        nonlocal calls
        calls += 1
        raise LLMBillingError("no credit")

    with pytest.raises(LLMBillingError):
        asyncio.run(LLMCleaner._with_retry("test", broke))
    assert calls == 1


def _gemini_client(generate):
    from types import SimpleNamespace

    return SimpleNamespace(
        aio=SimpleNamespace(models=SimpleNamespace(generate_content=generate))
    )


def test_verify_gemini_makes_exactly_one_standard_call_and_never_retries(
    monkeypatch,
) -> None:
    slept: list[float] = []

    async def record_sleep(seconds):
        slept.append(seconds)

    monkeypatch.setattr("app.services.llm_cleaner.asyncio.sleep", record_sleep)
    calls: list[dict] = []

    async def fail(**kwargs):
        calls.append(kwargs)
        raise _api_error(503, "UNAVAILABLE", "overloaded")

    monkeypatch.setattr(
        "app.services.llm_cleaner.genai.Client", lambda **_: _gemini_client(fail)
    )
    result = asyncio.run(LLMCleaner.verify(GOOD))
    assert result.ok is False
    assert result.error == "Google is busy right now. Try again shortly."
    assert len(calls) == 1
    assert calls[0]["config"].service_tier == gemini_types.ServiceTier.STANDARD
    assert slept == []


def test_verify_gemini_reports_the_real_model_not_found_reason() -> None:
    credential = LLMCredential("google", api_key="k", model="gemini-9-pro")
    error = _api_error(404, "NOT_FOUND", "models/gemini-9-pro is not found")
    calls = []

    async def fail(**kwargs):
        calls.append(kwargs)
        raise error

    with patch(
        "app.services.llm_cleaner.genai.Client", lambda **_: _gemini_client(fail)
    ):
        result = asyncio.run(LLMCleaner.verify(credential))
    assert result.error == "Google has no model named gemini-9-pro for this key."
    assert len(calls) == 1


def test_verify_gemini_unexpected_exception_gets_generic_message_and_is_logged(
    caplog,
) -> None:
    with (
        caplog.at_level("WARNING"),
        patch.object(
            LLMCleaner,
            "_async_clean",
            new=AsyncMock(side_effect=ZeroDivisionError("x")),
        ),
    ):
        result = asyncio.run(LLMCleaner.verify(GOOD))
    assert result.error == "Voqora could not verify Google. Try again."
    record = next(r for r in caplog.records if r.getMessage() == "llm.verify_failed")
    assert (record.provider, record.model) == ("google", "gemini-3.8-flash")
    assert record.error_type == "ZeroDivisionError"


def test_verify_gemini_timeout_message() -> None:
    async def hang(*_args, **_kwargs):
        await asyncio.sleep(10)

    with (
        patch.object(LLMCleaner, "_VERIFY_KEY_TIMEOUT_S", 0.05),
        patch.object(LLMCleaner, "_async_clean", side_effect=hang),
    ):
        result = asyncio.run(LLMCleaner.verify(GOOD))
    assert result.error == "Google didn't answer in time. Try again."


def test_verify_failure_log_carries_status_and_never_the_key(caplog) -> None:
    secret = "AIzaSyDUMMYKEYDUMMYKEY1234567890"
    error = _api_error(
        403, "PERMISSION_DENIED", f"key {secret} is blocked sk-ant-abcdef123456"
    )
    credential = LLMCredential.gemini(secret)
    with (
        caplog.at_level("WARNING"),
        patch.object(LLMCleaner, "_async_clean", new=AsyncMock(side_effect=error)),
    ):
        asyncio.run(LLMCleaner.verify(credential))
    records = [r for r in caplog.records if r.getMessage() == "llm.verify_failed"]
    assert records and records[0].http_status == 403
    for record in caplog.records:
        assert secret not in str(record.__dict__)
        assert "sk-ant-abcdef123456" not in str(record.__dict__)
    assert len(records[0].provider_message) <= 200


def _chat_ok():
    return AsyncMock(return_value=llm_providers.Completion("ok", 1, 1))


def test_verify_accepts_a_typed_model_missing_from_the_list_when_it_answers() -> None:
    credential = LLMCredential("openai", api_key="sk-test", model="gpt-image-mini")
    with (
        patch.object(
            llm_providers, "list_model_ids", new=AsyncMock(return_value=["gpt-6-luna"])
        ),
        patch.object(llm_providers, "complete", new=_chat_ok()) as chat,
    ):
        result = asyncio.run(LLMCleaner.verify(credential))
    assert result.ok is True
    chat.assert_awaited_once()


def test_verify_matches_ollama_latest_tag_without_a_completion() -> None:
    credential = LLMCredential("ollama", model="llama3")
    with (
        patch.object(
            llm_providers,
            "list_model_ids",
            new=AsyncMock(return_value=["llama3:latest", "qwen3:8b"]),
        ),
        patch.object(llm_providers, "complete", new=_chat_ok()) as chat,
    ):
        result = asyncio.run(LLMCleaner.verify(credential))
    assert result.ok is True
    chat.assert_not_called()


def test_verify_accepts_a_model_the_marker_filter_hides_when_listed() -> None:
    credential = LLMCredential("openai", api_key="sk-test", model="gpt-image-1")
    with (
        patch.object(
            llm_providers,
            "list_model_ids",
            new=AsyncMock(return_value=["gpt-image-1", "gpt-6-luna"]),
        ),
        patch.object(llm_providers, "complete", new=_chat_ok()) as chat,
    ):
        result = asyncio.run(LLMCleaner.verify(credential))
    assert (result.ok, result.models) == (True, ["gpt-6-luna"])
    chat.assert_not_called()


def test_verify_without_a_model_list_probes_with_one_tiny_completion() -> None:
    credential = LLMCredential(
        "custom", model="my-model", base_url="http://127.0.0.1:9/v1"
    )
    with (
        patch.object(
            llm_providers,
            "list_model_ids",
            new=AsyncMock(side_effect=llm_providers.LLMModelListUnavailableError("x")),
        ),
        patch.object(llm_providers, "complete", new=_chat_ok()) as chat,
    ):
        result = asyncio.run(LLMCleaner.verify(credential))
    assert (result.ok, result.models) == (True, [])
    chat.assert_awaited_once()
    assert chat.await_args.kwargs["max_output_tokens"] <= 64


def test_verify_without_a_model_list_or_model_asks_for_a_model() -> None:
    credential = LLMCredential("custom", base_url="http://127.0.0.1:9/v1")
    with patch.object(
        llm_providers,
        "list_model_ids",
        new=AsyncMock(side_effect=llm_providers.LLMModelListUnavailableError("x")),
    ):
        result = asyncio.run(LLMCleaner.verify(credential))
    assert result.error == "Choose a model for Custom Provider."


def test_verify_returns_the_providers_own_message_for_every_llm_error() -> None:
    credential = LLMCredential("openai", api_key="sk-test", model="gpt-6-luna")
    for error in (
        LLMBillingError("OpenAI is out of credit."),
        LLMRateLimitError("OpenAI is busy or rate limited (429)."),
        LLMBadResponseError("OpenAI returned an unexpected response."),
    ):
        with patch.object(
            llm_providers, "list_model_ids", new=AsyncMock(side_effect=error)
        ):
            result = asyncio.run(LLMCleaner.verify(credential))
        assert result.error == error.user_message


def test_verify_treats_a_truncated_probe_as_a_working_model() -> None:
    credential = LLMCredential("openai", api_key="sk-test", model="gpt-x")
    with (
        patch.object(llm_providers, "list_model_ids", new=AsyncMock(return_value=[])),
        patch.object(
            llm_providers,
            "complete",
            new=AsyncMock(side_effect=LLMIncompleteError("length")),
        ),
    ):
        assert asyncio.run(LLMCleaner.verify(credential)).ok is True


def test_verify_never_goes_through_with_retry(monkeypatch) -> None:
    async def forbidden(*_args, **_kwargs):
        raise AssertionError("verify must not retry")

    monkeypatch.setattr(LLMCleaner, "_with_retry", forbidden)
    with patch.object(LLMCleaner, "_async_clean", new=AsyncMock(return_value="ok")):
        assert asyncio.run(LLMCleaner.verify(GOOD)).ok is True
    credential = LLMCredential("ollama", model="m")
    with patch.object(
        llm_providers, "list_model_ids", new=AsyncMock(return_value=["m:latest"])
    ):
        assert asyncio.run(LLMCleaner.verify(credential)).ok is True
