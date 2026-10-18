import os
import threading

import numpy as np
import pytest
import soundfile as sf

from app.services import mp3_encoder
from app.services.mp3_encoder import (
    Mp3EncodeCancelled,
    Mp3InputError,
    Mp3UnavailableError,
    encode_wav_to_mp3,
    has_wav_header,
    mp3_supported,
)

_MPEG1_KBPS = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
_MPEG2_KBPS = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
_MPEG1_RATES = [44100, 48000, 32000]
_MPEG2_RATES = [22050, 24000, 16000]


def first_mp3_frame(data: bytes) -> dict:
    offset = 0
    if data[:3] == b"ID3":
        size = (data[6] << 21) | (data[7] << 14) | (data[8] << 7) | data[9]
        offset = 10 + size
    assert data[offset] == 0xFF and data[offset + 1] & 0xE0 == 0xE0
    version_bits = (data[offset + 1] >> 3) & 0b11
    mpeg1 = version_bits == 0b11
    return {
        "version": 1 if mpeg1 else 2,
        "layer3": (data[offset + 1] >> 1) & 0b11 == 0b01,
        "kbps": (_MPEG1_KBPS if mpeg1 else _MPEG2_KBPS)[data[offset + 2] >> 4],
        "rate": (_MPEG1_RATES if mpeg1 else _MPEG2_RATES)[(data[offset + 2] >> 2) & 3],
        "mono": data[offset + 3] >> 6 == 0b11,
    }


def write_wav(path, rate=24000, seconds=1.0, channels=1, subtype="PCM_16"):
    t = np.arange(int(rate * seconds)) / rate
    tone = (0.3 * np.sin(2 * np.pi * 440 * t)).astype(np.float32)
    data = np.stack([tone] * channels, axis=1) if channels > 1 else tone
    sf.write(path, data, rate, subtype=subtype, format="WAV")
    return str(path)


def test_mp3_support_is_present_in_the_bundled_libsndfile():
    assert mp3_supported()


def test_default_book_audio_encodes_to_valid_mono_mpeg2_at_96k(tmp_path):
    source = write_wav(tmp_path / "in.wav", seconds=2.0)
    target = str(tmp_path / "out.mp3")

    info = encode_wav_to_mp3(source, target, 96)

    with open(target, "rb") as f:
        header = first_mp3_frame(f.read())
    assert header == {
        "version": 2,
        "layer3": True,
        "kbps": 96,
        "rate": 24000,
        "mono": True,
    }
    assert info.samplerate == 24000 and info.channels == 1 and info.frames == 48000
    decoded = sf.info(target)
    assert decoded.samplerate == 24000
    assert decoded.duration == pytest.approx(2.0, abs=0.1)


@pytest.mark.parametrize("kbps", mp3_encoder.MP3_BITRATES_KBPS)
def test_every_allowed_bitrate_is_honoured_at_24k(tmp_path, kbps):
    source = write_wav(tmp_path / "in.wav", seconds=0.5)
    target = str(tmp_path / "out.mp3")

    encode_wav_to_mp3(source, target, kbps)

    with open(target, "rb") as f:
        header = first_mp3_frame(f.read())
    assert header["kbps"] == kbps
    assert header["rate"] == (48000 if kbps > 160 else 24000)


def test_192k_on_24k_audio_upsamples_and_keeps_duration(tmp_path):
    source = write_wav(tmp_path / "in.wav", seconds=3.0)
    target = str(tmp_path / "out.mp3")

    encode_wav_to_mp3(source, target, 192)

    decoded, rate = sf.read(target, dtype="float32")
    assert rate == 48000
    assert len(decoded) / rate == pytest.approx(3.0, abs=0.1)
    assert np.max(np.abs(decoded)) == pytest.approx(0.3, abs=0.05)


def test_stereo_float_44k_encodes_as_stereo_mpeg1(tmp_path):
    source = write_wav(tmp_path / "in.wav", rate=44100, channels=2, subtype="FLOAT")
    target = str(tmp_path / "out.mp3")

    encode_wav_to_mp3(source, target, 128)

    with open(target, "rb") as f:
        header = first_mp3_frame(f.read())
    assert header["version"] == 1 and header["rate"] == 44100
    assert header["kbps"] == 128 and not header["mono"]
    assert sf.info(target).channels == 2


