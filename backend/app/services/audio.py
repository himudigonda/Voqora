import struct

import numpy as np

from app.core.config import settings

# Single source of truth for the audio sample rate. Imported once so the
# WAV header constants below are stable for the process lifetime.
_SR = settings.AUDIO_SAMPLE_RATE
_BYTE_RATE = _SR * 2  # mono int16 → 2 bytes/sample

# Pre-computed WAV header for an open-ended stream. A size of zero makes
# AVFoundation reject the response as an empty file. `0xFFFFFFFF` is the
# conventional unknown-length sentinel used by RIFF stream producers; parsers
# consume the available PCM bytes while the Swift client keeps its low-latency
# header-then-PCM path.
_STREAMING_RIFF_SIZE = 0xFFFFFFFF
_WAV_HEADER = bytearray(44)
struct.pack_into("<4sI4s", _WAV_HEADER, 0, b"RIFF", _STREAMING_RIFF_SIZE, b"WAVE")
struct.pack_into(
    "<4sIHHIIHH", _WAV_HEADER, 12, b"fmt ", 16, 1, 1, _SR, _BYTE_RATE, 2, 16
)
struct.pack_into("<4sI", _WAV_HEADER, 36, b"data", _STREAMING_RIFF_SIZE)
_WAV_HEADER_BYTES = bytes(_WAV_HEADER)

# Pre-computed fade curves (avoid re-allocating on every call)
_FADE_SAMPLES = int(0.05 * _SR)  # 1200 samples at 24kHz
_FADE_IN_CURVE = np.linspace(0.6, 1.0, _FADE_SAMPLES, dtype=np.float32)
_FADE_OUT_CURVE = np.linspace(1.0, 0.6, _FADE_SAMPLES, dtype=np.float32)

# Silence array cache keyed by (rounded duration, sample rate). Populated
# lazily on first request, bounded to prevent unbounded growth from unusual
# (speed-scaled) durations.
_SILENCE_CACHE: dict[tuple[float, int], np.ndarray] = {}
_SILENCE_CACHE_CAP = 64


class AudioService:
    @staticmethod
    def apply_fade(
        samples: np.ndarray,
        fade_in: bool = True,
        fade_out: bool = True,
    ) -> np.ndarray:
        """
        Applies pre-computed fade curves to prevent popping at sentence boundaries.
        """
        n = len(samples)
        if n == 0:
            return samples

        # Operate on a copy to avoid mutating shared ONNX memory
        samples = samples.copy()
        fade_len = _FADE_SAMPLES

        if n < 2 * fade_len:
            fade_len = n // 2

        if fade_in and fade_len > 0:
            if fade_len == _FADE_SAMPLES:
                samples[:fade_len] *= _FADE_IN_CURVE
            else:
                samples[:fade_len] *= np.linspace(0.6, 1.0, fade_len, dtype=np.float32)

        if fade_out and fade_len > 0:
            if fade_len == _FADE_SAMPLES:
                samples[-fade_len:] *= _FADE_OUT_CURVE
            else:
                samples[-fade_len:] *= np.linspace(1.0, 0.6, fade_len, dtype=np.float32)

        return samples

    @staticmethod
    def get_silence(duration_sec: float, sample_rate: int = _SR) -> np.ndarray:
        """Return an (immutable) silence array, populating the cache on first use.

        Cache key is rounded to 3 decimals so floating-point jitter from
        speed-scaling (`pause / speed`) doesn't multiply cache entries.
        Bounded to `_SILENCE_CACHE_CAP` entries to cap memory under
        unusual speed sweeps.
        """
        key = (round(duration_sec, 3), sample_rate)
        cached = _SILENCE_CACHE.get(key)
        if cached is not None:
            return cached
        arr = np.zeros(int(duration_sec * sample_rate), dtype=np.float32)
        arr.flags.writeable = False
        if len(_SILENCE_CACHE) < _SILENCE_CACHE_CAP:
            _SILENCE_CACHE[key] = arr
        return arr

    @staticmethod
    async def stream_samples_to_wav(sample_generator, volume: float):
        """
        Takes an async generator of raw float samples and yields WAV chunks,
        starting with a pre-computed header for streaming.
        """
        # 1. Yield pre-computed WAV header immediately (no per-request construction)
        yield _WAV_HEADER_BYTES

        # 2. Stream PCM data chunks
        async for samples in sample_generator:
            samples = np.clip(samples * volume, -1.0, 1.0)
            yield (samples * 32767).astype(np.int16).tobytes()
