"""WAV to MP3 encoding through libsndfile's bundled LAME encoder.

The soundfile wheels ship libsndfile with LAME and mpg123 linked in, so MP3
export needs no extra dependency. Encoding is block-wise and cancellable, so
memory stays flat for a 24-hour book.
"""

from __future__ import annotations

import threading
from dataclasses import dataclass

import numpy as np
import soundfile as sf

MP3_BITRATES_KBPS = (64, 80, 96, 112, 128, 160, 192)
DEFAULT_MP3_BITRATE_KBPS = 96

_MPEG1_RATES = frozenset({32000, 44100, 48000})
_MPEG2_RATES = frozenset({16000, 22050, 24000})
_MPEG1_KBPS_RANGE = (32, 320)
_MPEG2_KBPS_RANGE = (8, 160)
_INPUT_SUBTYPES = frozenset({"PCM_16", "FLOAT"})
_BLOCK_FRAMES = 1 << 16


class Mp3InputError(ValueError):
    """A safe, user-actionable rejection of the source audio."""


class Mp3UnavailableError(RuntimeError):
    """The bundled libsndfile was built without MP3 support."""


class Mp3EncodeCancelled(Exception):
    """The caller stopped waiting for this encode."""


@dataclass(frozen=True, slots=True)
class WavInfo:
    samplerate: int
    channels: int
    frames: int


def mp3_supported() -> bool:
    return "MP3" in sf.available_formats()


def has_wav_header(prefix: bytes) -> bool:
    return len(prefix) >= 12 and prefix[:4] == b"RIFF" and prefix[8:12] == b"WAVE"


def encode_wav_to_mp3(
    source: str,
    destination: str,
    bitrate_kbps: int,
    cancel: threading.Event | None = None,
) -> WavInfo:
    if bitrate_kbps not in MP3_BITRATES_KBPS:
        raise ValueError(f"unsupported MP3 bitrate: {bitrate_kbps}")
    if not mp3_supported():
        raise Mp3UnavailableError("libsndfile has no MP3 encoder")
    with _open_wav(source) as wav:
        info = _validated_info(wav)
        output_rate, upsample = _output_rate(info.samplerate, bitrate_kbps)
        with sf.SoundFile(
            destination,
            "w",
            samplerate=output_rate,
            channels=info.channels,
            format="MP3",
            subtype="MPEG_LAYER_III",
            compression_level=_compression_level(output_rate, bitrate_kbps),
            bitrate_mode="CONSTANT",
        ) as mp3:
            previous: np.ndarray | None = None
            for block in wav.blocks(
                blocksize=_BLOCK_FRAMES, dtype="float32", always_2d=True
            ):
                if cancel is not None and cancel.is_set():
                    raise Mp3EncodeCancelled
                block = np.clip(block, -1.0, 1.0)
                if upsample:
                    block, previous = _upsample_2x(block, previous)
                mp3.write(block)
    return info


def _open_wav(source: str) -> sf.SoundFile:
    try:
        return sf.SoundFile(source)
    except (sf.LibsndfileError, RuntimeError, TypeError) as exc:
        raise Mp3InputError("This file is not a readable WAV file.") from exc


def _validated_info(wav: sf.SoundFile) -> WavInfo:
    if wav.format != "WAV" or wav.subtype not in _INPUT_SUBTYPES:
        raise Mp3InputError("Use a 16-bit PCM or 32-bit float WAV file.")
    if wav.channels not in (1, 2):
        raise Mp3InputError("Use a mono or stereo WAV file.")
    if wav.samplerate not in _MPEG1_RATES | _MPEG2_RATES:
        raise Mp3InputError(
            "Use a WAV file sampled at 16, 22.05, 24, 32, 44.1, or 48 kHz."
        )
    if wav.frames <= 0:
        raise Mp3InputError("The WAV file has no audio.")
    return WavInfo(wav.samplerate, wav.channels, wav.frames)


def _output_rate(samplerate: int, bitrate_kbps: int) -> tuple[int, bool]:
    if samplerate in _MPEG2_RATES and bitrate_kbps > _MPEG2_KBPS_RANGE[1]:
        return samplerate * 2, True
    return samplerate, False


def _compression_level(samplerate: int, bitrate_kbps: int) -> float:
    low, high = _MPEG1_KBPS_RANGE if samplerate in _MPEG1_RATES else _MPEG2_KBPS_RANGE
    return (high - bitrate_kbps) / (high - low)


def _upsample_2x(
    block: np.ndarray, previous: np.ndarray | None
) -> tuple[np.ndarray, np.ndarray]:
    before = block[:1] if previous is None else previous
    shifted = np.concatenate((before, block[:-1]))
    doubled = np.empty((block.shape[0] * 2, block.shape[1]), dtype=np.float32)
    doubled[0::2] = (shifted + block) * 0.5
    doubled[1::2] = block
    return doubled, block[-1:]
