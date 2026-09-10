from unittest.mock import MagicMock, patch

import numpy as np
import pytest

from app.services.audio import AudioService
from app.services.tts import TTSEngine


class MockKokoro:
    def create(self, text, voice, speed, lang):
        # Return dummy audio (1 second of ones)
        return np.ones(24000, dtype=np.float32), None


@pytest.fixture(autouse=True)
def setup_tts_engine():
    # Only initialize the executor for tests, don't load the real model
    import concurrent.futures

    if TTSEngine._executor is None:
        TTSEngine._executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)

    # Reset state including lookahead cache
    TTSEngine._model = None
    TTSEngine._lookahead_cache.clear()
    yield
    TTSEngine._lookahead_cache.clear()


@pytest.mark.asyncio
async def test_tts_engine_sentence_splitting():
    # We want to test that the sentence splitting logic works
    with patch.object(TTSEngine, "_model", MockKokoro()):
        text = "Hello world. This is a test! Does it work?"

        mock_model = MagicMock()
        mock_model.create.return_value = (np.ones(100), None)
        TTSEngine._model = mock_model

        gen = TTSEngine.generate(text, "af_bella", 1.0)
        chunks = []
        async for chunk in gen:
            chunks.append(chunk)

        # "Hello world." "This is a test!" "Does it work?"
        # Each yields ONE atomic chunk (audio + trailing silence)
        # Total chunks = 3
        assert len(chunks) == 3
        assert mock_model.create.call_count == 3


@pytest.mark.asyncio
async def test_tts_engine_empty_text():
    with patch.object(TTSEngine, "_model", MockKokoro()):
        gen = TTSEngine.generate("", "af_bella", 1.0)
        chunks = []
        async for chunk in gen:
            chunks.append(chunk)
        # Yields 0 chunks for empty text
        assert len(chunks) == 0


@pytest.mark.asyncio
async def test_tts_engine_newlines():
    with patch.object(TTSEngine, "_model", MockKokoro()):
        text = "Hi there"
        mock_model = MagicMock()
        mock_model.create.return_value = (np.ones(100), None)
        TTSEngine._model = mock_model

        gen = TTSEngine.generate(text, "af_bella", 1.0)
        async for _ in gen:
            pass

        # "Hi there" is 2 words (< _NORMAL_SEG_WORDS, no punctuation) → one segment
        assert mock_model.create.call_count == 1
        call_args = mock_model.create.call_args[0]
        assert "Hi there" in call_args[0]


@pytest.mark.asyncio
async def test_tts_engine_no_inter_segment_fades():
    # Verify that inter-segment fades are NOT applied (removed to prevent volume dips)
    with patch.object(TTSEngine, "_model", MockKokoro()):
        # "Good morning. How are you today?" → 2 segments:
        # "Good morning." (ends with '.') and "How are you today?" (ends with '?')
        text = "Good morning. How are you today?"

        mock_model = MagicMock()
        mock_model.create.return_value = (np.ones(100), None)
        TTSEngine._model = mock_model

        with patch(
            "app.services.tts.AudioService.apply_fade", wraps=AudioService.apply_fade
        ) as mock_fade:
            gen = TTSEngine.generate(text, "af_bella", 1.0)
            async for _ in gen:
                pass

            # apply_fade should NOT be called from generate() anymore
            assert mock_fade.call_count == 0


@pytest.mark.asyncio
async def test_generate_passes_lang_through_to_model_create():
    """Regression: SpeakRequest.lang was accepted by the API but silently
    dropped everywhere downstream — every call to _model.create hardcoded
    "en-us" regardless of what was actually requested, so non-English text
    was always phonemized with English rules. lang must now actually reach
    the model."""
    mock_model = MagicMock()
    mock_model.create.return_value = (np.ones(100), None)
    TTSEngine._model = mock_model

    gen = TTSEngine.generate("Bonjour le monde", "af_bella", 1.0, "fr-fr")
    async for _ in gen:
        pass

    calls = mock_model.create.call_args_list
    assert calls, "model.create was never called"
    for call in calls:
        assert call[0][3] == "fr-fr", f"expected lang='fr-fr', got {call[0][3]!r}"