def test_float_samples_beyond_full_scale_are_clipped(tmp_path):
    path = str(tmp_path / "loud.wav")
    sf.write(path, np.full(24000, 4.0, dtype=np.float32), 24000, subtype="FLOAT")
    target = str(tmp_path / "out.mp3")

    encode_wav_to_mp3(path, target, 64)

    assert os.path.getsize(target) > 0


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"subtype": "PCM_24"}, "16-bit PCM"),
        ({"subtype": "PCM_U8"}, "16-bit PCM"),
        ({"channels": 3}, "mono or stereo"),
        ({"rate": 8000}, "sampled at"),
        ({"rate": 96000}, "sampled at"),
        ({"seconds": 0.0}, "no audio"),
    ],
)
def test_unsupported_wav_inputs_are_rejected(tmp_path, kwargs, message):
    source = write_wav(tmp_path / "in.wav", **kwargs)

    with pytest.raises(Mp3InputError, match=message):
        encode_wav_to_mp3(source, str(tmp_path / "out.mp3"), 96)


def test_non_wav_containers_are_rejected(tmp_path):
    flac = str(tmp_path / "in.flac")
    sf.write(flac, np.zeros(2400, dtype=np.float32), 24000, format="FLAC")
    garbage = tmp_path / "garbage.wav"
    garbage.write_bytes(b"RIFF\x00\x00\x00\x00WAVEnot really audio")

    with pytest.raises(Mp3InputError, match="16-bit PCM"):
        encode_wav_to_mp3(flac, str(tmp_path / "a.mp3"), 96)
    with pytest.raises(Mp3InputError, match="readable WAV"):
        encode_wav_to_mp3(str(garbage), str(tmp_path / "b.mp3"), 96)


def test_unknown_bitrate_is_a_programming_error(tmp_path):
    source = write_wav(tmp_path / "in.wav")

    with pytest.raises(ValueError, match="bitrate"):
        encode_wav_to_mp3(source, str(tmp_path / "out.mp3"), 100)


def test_missing_mp3_support_is_reported(tmp_path, monkeypatch):
    source = write_wav(tmp_path / "in.wav")
    monkeypatch.setattr(mp3_encoder.sf, "available_formats", lambda: {"WAV": "WAV"})

    with pytest.raises(Mp3UnavailableError):
        encode_wav_to_mp3(source, str(tmp_path / "out.mp3"), 96)


def test_encoding_stops_when_cancelled(tmp_path):
    source = write_wav(tmp_path / "in.wav", seconds=1.0)
    cancel = threading.Event()
    cancel.set()

    with pytest.raises(Mp3EncodeCancelled):
        encode_wav_to_mp3(source, str(tmp_path / "out.mp3"), 96, cancel)


def test_blockwise_upsampling_matches_whole_signal_upsampling():
    signal = np.random.default_rng(7).uniform(-1, 1, (1000, 2)).astype(np.float32)

    whole, _ = mp3_encoder._upsample_2x(signal, None)
    first, carry = mp3_encoder._upsample_2x(signal[:333], None)
    second, _ = mp3_encoder._upsample_2x(signal[333:], carry)

    np.testing.assert_allclose(np.concatenate((first, second)), whole)
    np.testing.assert_allclose(whole[1::2], signal)
    np.testing.assert_allclose(whole[2::2], (signal[:-1] + signal[1:]) / 2)


def test_wav_header_sniffing():
    assert has_wav_header(b"RIFF\x24\x00\x00\x00WAVEfmt ")
    assert not has_wav_header(b"RIFF\x24\x00\x00\x00AVI ")
    assert not has_wav_header(b"ID3\x04")
    assert not has_wav_header(b"RIFF")


def test_non_finite_float_samples_are_sanitised_before_encoding(tmp_path):
    samples = np.zeros(24000, dtype=np.float32)
    samples[100:200] = np.nan
    samples[300:400] = np.inf
    samples[500:600] = -np.inf
    source = tmp_path / "nan.wav"
    sf.write(source, samples, 24000, subtype="FLOAT", format="WAV")
    destination = tmp_path / "out.mp3"

    encode_wav_to_mp3(str(source), str(destination), 96)

    decoded, _ = sf.read(destination, dtype="float32")
    assert np.isfinite(decoded).all()
