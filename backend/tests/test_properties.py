"""Property-based tests via Hypothesis.

These tests probe invariants the unit tests can only sample. They cover
the privacy-critical and audio-critical surfaces where a regression
would be silent — corrupted PCM (clicks/pops/clipping), lost sentence
text, or logging extras crashing the JSON formatter and dropping
correlation context.
"""

from __future__ import annotations

import json
import logging

import numpy as np
import pytest
from hypothesis import HealthCheck, assume, given, settings
from hypothesis import strategies as st

from app.core.logging import (
    _JsonFormatter,
    current_correlation_id,
    set_correlation_id,
)
from app.services.audio import AudioService
from app.services.tts import TTSEngine

# ---------- AudioService.apply_fade ----------


@settings(max_examples=150, suppress_health_check=[HealthCheck.too_slow])
@given(
    samples=st.lists(
        st.floats(
            min_value=-1.0,
            max_value=1.0,
            allow_nan=False,
            allow_infinity=False,
            width=32,
        ),
        min_size=0,
        max_size=4096,
    ),
    fade_in=st.booleans(),
    fade_out=st.booleans(),
)
def test_apply_fade_preserves_length_and_does_not_clip(
    samples: list[float], fade_in: bool, fade_out: bool
) -> None:
    arr = np.asarray(samples, dtype=np.float32)
    out = AudioService.apply_fade(arr.copy(), fade_in=fade_in, fade_out=fade_out)
    assert len(out) == len(arr), "fade must preserve sample count"
    if out.size:
        assert np.all(np.isfinite(out)), "fade must never emit NaN/Inf"
        # The fade curves scale by 0.6–1.0 — output magnitude must not grow
        assert np.max(np.abs(out)) <= np.max(np.abs(arr)) + 1e-6


# ---------- TTSEngine._split_segments ----------


_SAFE_TEXT = st.text(
    alphabet=st.characters(
        whitelist_categories=("Lu", "Ll", "Nd", "Zs"), whitelist_characters=" .,!?;:"
    ),
    min_size=0,
    max_size=400,
)


@settings(max_examples=200, suppress_health_check=[HealthCheck.too_slow])
@given(text=_SAFE_TEXT)
def test_split_segments_reassembles_to_original_words(text: str) -> None:
    segments = TTSEngine._split_segments(text)
    # Concatenating segment words must equal original-text words (whitespace-
    # normalised). This is the privacy-adjacent invariant: the splitter must
    # never DROP user text, since dropped text would silently be omitted from
    # generation.
    original_words = text.replace("\n", " ").split()
    segment_words: list[str] = []
    for s in segments:
        segment_words.extend(s.split())
    assert segment_words == original_words


@settings(max_examples=100)
@given(text=_SAFE_TEXT)
def test_split_segments_emits_no_empty_strings(text: str) -> None:
    segments = TTSEngine._split_segments(text)
    assert all(s.strip() for s in segments), "no empty / whitespace-only segments"


def test_split_segments_empty_returns_empty_list() -> None:
    assert TTSEngine._split_segments("") == []
    assert TTSEngine._split_segments("   \n\t  ") == []


# ---------- Logging formatter robustness ----------


class _NonSerializable:
    """Object that JSON can't natively serialize — must not crash the formatter."""

    def __repr__(self) -> str:  # pragma: no cover - representation only
        return "<NonSerializable>"


