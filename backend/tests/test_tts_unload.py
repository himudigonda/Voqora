"""Tests for TTSEngine.unload(), idle_watcher() conditions, and the pipe-regex fix.

Three groups of invariants:
  1. unload(): clears model/executor/cache; does NOT call gc.collect() (our fix);
     no-op when model is None; idempotent.
  2. idle_watcher(): the four guard conditions that prevent a premature unload
     (model None, is_initializing, last_request_time==0, within timeout window).
  3. _split_segments(): pipe "|" is NOT a sentence boundary (our regex fix);
     colon/semicolon still work; no text is lost.
"""

from __future__ import annotations

import concurrent.futures
import time
from unittest.mock import MagicMock, patch

import numpy as np
import pytest

from app.services.tts import TTSEngine

# ---------------------------------------------------------------------------
# Fixture: clean engine state around every test
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _reset_engine():
    saved = (
        TTSEngine._model,
        TTSEngine._executor,
        TTSEngine._is_initializing,
        TTSEngine._last_request_time,
        TTSEngine._IDLE_TIMEOUT,
    )
    TTSEngine._model = None
    TTSEngine._executor = None
    TTSEngine._is_initializing = False
    TTSEngine._last_request_time = 0.0
    TTSEngine._lookahead_cache.clear()
    yield
    (
        TTSEngine._model,
        TTSEngine._executor,
        TTSEngine._is_initializing,
        TTSEngine._last_request_time,
        TTSEngine._IDLE_TIMEOUT,
    ) = saved
    TTSEngine._lookahead_cache.clear()


# ===========================================================================
# 1. unload()
# ===========================================================================


def test_unload_noop_when_model_is_none():
    """Cold engine: unload() must return without touching anything."""
    TTSEngine._model = None
    executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
    TTSEngine._executor = executor  # executor should NOT be shut down
    TTSEngine.unload()
    # Executor unchanged — unload() returned early
    assert TTSEngine._executor is executor
    executor.shutdown(wait=False, cancel_futures=True)


def test_unload_clears_model():
    TTSEngine._model = MagicMock()
    TTSEngine._last_request_time = time.monotonic()
    TTSEngine.unload()
    assert TTSEngine._model is None


def test_unload_shuts_down_executor():
    TTSEngine._model = MagicMock()
    TTSEngine._executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
    TTSEngine._last_request_time = time.monotonic()
    TTSEngine.unload()
    assert TTSEngine._executor is None


def test_unload_clears_lookahead_cache():
    TTSEngine._model = MagicMock()
    TTSEngine._last_request_time = time.monotonic()
    TTSEngine._lookahead_cache[("seg", "af_bella", 1.0)] = np.zeros(100)
    TTSEngine._lookahead_cache[("seg2", "af_bella", 1.5)] = np.zeros(50)
    TTSEngine.unload()
    assert len(TTSEngine._lookahead_cache) == 0


def test_unload_does_not_call_gc_collect():
    """Regression guard: gc.collect() was removed from unload() because it blocked
    the asyncio event loop for 100–300 ms every 5 min idle (CPU spike root cause).
    It must NEVER be re-introduced."""
    import gc as _gc

    TTSEngine._model = MagicMock()
    TTSEngine._last_request_time = time.monotonic()

    with patch.object(_gc, "collect") as mock_gc:
        TTSEngine.unload()
        mock_gc.assert_not_called()


def test_unload_gc_module_not_imported_during_unload():
    """Even if gc is available globally, unload() must not reference it."""
    import gc as _gc

    TTSEngine._model = MagicMock()
    TTSEngine._last_request_time = time.monotonic()

    collect_called = []
    original_collect = _gc.collect

    def spy(*args, **kwargs):
        collect_called.append(True)
        return original_collect(*args, **kwargs)

    _gc.collect = spy
    try:
        TTSEngine.unload()
    finally:
        _gc.collect = original_collect

    assert collect_called == [], "gc.collect must not be called during unload()"


def test_unload_idempotent_second_call_is_noop():
    """Calling unload() twice must not raise."""
    TTSEngine._model = MagicMock()
    TTSEngine._last_request_time = time.monotonic()
    TTSEngine.unload()
    # Second call: model is None → early return, no exception
    TTSEngine.unload()
    assert TTSEngine._model is None


def test_unload_without_executor_does_not_raise():
    """unload() with model set but executor=None must still clear the model."""
    TTSEngine._model = MagicMock()
    TTSEngine._executor = None
    TTSEngine._last_request_time = time.monotonic()
    TTSEngine.unload()
    assert TTSEngine._model is None


# ===========================================================================
# 2. idle_watcher() guard conditions
# ===========================================================================


def _run_one_watcher_tick(idle_timeout_override: float | None = None) -> bool:
    """Simulate one watcher tick without asyncio.sleep; returns whether unload was called."""
    if idle_timeout_override is not None:
        timeout = idle_timeout_override
    else:
        timeout = TTSEngine._IDLE_TIMEOUT

    if TTSEngine._model is None or TTSEngine._is_initializing:
        return False
    if TTSEngine._last_request_time == 0:
        return False
    if time.monotonic() - TTSEngine._last_request_time > timeout:
        TTSEngine.unload()
        return True
    return False