@pytest.mark.asyncio
async def test_generate_defaults_lang_to_en_us_when_unspecified():
    """Default must stay en-us so every existing caller's behavior is
    unchanged unless it explicitly passes a different lang."""
    mock_model = MagicMock()
    mock_model.create.return_value = (np.ones(100), None)
    TTSEngine._model = mock_model

    gen = TTSEngine.generate("Hello world", "af_bella", 1.0)
    async for _ in gen:
        pass

    calls = mock_model.create.call_args_list
    assert calls, "model.create was never called"
    assert calls[0][0][3] == "en-us"


@pytest.mark.asyncio
async def test_tts_engine_not_initialized():
    TTSEngine._model = None
    with pytest.raises(RuntimeError, match="Model not initialized"):
        gen = TTSEngine.generate("test", "af_bella", 1.0)
        async for _ in gen:
            pass


@pytest.mark.asyncio
async def test_lookahead_cache_hit_skips_inference():
    """Cache hit: first segment is served from cache without calling model.create."""
    mock_model = MagicMock()
    mock_model.create.return_value = (np.ones(100), None)
    TTSEngine._model = mock_model

    test_text = "Hello world. Great to meet you all."
    # Derive the exact first segment the way generate() does
    first_seg = TTSEngine._split_segments(test_text)[0]  # "Hello world." with period
    key = (first_seg, "af_bella", round(1.0, 2), "en-us")
    cached_audio = np.ones(50, dtype=np.float32) * 0.5
    TTSEngine._lookahead_cache[key] = cached_audio

    gen = TTSEngine.generate(test_text, "af_bella", 1.0)
    chunks = []
    async for chunk in gen:
        chunks.append(chunk)

    # model.create must NOT have been called for the first segment (cache hit)
    calls = mock_model.create.call_args_list
    called_texts = [c[0][0] for c in calls]
    assert first_seg not in called_texts, "model.create was called for cached segment"
    # Cache entry must be consumed (popped)
    assert key not in TTSEngine._lookahead_cache


@pytest.mark.asyncio
async def test_prewarm_with_lookahead_populates_cache():
    """prewarm_with_lookahead() stores inference result in _lookahead_cache."""
    mock_model = MagicMock()
    cached_audio = np.ones(200, dtype=np.float32)
    mock_model.create.return_value = (cached_audio, None)
    TTSEngine._model = mock_model

    await TTSEngine.prewarm_with_lookahead("Hello world test phrase", "af_bella", 1.0)

    # "Hello world test phrase" has no punctuation and 4 words < _NORMAL_SEG_WORDS,
    # so it stays as a single segment (no force-split at 2 words anymore).
    expected_seg = "Hello world test phrase"
    key = (expected_seg, "af_bella", 1.0, "en-us")
    assert key in TTSEngine._lookahead_cache
    assert TTSEngine._lookahead_cache[key] is cached_audio
    mock_model.create.assert_called_once_with(expected_seg, "af_bella", 1.0, "en-us")


@pytest.mark.asyncio
async def test_prewarm_with_lookahead_no_op_when_cached():
    """prewarm_with_lookahead() skips inference when key is already cached."""
    mock_model = MagicMock()
    TTSEngine._model = mock_model

    prewarm_text = "Hello world. Extra text."
    # Derive exact first segment to match the cache key generation in prewarm_with_lookahead
    first_seg = TTSEngine._split_segments(prewarm_text)[0]  # "Hello world." with period
    key = (first_seg, "af_bella", 1.0, "en-us")
    TTSEngine._lookahead_cache[key] = np.ones(50, dtype=np.float32)

    await TTSEngine.prewarm_with_lookahead(prewarm_text, "af_bella", 1.0)

    mock_model.create.assert_not_called()


@pytest.mark.asyncio
async def test_lookahead_cache_evicts_oldest_when_full():
    """When cache is full, the oldest entry is evicted before adding a new one."""
    mock_model = MagicMock()
    mock_model.create.return_value = (np.ones(50, dtype=np.float32), None)
    TTSEngine._model = mock_model

    # Fill cache to capacity
    for i in range(TTSEngine._MAX_CACHE_ENTRIES):
        TTSEngine._lookahead_cache[(f"seg{i}", "af_bella", 1.0, "en-us")] = np.zeros(10)

    oldest_key = ("seg0", "af_bella", 1.0, "en-us")
    assert oldest_key in TTSEngine._lookahead_cache

    await TTSEngine.prewarm_with_lookahead("New entry here today", "af_bella", 1.0)

    # Oldest must be gone; total entries stay at MAX_CACHE_ENTRIES
    assert oldest_key not in TTSEngine._lookahead_cache
    assert len(TTSEngine._lookahead_cache) == TTSEngine._MAX_CACHE_ENTRIES


