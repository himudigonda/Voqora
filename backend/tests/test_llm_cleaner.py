"""Tests for LLMCleaner pure logic — error classification, cost estimation,
section JSON parsing, section stitching, and retry behavior with mocked network."""

from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, patch

import pytest

from app.services import llm_providers
from app.services.llm_cleaner import (
    LLMAuthError,
    LLMBadResponseError,
    LLMCapacityError,
    LLMCleaner,
    LLMIncompleteError,
    LLMRateLimitError,
)
from app.services.llm_cleaner import types as gemini_types
from app.services.llm_providers import LLMCredential

# ---------- error classification ----------


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


# ---------- Flex retry / explicit Standard approval ----------


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
    # Standard pricing needs a user-approved, separately budgeted request;
    # retries for a Flex request must remain in the original tier.
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
    # A single Flex 503 is below the fallback threshold — retry stays on Flex.
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


# ---------- cost / token estimation ----------


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


# ---------- section JSON parsing ----------


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


# ---------- section stitching ----------


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
        {"title": "A", "start_page": 1, "end_page": 5},  # exact dup
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


# ---------- clean_page early-return ----------


def test_clean_page_empty_input_returns_dash_without_calling_api() -> None:
    """Empty input must short-circuit — no key, no network call."""
    result = asyncio.run(LLMCleaner.clean_page(LLMCredential.gemini("anything"), "   "))
    assert result == "-"


# ---------- clean_page retry logic with mocked _async_clean ----------


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


# ---------- verify ----------

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
    """Key verification must never be subject to Flex's best-effort queuing."""
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
    with patch.object(
        llm_providers, "list_models", new=AsyncMock(return_value=["qwen3", "gemma4"])
    ):
        result = asyncio.run(LLMCleaner.verify(credential))
    assert result.ok is False
    assert result.models == ["qwen3", "gemma4"]
    assert "llama9" in (result.error or "")


def test_verify_local_provider_without_model_returns_choices() -> None:
    with patch.object(
        llm_providers, "list_models", new=AsyncMock(return_value=["qwen3"])
    ):
        result = asyncio.run(LLMCleaner.verify(LLMCredential("lmstudio")))
    assert (result.ok, result.models) == (False, ["qwen3"])


def test_verify_key_times_out_instead_of_hanging_forever(monkeypatch) -> None:
    """Regression: Standard-tier calls get no HttpOptions, which the genai SDK
    treats as an *unbounded* httpx timeout (see _async_clean). Before
    _VERIFY_KEY_TIMEOUT_S existed, a dropped-packet/offline network made this
    call — and the /llm/verify request it backs — hang forever
    instead of failing fast. Use a near-zero timeout so the test itself
    doesn't hang if the fix regresses.
    """
    monkeypatch.setattr(LLMCleaner, "_VERIFY_KEY_TIMEOUT_S", 0.05)
    monkeypatch.setattr(LLMCleaner, "_BACKOFF_BASE", 0.0)

    async def hang_forever(*_args, **_kwargs):
        await asyncio.sleep(10)
        return "ok"

    with patch.object(LLMCleaner, "_async_clean", side_effect=hang_forever):
        result = asyncio.run(asyncio.wait_for(LLMCleaner.verify(GOOD), timeout=2.0))
    assert result.ok is False