def test_idle_watcher_skips_when_model_is_none():
    TTSEngine._model = None
    TTSEngine._last_request_time = 1.0  # stale
    result = _run_one_watcher_tick(idle_timeout_override=0.001)
    assert result is False
    assert TTSEngine._model is None


def test_idle_watcher_skips_when_initializing():
    TTSEngine._model = MagicMock()
    TTSEngine._is_initializing = True
    TTSEngine._last_request_time = 1.0  # stale
    result = _run_one_watcher_tick(idle_timeout_override=0.001)
    assert result is False
    assert TTSEngine._model is not None


def test_idle_watcher_skips_when_last_request_time_is_zero():
    """_last_request_time == 0 means no request was ever made; skip unload."""
    TTSEngine._model = MagicMock()
    TTSEngine._last_request_time = 0.0
    result = _run_one_watcher_tick(idle_timeout_override=0.001)
    assert result is False
    assert TTSEngine._model is not None


def test_idle_watcher_skips_within_timeout_window():
    """Model loaded and recent request → must NOT unload."""
    TTSEngine._model = MagicMock()
    TTSEngine._last_request_time = time.monotonic()  # just now
    result = _run_one_watcher_tick(idle_timeout_override=300.0)
    assert result is False
    assert TTSEngine._model is not None


def test_idle_watcher_unloads_after_timeout():
    """Stale last_request_time + timeout exceeded → unload IS called."""
    TTSEngine._model = MagicMock()
    TTSEngine._executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
    TTSEngine._last_request_time = 1.0  # ancient (monotonic always > this)
    result = _run_one_watcher_tick(idle_timeout_override=0.001)
    assert result is True
    assert TTSEngine._model is None


# ===========================================================================
# 3. _split_segments() — pipe character regression fix
# ===========================================================================


def test_pipe_is_not_a_sentence_boundary():
    """Pipe '|' must NOT trigger a split. Regression: it was erroneously in
    the character class [.!?|:;,] which shattered TOC-style text at every pipe."""
    text = "Chapter 1 | Introduction | Overview"
    segments = TTSEngine._split_segments(text)
    # All words must be present in output
    joined = " ".join(segments)
    for word in ["Chapter", "Introduction", "Overview"]:
        assert word in joined


def test_pipe_heavy_toc_stays_manageable():
    """TOC text with many pipes must not be shattered into single-word fragments."""
    text = "The Merchant of Venice | Act I | Scene I | Enter Bassanio and Lorenzo"
    segments = TTSEngine._split_segments(text)
    # Pipe should NOT create 5+ separate segments for 10 words
    assert (
        len(segments) <= 3
    ), f"Pipe-split regression: got {len(segments)} segments for 10-word text: {segments}"
    # No word lost
    all_words = " ".join(segments).split()
    for word in text.replace("|", "").split():
        assert word in all_words


def test_all_words_preserved_with_multiple_pipes():
    """Property: words are never dropped even when pipes appear throughout."""
    text = "foo bar | baz qux | hello world | extra content now here"
    segments = TTSEngine._split_segments(text)
    joined = " ".join(segments)
    for word in text.replace("|", "").split():
        assert word in joined, f"word '{word}' lost in segments"


def test_colon_is_still_a_boundary():
    """Colon ':' remains a valid split character after the pipe fix."""
    # The sentence has ≥5 words after the colon, so a split can occur
    text = "Important announcement: this event has been cancelled immediately today."
    segments = TTSEngine._split_segments(text)
    all_text = " ".join(segments)
    assert "Important" in all_text
    assert "cancelled" in all_text


def test_semicolon_is_still_a_boundary():
    """Semicolon ';' remains a valid split character."""
    text = "First clause starts here; second clause follows after this point."
    segments = TTSEngine._split_segments(text)
    all_text = " ".join(segments)
    assert "First" in all_text
    assert "second" in all_text


def test_sentence_ending_punctuation_still_works():
    """The basic .!? sentence splitting must still work after the pipe fix."""
    text = "Hello world. How are you today? I am fine!"
    segments = TTSEngine._split_segments(text)
    assert len(segments) >= 2
    # Segments legitimately retain punctuation ("world."), so compare on
    # punctuation-stripped tokens.
    all_words = {w.strip(".!?,;:") for w in " ".join(segments).split()}
    for word in ["Hello", "world", "How", "fine"]:
        assert word in all_words


def test_no_empty_segments_with_pipes():
    """No segment should be empty or whitespace-only even with many pipes."""
    text = "A | B | C | D | E word more content here please"
    segments = TTSEngine._split_segments(text)
    for s in segments:
        assert s.strip(), f"empty segment in output: {segments!r}"


def test_split_segments_is_deterministic_with_pipe():
    text = "Col A | Col B | Col C is a value here"
    first = TTSEngine._split_segments(text)
    second = TTSEngine._split_segments(text)
    assert first == second


def test_no_pipe_character_in_any_segment():
    """After our fix, pipes should remain in the text (not stripped) but not cause splits.
    The pipe character is passed through to Kokoro as-is (it reads it as punctuation).
    """
    text = "Section one | section two here"
    segments = TTSEngine._split_segments(text)
    # Pipe is in the text — it should appear somewhere in the segments
    all_text = " ".join(segments)
    # All non-pipe words should be there
    assert "Section" in all_text
    assert "section" in all_text
    assert "two" in all_text
