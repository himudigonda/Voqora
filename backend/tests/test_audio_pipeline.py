"""Audio pipeline integrity tests.

Deterministic tests: known PCM patterns → verify bytes are preserved exactly
through every transformation (clip, write, concat, page-to-time).

Non-deterministic / smoke tests: run through the real TTS engine (if loaded)
to catch format regressions that mocks would miss.

Key invariants:
  I1. WAV_HEADER_SIZE == 44 and every written WAV starts with "RIFF…WAVE".
  I2. _write_wav_from_samples preserves int16 PCM round-trip within ±1 LSB.
  I3. _phase_concat produces a WAV whose PCM body is the exact byte-for-byte
      concatenation of each per-page WAV's PCM body, in page order.
  I4. page_to_time[str(n)] == (sum of prior page PCM bytes) / (SR * 2).
  I5. total_audio_seconds == total_pcm_bytes / (SR * 2).
  I6. Silence pages produce exactly duration * SR samples of zeros.
  I7. Clipping: samples outside [-1, 1] are clamped before int16 conversion.
  I8. concat final WAV RIFF/data sizes match the actual file size.
  I9. Per-page WAV header has correct sample rate, channels, bit depth.
 I10. Multi-page concat matches independently-concatenated PCM.
 I11. Transcript JSON written by concat phase contains correct book_id and
      per-page text that matches what was written to the clean files.
"""

import asyncio
import os
import shutil
import struct
import tempfile
import wave
from unittest.mock import AsyncMock, patch

import numpy as np
import pytest

from app.services.audiobook_service import (
    BYTES_PER_SAMPLE,
    SAMPLE_RATE,
    WAV_HEADER_SIZE,
    AudiobookService,
    _wav_header,
)
from app.services.audiobook_store import AudiobookStore

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def isolated_dir(monkeypatch, tmp_path):
    class _S:
        @property
        def AUDIOBOOKS_DIR(self):
            return str(tmp_path)

    monkeypatch.setattr("app.services.audiobook_store.settings", _S())
    AudiobookStore._reset_for_tests()
    yield str(tmp_path)
    AudiobookStore._reset_for_tests()
    shutil.rmtree(str(tmp_path), ignore_errors=True)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _read_pcm_body(path: str) -> bytes:
    """Return the raw PCM bytes of a WAV file (everything after the 44-byte header)."""
    with open(path, "rb") as f:
        header = f.read(WAV_HEADER_SIZE)
        assert header[:4] == b"RIFF", f"Not a RIFF WAV: {path}"
        assert header[8:12] == b"WAVE"
        return f.read()


def _wav_header_fields(path: str) -> dict:
    """Parse the 44-byte WAV header fields from a file."""
    with open(path, "rb") as f:
        raw = f.read(WAV_HEADER_SIZE)
    assert len(raw) == WAV_HEADER_SIZE
    riff_id = raw[0:4]
    wave_id = raw[8:12]
    fmt_id = raw[12:16]
    (fmt_chunk_size,) = struct.unpack_from("<I", raw, 16)
    (audio_fmt,) = struct.unpack_from("<H", raw, 20)
    (channels,) = struct.unpack_from("<H", raw, 22)
    (sample_rate,) = struct.unpack_from("<I", raw, 24)
    (byte_rate,) = struct.unpack_from("<I", raw, 28)
    (block_align,) = struct.unpack_from("<H", raw, 32)
    (bits_per_sample,) = struct.unpack_from("<H", raw, 34)
    data_id = raw[36:40]
    (data_size,) = struct.unpack_from("<I", raw, 40)
    return dict(
        riff_id=riff_id,
        wave_id=wave_id,
        fmt_id=fmt_id,
        fmt_chunk_size=fmt_chunk_size,
        audio_fmt=audio_fmt,
        channels=channels,
        sample_rate=sample_rate,
        byte_rate=byte_rate,
        block_align=block_align,
        bits_per_sample=bits_per_sample,
        data_id=data_id,
        data_size=data_size,
    )