@settings(max_examples=75, suppress_health_check=[HealthCheck.too_slow])
@given(
    extras=st.dictionaries(
        keys=st.text(
            alphabet=st.characters(whitelist_categories=("L", "N")),
            min_size=1,
            max_size=12,
        ),
        values=st.one_of(
            st.integers(min_value=-(2**31), max_value=2**31 - 1),
            st.floats(allow_nan=False, allow_infinity=False, width=32),
            st.text(max_size=64),
            st.booleans(),
            st.none(),
            st.lists(st.integers(), max_size=5),
        ),
        max_size=8,
    )
)
def test_logging_formatter_emits_valid_json_for_arbitrary_extras(
    extras: dict[str, object],
) -> None:
    # Do not generate framework or formatter-control keys. The explicit
    # formatter contract tracks stdlib additions such as ``taskName``; the
    # property test must verify arbitrary metadata rather than a field that
    # product code deliberately ignores or protects.
    record = logging.LogRecord(
        name="voqora.test",
        level=logging.INFO,
        pathname=__file__,
        lineno=1,
        msg="property test",
        args=None,
        exc_info=None,
    )
    reserved = (
        set(record.__dict__)
        | _JsonFormatter._SKIPPED_RECORD_KEYS
        | _JsonFormatter._PROTECTED_KEYS
    )
    assume(not (set(extras.keys()) & reserved))

    set_correlation_id("test-cid-properties")
    for k, v in extras.items():
        setattr(record, k, v)

    formatter = _JsonFormatter()
    out = formatter.format(record)
    parsed = json.loads(out)  # must be valid JSON

    assert parsed["msg"] == "property test"
    assert parsed["cid"] == current_correlation_id()
    for k, v in extras.items():
        # Values are either preserved as-is or coerced to string — the
        # contract is "never crash, never drop the message".
        assert k in parsed


def test_logging_formatter_handles_non_serializable_value_without_crashing() -> None:
    record = logging.LogRecord(
        name="voqora.test",
        level=logging.INFO,
        pathname=__file__,
        lineno=1,
        msg="non-serializable extra",
        args=None,
        exc_info=None,
    )
    record.bad = _NonSerializable()  # type: ignore[attr-defined]
    out = _JsonFormatter().format(record)
    parsed = json.loads(out)
    assert parsed["msg"] == "non-serializable extra"
    assert "bad" in parsed  # coerced, not dropped


# ---------- Determinism + idempotence guards ----------


@pytest.mark.parametrize(
    "text", ["", "Hello.", "First. Second. Third.", "no terminator"]
)
def test_split_segments_is_deterministic(text: str) -> None:
    first = TTSEngine._split_segments(text)
    second = TTSEngine._split_segments(text)
    assert first == second


def test_apply_fade_with_empty_is_a_noop() -> None:
    empty = np.zeros(0, dtype=np.float32)
    out = AudioService.apply_fade(empty)
    assert out.size == 0


# ---------- Silence cache (HARD-016) ----------


@given(
    speed=st.floats(min_value=0.5, max_value=2.0, allow_nan=False, allow_infinity=False)
)
def test_get_silence_populates_cache_on_first_use_and_hits_thereafter(
    speed: float,
) -> None:
    """Speed-scaled durations like `0.35 / speed` used to miss the pre-populated
    cache. HARD-016 made the cache lazy + rounded-key, so any reasonable duration
    populates on first call and hits on the second."""
    from app.services.audio import _SILENCE_CACHE

    _SILENCE_CACHE.clear()
    duration = round(0.35 / speed, 3)
    first = AudioService.get_silence(duration)
    second = AudioService.get_silence(duration)
    assert (duration, 24000) in _SILENCE_CACHE
    # Same array object reused on hit (we cap allocation to one per key).
    assert first is second


def test_get_silence_cache_capped() -> None:
    """Unbounded growth would be a slow leak under speed sweeps."""
    from app.services.audio import _SILENCE_CACHE, _SILENCE_CACHE_CAP

    _SILENCE_CACHE.clear()
    for i in range(_SILENCE_CACHE_CAP * 2):
        AudioService.get_silence(0.1 + i * 0.001)
    assert len(_SILENCE_CACHE) <= _SILENCE_CACHE_CAP


def test_get_silence_returns_correct_length() -> None:
    arr = AudioService.get_silence(0.5)
    assert arr.shape == (12000,)
    assert np.all(arr == 0)