@pytest.mark.asyncio
async def test_speed_scaled_pauses():
    """Verify that pause durations scale inversely with speed (faster = shorter pauses)."""
    mock_model = MagicMock()
    # Return dummy audio: 1 second of samples at 24kHz
    mock_model.create.return_value = (np.ones(24000, dtype=np.float32), None)
    TTSEngine._model = mock_model

    # Test text with punctuation to trigger pauses
    text = "Hello world. This is great!"

    # Generate at 1.0x speed
    gen_1x = TTSEngine.generate(text, "af_bella", 1.0)
    chunks_1x = []
    async for chunk in gen_1x:
        chunks_1x.append(chunk)
    total_samples_1x = sum(len(chunk) for chunk in chunks_1x)

    # Generate at 2.0x speed (should have shorter pauses)
    mock_model.reset_mock()
    gen_2x = TTSEngine.generate(text, "af_bella", 2.0)
    chunks_2x = []
    async for chunk in gen_2x:
        chunks_2x.append(chunk)
    total_samples_2x = sum(len(chunk) for chunk in chunks_2x)

    # At 2.0x speed with speed-scaled pauses, total duration should be shorter
    # (speech is same length since speed only affects pause duration, not phoneme timing)
    # Actually, speed parameter affects the model.create output, so audio length differs.
    # The key validation: silence between "Hello world." and "This is great!" should be
    # half as long at 2.0x speed as at 1.0x speed.

    # Base pause for "." is 0.35s. At 24kHz:
    # 1.0x: 0.35 / 1.0 = 0.35s = 8400 samples
    # 2.0x: 0.35 / 2.0 = 0.175s = 4200 samples
    # Difference should be ~4200 samples (one pause worth)

    # We expect fewer samples at 2.0x due to faster playback + shorter pauses
    assert total_samples_2x < total_samples_1x


def test_initialize_disables_onnx_spinning():
    """ORT's allow_spinning defaults to enabled, which busy-waits between
    inferences (see jira-cpu-ram-optimization.md). initialize() must
    explicitly disable it rather than relying on the default."""
    TTSEngine._model = None
    mock_session_options = MagicMock()

    with (
        patch("app.services.tts.ort.SessionOptions", return_value=mock_session_options),
        patch("app.services.tts.ort.InferenceSession", return_value=MagicMock()),
        patch("app.services.tts.Kokoro.from_session", return_value=MockKokoro()),
    ):
        TTSEngine.initialize()

    mock_session_options.add_session_config_entry.assert_called_once_with(
        "session.intra_op.allow_spinning", "0"
    )


# ---------- /speak normalizes at the API boundary ----------


def test_speak_request_strips_markdown_at_the_boundary():
    """The backend must not trust a client to have stripped Markdown.

    /speak is the one endpoint that takes arbitrary user text -- a clipboard
    selection, often lifted straight out of a README -- and hands it to the
    phonemizer. It previously applied only .strip(), so anything the Swift
    client's own (weaker) stripper missed was vocalized as "hash",
    "asterisk", "pipe".
    """
    from app.api.tts import SpeakRequest
    from app.services.text_normalizer import has_residual_markup

    req = SpeakRequest(
        text="## Section name\n\n**Bold** and `code`.\n\n> A quote.\n\n| a | b |"
    )
    assert has_residual_markup(req.text) == [], req.text
    assert "Section name" in req.text
    assert "Bold" in req.text


def test_prewarm_normalization_matches_speak():
    """Otherwise the lookahead cache silently never hits.

    The cache is keyed on the first *segment* of the text. If /prewarm cached
    a segment built from un-stripped text while /speak strips, the two compute
    different keys and the warm-up this endpoint exists to provide is wasted.
    """
    from app.api.tts import PrewarmRequest, SpeakRequest

    md = "# Title\n\nSome **bold** text to narrate."
    assert PrewarmRequest(text=md).text == SpeakRequest(text=md).text


def test_speak_rejects_text_that_is_entirely_markup():
    """Stripping can empty the input; that must 422, not synthesize silence."""
    import pytest
    from pydantic import ValidationError

    from app.api.tts import SpeakRequest

    with pytest.raises(ValidationError):
        SpeakRequest(text="---\n\n```\n```")
