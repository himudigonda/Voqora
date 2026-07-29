"""Tests for GeminiCleaner pure logic — error classification, cost estimation,
section JSON parsing, section stitching, and retry behavior with mocked network."""

from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock, patch

import pytest

from app.services.gemini_cleaner import (
    GeminiAuthError,
    GeminiBadResponseError,
    GeminiCleaner,
    GeminiRateLimitError,
)

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
    with pytest.raises(GeminiAuthError):
        GeminiCleaner._reraise_typed(RuntimeError(msg))


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
    with pytest.raises(GeminiRateLimitError):
        GeminiCleaner._reraise_typed(RuntimeError(msg))


@pytest.mark.parametrize(
    "msg",
    [
        "model gemini-2.5-flash-fake not found",
        "404 not found",
        "model does not exist",
    ],
)
def test_reraise_typed_classifies_model_not_found_as_bad_response(msg: str) -> None:
    with pytest.raises(GeminiBadResponseError):
        GeminiCleaner._reraise_typed(RuntimeError(msg))


def test_reraise_typed_falls_through_to_bad_response() -> None:
    with pytest.raises(GeminiBadResponseError):
        GeminiCleaner._reraise_typed(RuntimeError("unspecified server error"))


# ---------- cost / token estimation ----------


@pytest.mark.parametrize("chars,expected", [(0, 1), (4, 1), (40, 10), (4000, 1000)])
def test_estimate_tokens_rough_heuristic(chars: int, expected: int) -> None:
    assert GeminiCleaner.estimate_tokens(chars) == expected


def test_estimate_cost_is_monotonic_in_chars() -> None:
    small = GeminiCleaner.estimate_cost_usd(1000)
    large = GeminiCleaner.estimate_cost_usd(1_000_000)
    assert 0 < small < large


def test_estimate_cost_is_nonzero_for_one_token() -> None:
    assert GeminiCleaner.estimate_cost_usd(1) > 0


# ---------- section JSON parsing ----------


def test_parse_sections_strips_markdown_fences() -> None:
    raw = '```json\n{"sections":[{"title":"Intro","start_page":1,"end_page":3}]}\n```'
    out = GeminiCleaner._parse_sections_json(raw, max_page=10)
    assert out == [{"title": "Intro", "start_page": 1, "end_page": 3}]


def test_parse_sections_clamps_end_page_to_max() -> None:
    raw = '{"sections":[{"title":"X","start_page":1,"end_page":999}]}'
    out = GeminiCleaner._parse_sections_json(raw, max_page=10)
    assert out == [{"title": "X", "start_page": 1, "end_page": 10}]


def test_parse_sections_rejects_invalid_shapes() -> None:
    assert GeminiCleaner._parse_sections_json("not json", max_page=10) == []
    assert GeminiCleaner._parse_sections_json("[]", max_page=10) == []
    assert (
        GeminiCleaner._parse_sections_json(
            '{"sections":[{"title":"","start_page":1,"end_page":2}]}', max_page=10
        )
        == []
    )
    assert (
        GeminiCleaner._parse_sections_json(
            '{"sections":[{"title":"X","start_page":"a","end_page":"b"}]}',
            max_page=10,
        )
        == []
    )


def test_parse_sections_drops_items_starting_after_max_page() -> None:
    raw = '{"sections":[{"title":"OOB","start_page":99,"end_page":100}]}'
    assert GeminiCleaner._parse_sections_json(raw, max_page=10) == []


def test_parse_sections_drops_inverted_ranges() -> None:
    raw = '{"sections":[{"title":"BadRange","start_page":5,"end_page":3}]}'
    assert GeminiCleaner._parse_sections_json(raw, max_page=10) == []


# ---------- section stitching ----------


def test_stitch_sections_inserts_front_matter_if_first_section_starts_late() -> None:
    sections = [{"title": "Chapter 1", "start_page": 5, "end_page": 10}]
    out = GeminiCleaner._stitch_sections(sections, page_count=10)
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
    out = GeminiCleaner._stitch_sections(sections, page_count=10)
    assert [s["title"] for s in out] == ["A", "B"]


def test_stitch_sections_end_page_extends_to_doc_end_for_last_section() -> None:
    sections = [
        {"title": "A", "start_page": 1, "end_page": 3},
        {"title": "B", "start_page": 4, "end_page": 6},
    ]
    out = GeminiCleaner._stitch_sections(sections, page_count=20)
    assert out[-1]["end_page"] == 20


def test_stitch_sections_returns_empty_list_for_empty_input() -> None:
    assert GeminiCleaner._stitch_sections([], page_count=10) == []


# ---------- clean_page early-return ----------


def test_clean_page_empty_input_returns_dash_without_calling_api() -> None:
    """Empty input must short-circuit — no key, no network call."""
    result = asyncio.run(GeminiCleaner.clean_page(api_key="anything", raw_text="   "))
    assert result == "-"


# ---------- clean_page retry logic with mocked _async_clean ----------


def test_clean_page_does_not_retry_on_auth_error() -> None:
    call_count = {"n": 0}

    async def fail_auth(*_args, **_kwargs):
        call_count["n"] += 1
        raise GeminiAuthError("API key not valid")

    with patch.object(GeminiCleaner, "_async_clean", side_effect=fail_auth):
        with pytest.raises(GeminiAuthError):
            asyncio.run(GeminiCleaner.clean_page("bad-key", "hello"))
    assert call_count["n"] == 1, "auth errors must short-circuit, never retry"


def test_clean_page_retries_on_rate_limit_then_succeeds(monkeypatch) -> None:
    monkeypatch.setattr(GeminiCleaner, "_BACKOFF_BASE", 0.0)
    attempt = {"n": 0}

    async def flaky(*_args, **_kwargs):
        attempt["n"] += 1
        if attempt["n"] < 2:
            raise GeminiRateLimitError("429")
        return "cleaned text"

    with patch.object(GeminiCleaner, "_async_clean", side_effect=flaky):
        result = asyncio.run(GeminiCleaner.clean_page("k", "hello"))
    assert result == "cleaned text"
    assert attempt["n"] == 2


def test_clean_page_exhausts_retries_then_raises(monkeypatch) -> None:
    monkeypatch.setattr(GeminiCleaner, "_BACKOFF_BASE", 0.0)
    attempt = {"n": 0}

    async def always_bad(*_args, **_kwargs):
        attempt["n"] += 1
        raise GeminiBadResponseError("nope")

    with patch.object(GeminiCleaner, "_async_clean", side_effect=always_bad):
        with pytest.raises(GeminiBadResponseError):
            asyncio.run(GeminiCleaner.clean_page("k", "hello"))
    assert attempt["n"] == GeminiCleaner._MAX_RETRIES


# ---------- verify_key ----------


def test_verify_key_true_on_success() -> None:
    with patch.object(GeminiCleaner, "clean_page", new=AsyncMock(return_value="ok")):
        assert asyncio.run(GeminiCleaner.verify_key("good")) is True


def test_verify_key_false_on_auth_failure() -> None:
    with patch.object(
        GeminiCleaner, "clean_page", new=AsyncMock(side_effect=GeminiAuthError("bad"))
    ):
        assert asyncio.run(GeminiCleaner.verify_key("bad")) is False


def test_verify_key_false_on_any_other_exception() -> None:
    with patch.object(
        GeminiCleaner,
        "clean_page",
        new=AsyncMock(side_effect=RuntimeError("network")),
    ):
        assert asyncio.run(GeminiCleaner.verify_key("k")) is False