def _make_book(page_count: int = 3) -> str:
    bid = AudiobookStore.create_book("Test.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "Test.pdf", page_count, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    AudiobookStore.write_meta(bid, meta)
    return bid


def _write_sine_wav(path: str, freq_hz: float, n_samples: int) -> np.ndarray:
    """Write a pure sine wave WAV and return the int16 samples written."""
    t = np.arange(n_samples, dtype=np.float32) / SAMPLE_RATE
    f32 = np.sin(2 * np.pi * freq_hz * t).astype(np.float32)
    samples = (f32 * 32767).astype(np.int16)
    pcm = samples.tobytes()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(pcm)
    return samples


# ===========================================================================
# I1 – WAV_HEADER_SIZE = 44 and every written WAV starts with RIFF/WAVE
# ===========================================================================


def test_wav_header_size_constant():
    assert WAV_HEADER_SIZE == 44


def test_wav_header_builder_produces_44_bytes():
    h = _wav_header(1000)
    assert len(h) == 44


def test_wav_header_builder_fields():
    body = 48000  # 1s of int16 mono at 24000 Hz
    h = _wav_header(body)
    # Parse manually
    assert h[0:4] == b"RIFF"
    assert h[8:12] == b"WAVE"
    assert h[12:16] == b"fmt "
    (fmt_size,) = struct.unpack_from("<I", h, 16)
    assert fmt_size == 16  # standard PCM
    (audio_fmt,) = struct.unpack_from("<H", h, 20)
    assert audio_fmt == 1  # PCM
    (channels,) = struct.unpack_from("<H", h, 22)
    assert channels == 1
    (sr,) = struct.unpack_from("<I", h, 24)
    assert sr == SAMPLE_RATE
    (br,) = struct.unpack_from("<I", h, 28)
    assert br == SAMPLE_RATE * BYTES_PER_SAMPLE  # byte rate = SR * channels * bps/8
    (ba,) = struct.unpack_from("<H", h, 32)
    assert ba == BYTES_PER_SAMPLE  # block align = channels * bps/8
    (bps,) = struct.unpack_from("<H", h, 34)
    assert bps == 16
    assert h[36:40] == b"data"
    (data_size,) = struct.unpack_from("<I", h, 40)
    assert data_size == body


def test_riff_sizes_consistent_with_file_size(tmp_path):
    """I8: RIFF chunk size and data chunk size must match actual file."""
    bid = _make_book(2)
    for n in (1, 2):
        AudiobookService._write_silence_wav(AudiobookStore.page_audio_path(bid, n), 0.5)

    asyncio.get_event_loop().run_until_complete(
        AudiobookService._phase_concat(bid, AudiobookStore.read_meta(bid))
    )
    final = AudiobookStore.audio_path(bid)
    file_size = os.path.getsize(final)

    with open(final, "rb") as f:
        raw = f.read(44)

    (riff_size,) = struct.unpack_from("<I", raw, 4)
    (data_size,) = struct.unpack_from("<I", raw, 40)

    assert riff_size + 8 == file_size, "RIFF size mismatch"
    assert data_size == file_size - WAV_HEADER_SIZE, "data chunk size mismatch"


# ===========================================================================
# I2 – _write_wav_from_samples round-trip: float32 → int16 WAV → int16 back
# ===========================================================================


def test_write_wav_round_trip_exact(tmp_path):
    """Samples survive float32→int16 conversion within ±1 LSB."""
    rng = np.random.default_rng(42)
    f32 = rng.uniform(-1.0, 1.0, 24000).astype(np.float32)
    expected_int16 = (np.clip(f32, -1.0, 1.0) * 32767).astype(np.int16)

    path = str(tmp_path / "test.wav")
    AudiobookService._write_wav_from_samples(path, f32)

    pcm = _read_pcm_body(path)
    actual_int16 = np.frombuffer(pcm, dtype="<i2")  # little-endian int16

    assert len(actual_int16) == len(expected_int16)
    diff = np.abs(actual_int16.astype(np.int32) - expected_int16.astype(np.int32))
    assert diff.max() <= 1, f"Max round-trip error {diff.max()} LSB > 1"


def test_write_wav_correct_header(tmp_path):
    """I9: per-page WAV must have canonical 24kHz/16-bit/mono header."""
    path = str(tmp_path / "p.wav")
    AudiobookService._write_wav_from_samples(path, np.zeros(1200, dtype=np.float32))
    fields = _wav_header_fields(path)
    assert fields["riff_id"] == b"RIFF"
    assert fields["wave_id"] == b"WAVE"
    assert fields["fmt_id"] == b"fmt "
    assert fields["audio_fmt"] == 1
    assert fields["channels"] == 1
    assert fields["sample_rate"] == SAMPLE_RATE
    assert fields["bits_per_sample"] == 16
    assert fields["byte_rate"] == SAMPLE_RATE * BYTES_PER_SAMPLE
    assert fields["block_align"] == BYTES_PER_SAMPLE
    assert fields["data_id"] == b"data"
    assert fields["data_size"] == 1200 * BYTES_PER_SAMPLE


def test_write_wav_file_size_exact(tmp_path):
    n_samples = 7200
    path = str(tmp_path / "sz.wav")
    AudiobookService._write_wav_from_samples(
        path, np.zeros(n_samples, dtype=np.float32)
    )
    expected = WAV_HEADER_SIZE + n_samples * BYTES_PER_SAMPLE
    assert os.path.getsize(path) == expected


# ===========================================================================
# I7 – Clipping: samples outside [-1, 1] are clamped
# ===========================================================================


def test_clipping_positive_overflow(tmp_path):
    """Values > 1.0 are clamped to 32767."""
    samples = np.array([2.0, 10.0, 1.0001], dtype=np.float32)
    path = str(tmp_path / "clip_pos.wav")
    AudiobookService._write_wav_from_samples(path, samples)
    pcm = np.frombuffer(_read_pcm_body(path), dtype="<i2")
    assert pcm.max() == 32767
    assert pcm.min() >= -32768


def test_clipping_negative_overflow(tmp_path):
    """Values < -1.0 are clamped to -32767 (not -32768 due to *32767 scale)."""
    samples = np.array([-2.0, -10.0, -1.0001], dtype=np.float32)
    path = str(tmp_path / "clip_neg.wav")
    AudiobookService._write_wav_from_samples(path, samples)
    pcm = np.frombuffer(_read_pcm_body(path), dtype="<i2")
    assert pcm.min() == -32767


def test_in_range_samples_not_clipped(tmp_path):
    """Samples within [-1, 1] are preserved exactly (within ±1 LSB)."""
    samples = np.array([0.5, -0.5, 0.0, 0.9999, -0.9999], dtype=np.float32)
    path = str(tmp_path / "noclip.wav")
    AudiobookService._write_wav_from_samples(path, samples)
    pcm = np.frombuffer(_read_pcm_body(path), dtype="<i2")
    expected = (samples * 32767).astype(np.int16)
    assert np.all(np.abs(pcm.astype(np.int32) - expected.astype(np.int32)) <= 1)


# ===========================================================================
# I6 – Silence pages: correct duration and all-zero samples
# ===========================================================================


@pytest.mark.parametrize("duration", [0.3, 0.5, 1.0, 2.5])
def test_silence_wav_duration(tmp_path, duration):
    path = str(tmp_path / f"sil_{duration}.wav")
    AudiobookService._write_silence_wav(path, duration)
    expected_samples = int(duration * SAMPLE_RATE)
    pcm = _read_pcm_body(path)
    assert len(pcm) == expected_samples * BYTES_PER_SAMPLE
    assert all(b == 0 for b in pcm), "silence WAV must contain only zero bytes"


def test_silence_wav_correct_header(tmp_path):
    path = str(tmp_path / "sil.wav")
    AudiobookService._write_silence_wav(path, 1.0)
    fields = _wav_header_fields(path)
    assert fields["sample_rate"] == SAMPLE_RATE
    assert fields["bits_per_sample"] == 16
    assert fields["channels"] == 1
    assert fields["audio_fmt"] == 1


# ===========================================================================
# I3 / I10 – _phase_concat: exact byte concatenation in page order
# ===========================================================================


@pytest.mark.asyncio
async def test_concat_pcm_is_exact_byte_concat():
    """I3/I10: final WAV PCM body == byte-for-byte cat of all per-page PCM bodies."""
    bid = _make_book(4)
    expected_pcm = b""
    for n in range(1, 5):
        samples = _write_sine_wav(
            AudiobookStore.page_audio_path(bid, n),
            freq_hz=440 * n,
            n_samples=2400 * n,  # 0.1s * n
        )
        expected_pcm += samples.tobytes()

    await AudiobookService._phase_concat(bid, AudiobookStore.read_meta(bid))
    actual_pcm = _read_pcm_body(AudiobookStore.audio_path(bid))
    assert (
        actual_pcm == expected_pcm
    ), "PCM body mismatch — concat reordered or corrupted bytes"


@pytest.mark.asyncio
async def test_concat_with_missing_pages():
    """Pages with no audio file on disk are silently skipped."""
    bid = _make_book(3)
    # Only write pages 1 and 3 — page 2 is absent.
    _write_sine_wav(AudiobookStore.page_audio_path(bid, 1), 440, 4800)
    _write_sine_wav(AudiobookStore.page_audio_path(bid, 3), 880, 2400)

    await AudiobookService._phase_concat(bid, AudiobookStore.read_meta(bid))

    p1 = _read_pcm_body(AudiobookStore.page_audio_path(bid, 1))
    p3 = _read_pcm_body(AudiobookStore.page_audio_path(bid, 3))
    final = _read_pcm_body(AudiobookStore.audio_path(bid))
    assert final == p1 + p3


@pytest.mark.asyncio
async def test_concat_all_missing_produces_empty_wav():
    """No per-page WAVs → final file is a valid WAV with zero PCM bytes."""
    bid = _make_book(2)
    # Write no per-page WAVs.
    await AudiobookService._phase_concat(bid, AudiobookStore.read_meta(bid))
    final = AudiobookStore.audio_path(bid)
    assert os.path.exists(final)
    assert os.path.getsize(final) == WAV_HEADER_SIZE


# ===========================================================================
# I4 / I5 – page_to_time and total_audio_seconds
# ===========================================================================


@pytest.mark.asyncio
async def test_page_to_time_cumulative():
    """I4: page_to_time[n] == cumulative PCM bytes before page n / (SR * 2)."""
    bid = _make_book(3)
    sizes = [24000, 12000, 6000]  # samples per page
    for n, sz in enumerate(sizes, 1):
        path = AudiobookStore.page_audio_path(bid, n)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with wave.open(path, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(SAMPLE_RATE)
            wf.writeframes(np.zeros(sz, dtype=np.int16).tobytes())

    await AudiobookService._phase_concat(bid, AudiobookStore.read_meta(bid))
    meta = AudiobookStore.read_meta(bid)
    p2t = meta["page_to_time"]

    assert p2t["1"] == pytest.approx(0.0)
    assert p2t["2"] == pytest.approx(sizes[0] / SAMPLE_RATE)
    assert p2t["3"] == pytest.approx((sizes[0] + sizes[1]) / SAMPLE_RATE)


@pytest.mark.asyncio
async def test_total_audio_seconds():
    """I5: total_audio_seconds == total_pcm_bytes / (SR * 2)."""
    bid = _make_book(2)
    for n, sz in [(1, 48000), (2, 24000)]:
        path = AudiobookStore.page_audio_path(bid, n)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with wave.open(path, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(SAMPLE_RATE)
            wf.writeframes(np.zeros(sz, dtype=np.int16).tobytes())

    await AudiobookService._phase_concat(bid, AudiobookStore.read_meta(bid))
    meta = AudiobookStore.read_meta(bid)
    total_samples = 48000 + 24000
    expected_seconds = total_samples / SAMPLE_RATE
    assert meta["total_audio_seconds"] == pytest.approx(expected_seconds)


# ===========================================================================
# I11 – Transcript JSON integrity
# ===========================================================================


@pytest.mark.asyncio
async def test_transcript_json_written_and_correct():
    """I11: transcript.json contains book_id, page texts, page_to_time, sections."""
    import json

    bid = _make_book(2)
    for n in (1, 2):
        path = AudiobookStore.page_audio_path(bid, n)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with wave.open(path, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(SAMPLE_RATE)
            wf.writeframes(np.zeros(2400, dtype=np.int16).tobytes())
        # Write clean text for this page
        clean_path = AudiobookStore.page_clean_path(bid, n)
        os.makedirs(os.path.dirname(clean_path), exist_ok=True)
        with open(clean_path, "w") as f:
            f.write(f"Page {n} clean text.")

    await AudiobookService._phase_concat(bid, AudiobookStore.read_meta(bid))

    tpath = AudiobookStore.transcript_path(bid)
    assert os.path.exists(tpath), "transcript.json not written"
    with open(tpath) as f:
        t = json.load(f)

    assert t["book_id"] == bid
    assert "page_to_time" in t
    assert "sections" in t
    assert t["pages"]["1"] == "Page 1 clean text."
    assert t["pages"]["2"] == "Page 2 clean text."
    assert abs(t["total_audio_seconds"] - 2 * 2400 / SAMPLE_RATE) < 0.001


@pytest.mark.asyncio
async def test_transcript_missing_clean_file_still_writes():
    """Transcript is written even if some clean files are absent (graceful degradation)."""
    import json

    bid = _make_book(2)
    # Only page 1 has audio and clean text; page 2 has nothing.
    path = AudiobookStore.page_audio_path(bid, 1)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(np.zeros(2400, dtype=np.int16).tobytes())
    clean_path = AudiobookStore.page_clean_path(bid, 1)
    os.makedirs(os.path.dirname(clean_path), exist_ok=True)
    with open(clean_path, "w") as f:
        f.write("Only page one.")

    await AudiobookService._phase_concat(bid, AudiobookStore.read_meta(bid))

    tpath = AudiobookStore.transcript_path(bid)
    assert os.path.exists(tpath)
    with open(tpath) as f:
        t = json.load(f)
    assert "1" in t["pages"]
    assert "2" not in t["pages"]  # gracefully absent, not an error


# ===========================================================================
# TTS phase: WAV written per page and can be re-read
# ===========================================================================


async def _mock_generate(*args, **kwargs):
    yield np.sin(np.linspace(0, 2 * np.pi, 2400)).astype(np.float32)


@pytest.mark.asyncio
async def test_tts_phase_writes_valid_wavs(monkeypatch):
    bid = _make_book(2)
    for n in (1, 2):
        p = AudiobookStore.page_clean_path(bid, n)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(f"Page {n}.")

    with (
        patch(
            "app.services.audiobook_service.EngineManager.ensure_loaded",
            new=AsyncMock(),
        ),
        patch("app.services.audiobook_service.EngineManager.touch"),
        patch(
            "app.services.audiobook_service.EngineManager.generate",
            side_effect=_mock_generate,
        ),
    ):
        await AudiobookService._phase_tts(bid, AudiobookStore.read_meta(bid))

    for n in (1, 2):
        p = AudiobookStore.page_audio_path(bid, n)
        assert os.path.exists(p), f"page {n} WAV missing"
        fields = _wav_header_fields(p)
        assert fields["sample_rate"] == SAMPLE_RATE
        assert fields["bits_per_sample"] == 16
        assert fields["channels"] == 1
        assert fields["audio_fmt"] == 1
        assert fields["data_size"] > 0
        # PCM body must be valid int16 (not NaN/Inf)
        pcm = np.frombuffer(_read_pcm_body(p), dtype="<i2")
        assert len(pcm) > 0
        assert np.all(np.isfinite(pcm.astype(np.float32)))


@pytest.mark.asyncio
async def test_tts_blank_page_writes_silence(monkeypatch):
    """Pages containing only '-' produce a silence WAV, never call TTS."""
    bid = _make_book(1)
    p = AudiobookStore.page_clean_path(bid, 1)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write("-")

    generate_calls = []

    async def counting_generate(*a, **kw):
        generate_calls.append(1)
        yield np.zeros(100, dtype=np.float32)

    with (
        patch(
            "app.services.audiobook_service.EngineManager.ensure_loaded",
            new=AsyncMock(),
        ),
        patch("app.services.audiobook_service.EngineManager.touch"),
        patch(
            "app.services.audiobook_service.EngineManager.generate",
            side_effect=counting_generate,
        ),
    ):
        await AudiobookService._phase_tts(bid, AudiobookStore.read_meta(bid))

    assert len(generate_calls) == 0, "TTS must not be called for blank ('-') pages"
    out = AudiobookStore.page_audio_path(bid, 1)
    assert os.path.exists(out)
    pcm = _read_pcm_body(out)
    assert all(b == 0 for b in pcm), "blank page audio must be all silence"


@pytest.mark.asyncio
async def test_tts_failure_writes_silence_and_records_failed_page(monkeypatch):
    """When TTS raises for a page, a silence WAV is written and the page appears in failed_pages."""
    bid = _make_book(2)
    for n in (1, 2):
        p = AudiobookStore.page_clean_path(bid, n)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(f"Page {n}.")

    call_count = [0]

    async def flaky_generate(*a, **kw):
        call_count[0] += 1
        if call_count[0] == 1:
            raise RuntimeError("TTS exploded")
        yield np.zeros(100, dtype=np.float32)

    with (
        patch(
            "app.services.audiobook_service.EngineManager.ensure_loaded",
            new=AsyncMock(),
        ),
        patch("app.services.audiobook_service.EngineManager.touch"),
        patch(
            "app.services.audiobook_service.EngineManager.generate",
            side_effect=flaky_generate,
        ),
    ):
        await AudiobookService._phase_tts(bid, AudiobookStore.read_meta(bid))

    meta = AudiobookStore.read_meta(bid)
    assert 1 in meta["failed_pages"], "failed page 1 must be recorded"
    # Failed page still has a silence WAV so concat can proceed
    assert os.path.exists(AudiobookStore.page_audio_path(bid, 1))
    pcm = _read_pcm_body(AudiobookStore.page_audio_path(bid, 1))
    assert all(b == 0 for b in pcm)
    # Page 2 must have been written normally despite page 1 failing
    assert os.path.exists(AudiobookStore.page_audio_path(bid, 2))
    p2_pcm = _read_pcm_body(AudiobookStore.page_audio_path(bid, 2))
    assert len(p2_pcm) > 0


# ===========================================================================
# End-to-end pipeline: TTS → concat → verify final WAV is playable
# ===========================================================================


@pytest.mark.asyncio
async def test_end_to_end_pipeline_produces_valid_wav(monkeypatch):
    """Full extract→clean→TTS→concat smoke test (mocked I/O, real WAV writing)."""
    import json

    page_count = 3
    bid = _make_book(page_count)
    meta = AudiobookStore.read_meta(bid)

    # Write clean text for each page
    for n in range(1, page_count + 1):
        p = AudiobookStore.page_clean_path(bid, n)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(f"This is page {n} of the test audiobook.")

    # TTS: yield a short sine wave per page
    def make_page_generator(page_num):
        async def _gen(*a, **kw):
            freq = 220 * page_num
            t = np.linspace(0, 0.1, int(0.1 * SAMPLE_RATE), endpoint=False)
            yield (np.sin(2 * np.pi * freq * t) * 0.5).astype(np.float32)

        return _gen

    call_tracker = [0]

    async def rotating_generate(*a, **kw):
        call_tracker[0] += 1
        freq = 220 * call_tracker[0]
        t = np.linspace(0, 0.1, int(0.1 * SAMPLE_RATE), endpoint=False)
        yield (np.sin(2 * np.pi * freq * t) * 0.5).astype(np.float32)

    with (
        patch(
            "app.services.audiobook_service.EngineManager.ensure_loaded",
            new=AsyncMock(),
        ),
        patch("app.services.audiobook_service.EngineManager.touch"),
        patch(
            "app.services.audiobook_service.EngineManager.generate",
            side_effect=rotating_generate,
        ),
    ):
        await AudiobookService._phase_tts(bid, meta)

    actual = await AudiobookService._phase_concat(bid, AudiobookStore.read_meta(bid))

    # --- Final WAV exists and is a valid WAV ---
    final = AudiobookStore.audio_path(bid)
    assert os.path.exists(final)
    file_size = os.path.getsize(final)
    assert file_size > WAV_HEADER_SIZE

    # --- Header fields correct ---
    fields = _wav_header_fields(final)
    assert fields["riff_id"] == b"RIFF"
    assert fields["wave_id"] == b"WAVE"
    assert fields["sample_rate"] == SAMPLE_RATE
    assert fields["bits_per_sample"] == 16
    assert fields["channels"] == 1
    assert fields["data_size"] == file_size - WAV_HEADER_SIZE

    # --- RIFF size consistent ---
    (riff_size,) = struct.unpack_from("<I", open(final, "rb").read(8), 4)
    assert riff_size + 8 == file_size

    # --- PCM body is exact cat of per-page bodies ---
    expected_pcm = b"".join(
        _read_pcm_body(AudiobookStore.page_audio_path(bid, n))
        for n in range(1, page_count + 1)
        if os.path.exists(AudiobookStore.page_audio_path(bid, n))
    )
    assert _read_pcm_body(final) == expected_pcm

    # --- page_to_time is monotonically increasing ---
    new_meta = AudiobookStore.read_meta(bid)
    p2t = new_meta["page_to_time"]
    times = [p2t[str(n)] for n in range(1, page_count + 1)]
    assert times[0] == 0.0
    for a, b in zip(times, times[1:]):
        assert b > a, "page_to_time must be strictly increasing for non-empty pages"

    # --- total_audio_seconds matches ---
    assert abs(new_meta["total_audio_seconds"] - actual["audio_seconds"]) < 0.001

    # --- Transcript JSON exists and is parseable ---
    tpath = AudiobookStore.transcript_path(bid)
    assert os.path.exists(tpath)
    with open(tpath) as f:
        t = json.load(f)
    assert t["book_id"] == bid
    assert len(t["pages"]) == page_count

    # --- PCM samples are non-trivially non-zero (actual audio, not silence) ---
    pcm = np.frombuffer(_read_pcm_body(final), dtype="<i2")
    assert np.abs(pcm).max() > 100, "Expected non-silent audio from TTS mock"


# ===========================================================================
# Non-deterministic: real TTS engine (skipped unless model is present)
# ===========================================================================


@pytest.mark.asyncio
@pytest.mark.skipif(
    not os.path.exists(
        os.path.join(os.path.dirname(__file__), "..", "kokoro-v1.0.onnx")
    ),
    reason="Kokoro ONNX model not present — skipping real TTS test",
)
async def test_real_tts_generates_audible_audio():
    """Non-deterministic: run the real Kokoro model on a short sentence and
    verify the output is non-silent, within amplitude bounds, and correctly
    formatted. This catches model-loading or inference regressions that mocks
    would miss."""
    from app.services.engine_manager import EngineManager

    await EngineManager.ensure_loaded()

    chunks = []
    async for chunk in EngineManager.generate("Hello world.", "af_bella", 1.0):
        chunks.append(chunk)

    assert len(chunks) > 0, "Real TTS produced no audio chunks"
    audio = np.concatenate(chunks)

    # Should produce at least 0.5 seconds of audio
    assert len(audio) >= SAMPLE_RATE * 0.5, "Too short for 'Hello world.'"

    # float32 samples must be in [-1, 1] (model output before clipping)
    assert audio.dtype == np.float32
    assert audio.max() <= 1.05, "Samples exceed 1.0 before clipping"
    assert audio.min() >= -1.05, "Samples below -1.0 before clipping"

    # Must be non-silent
    rms = np.sqrt(np.mean(audio**2))
    assert rms > 0.01, f"RMS {rms:.4f} too low — audio is essentially silent"

    # Round-trip through WAV writer: verify int16 representation is valid

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        path = tmp.name
    try:
        AudiobookService._write_wav_from_samples(path, audio)
        pcm = np.frombuffer(_read_pcm_body(path), dtype="<i2")
        assert len(pcm) == len(audio)
        rms_int16 = np.sqrt(np.mean(pcm.astype(np.float32) ** 2))
        assert rms_int16 > 100, "int16 RMS too low after conversion"
    finally:
        os.unlink(path)


@pytest.mark.asyncio
@pytest.mark.skipif(
    not os.path.exists(
        os.path.join(os.path.dirname(__file__), "..", "kokoro-v1.0.onnx")
    ),
    reason="Kokoro ONNX model not present — skipping real pipeline test",
)
async def test_real_pipeline_produces_correct_transcript():
    """Non-deterministic: run a 2-page book through the full TTS→concat pipeline
    with the real model and verify the output WAV is bit-for-bit the concat of
    the two per-page WAVs."""
    from app.services.engine_manager import EngineManager

    await EngineManager.ensure_loaded()

    bid = _make_book(2)
    meta = AudiobookStore.read_meta(bid)
    texts = ["The quick brown fox jumps.", "Over the lazy dog."]
    for n, text in enumerate(texts, 1):
        p = AudiobookStore.page_clean_path(bid, n)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)

    await AudiobookService._phase_tts(bid, meta)
    await AudiobookService._phase_concat(bid, AudiobookStore.read_meta(bid))

    # Final PCM == concat of per-page PCMs
    expected = b"".join(
        _read_pcm_body(AudiobookStore.page_audio_path(bid, n)) for n in (1, 2)
    )
    assert _read_pcm_body(AudiobookStore.audio_path(bid)) == expected

    # Both pages produced non-silent audio
    for n in (1, 2):
        pcm = np.frombuffer(
            _read_pcm_body(AudiobookStore.page_audio_path(bid, n)), dtype="<i2"
        )
        rms = np.sqrt(np.mean(pcm.astype(np.float32) ** 2))
        assert rms > 50, f"Page {n} RMS {rms:.1f} — sounds like silence"

    # page_to_time[1] = 0; page_to_time[2] > 0
    new_meta = AudiobookStore.read_meta(bid)
    assert new_meta["page_to_time"]["1"] == 0.0
    assert new_meta["page_to_time"]["2"] > 0.0
