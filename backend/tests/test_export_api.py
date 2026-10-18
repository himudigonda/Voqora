import asyncio
import io
import json
import os
import shutil
import tempfile
import threading
from unittest.mock import AsyncMock, patch
from urllib.parse import unquote

import numpy as np
import pytest
import soundfile as sf
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app.api import export
from app.core.config import settings
from app.main import app
from app.services.audiobook_service import SAMPLE_RATE, AudiobookService
from app.services.audiobook_store import AudiobookStore
from tests.test_mp3_encoder import first_mp3_frame


@pytest.fixture(autouse=True)
def isolated_audiobooks_dir(monkeypatch):
    tmp = tempfile.mkdtemp(prefix="ss_export_test_")

    class _PatchedSettings:
        @property
        def AUDIOBOOKS_DIR(self) -> str:
            return tmp

    monkeypatch.setattr("app.services.audiobook_store.settings", _PatchedSettings())
    AudiobookStore._reset_for_tests()
    yield tmp
    AudiobookStore._reset_for_tests()
    shutil.rmtree(tmp, ignore_errors=True)


@pytest.fixture
def client() -> TestClient:
    return TestClient(app)


def _transcript(bid: str, lines=None, sections=None, total=4.0) -> dict:
    return {
        "book_id": bid,
        "sections": sections
        or [{"title": "Only", "start_page": 1, "end_page": 1, "start_time": 0.0}],
        "page_to_time": {"1": 0.0},
        "total_audio_seconds": total,
        "pages": {"1": "Chapter One\n\nIt began. Then it ended."},
        "page_status": {},
        "lines": (
            {
                "1": [
                    {"paragraph": 0, "text": "Chapter One", "start": 0.0, "end": 1.0},
                    {"paragraph": 1, "text": "It began.", "start": 1.0, "end": 2.5},
                    {
                        "paragraph": 1,
                        "text": "Then it ended.",
                        "start": 2.5,
                        "end": 4.0,
                    },
                ]
            }
            if lines is None
            else lines
        ),
    }


def _book(
    title="My Book.pdf",
    status="done",
    transcript=True,
    audio_seconds: float | None = None,
    **transcript_kwargs,
) -> str:
    bid = AudiobookStore.create_book(title)
    meta = AudiobookStore.initial_meta(
        bid, title, 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["status"] = status
    AudiobookStore.write_meta(bid, meta)
    if transcript:
        with open(AudiobookStore.transcript_path(bid), "w", encoding="utf-8") as f:
            json.dump(_transcript(bid, **transcript_kwargs), f, ensure_ascii=False)
    if audio_seconds is not None:
        t = np.arange(int(SAMPLE_RATE * audio_seconds)) / SAMPLE_RATE
        AudiobookService._write_wav_from_samples(
            AudiobookStore.audio_path(bid),
            (0.3 * np.sin(2 * np.pi * 220 * t)).astype(np.float32),
        )
    return bid


def _wav_bytes(rate=24000, seconds=0.5, channels=1, subtype="PCM_16") -> bytes:
    t = np.arange(int(rate * seconds)) / rate
    tone = (0.3 * np.sin(2 * np.pi * 440 * t)).astype(np.float32)
    data = np.stack([tone] * channels, axis=1) if channels > 1 else tone
    buffer = io.BytesIO()
    sf.write(buffer, data, rate, subtype=subtype, format="WAV")
    return buffer.getvalue()


def _exports_left() -> list[str]:
    return os.listdir(AudiobookStore.exports_dir())


def _filenames(response) -> tuple[str, str]:
    header = response.headers["content-disposition"]
    ascii_name = header.split('filename="', 1)[1].split('"', 1)[0]
    utf8_name = unquote(header.split("filename*=UTF-8''", 1)[1])
    return ascii_name, utf8_name


# ---------- subtitles ----------


def test_srt_export_serves_sentence_cues_as_a_download(client):
    bid = _book()

    response = client.get(f"/audiobook/{bid}/export/srt")

    assert response.status_code == 200
    assert response.headers["content-type"] == "application/x-subrip; charset=utf-8"
    assert _filenames(response) == ("My Book.srt", "My Book.srt")
    assert response.text == (
        "1\n00:00:00,000 --> 00:00:01,000\nChapter One\n\n"
        "2\n00:00:01,000 --> 00:00:02,500\nIt began.\n\n"
        "3\n00:00:02,500 --> 00:00:04,000\nThen it ended.\n\n"
    )


def test_vtt_export_serves_webvtt(client):
    bid = _book()

    response = client.get(f"/audiobook/{bid}/export/vtt")

    assert response.status_code == 200
    assert response.headers["content-type"] == "text/vtt; charset=utf-8"
    assert response.text.startswith("WEBVTT\n\n1\n00:00:00.000 --> 00:00:01.000\n")
    assert _filenames(response)[1] == "My Book.vtt"


def test_unicode_title_and_text_are_exported_safely(client):
    lines = {"1": [{"paragraph": 0, "text": "Café 東京。", "start": 0, "end": 1}]}
    bid = _book(title="Café 東京.docx", lines=lines)

    response = client.get(f"/audiobook/{bid}/export/srt")

    assert "Café 東京。" in response.content.decode("utf-8")
    assert _filenames(response) == ("Cafe.srt", "Café 東京.srt")


def test_hostile_title_cannot_escape_the_content_disposition(client):
    bid = _book(title='../../evil"\r\nX-Injected: 1;.pdf')

    response = client.get(f"/audiobook/{bid}/export/srt")

    assert response.status_code == 200
    assert "x-injected" not in response.headers
    ascii_name, utf8_name = _filenames(response)
    for name in (ascii_name, utf8_name):
        assert "/" not in name and '"' not in name and "\r" not in name
        assert not name.startswith(".")
        assert name.endswith(".srt")


def test_non_ascii_only_title_gets_an_ascii_fallback(client):
    bid = _book(title="東京.pdf")

    response = client.get(f"/audiobook/{bid}/export/vtt")

    assert _filenames(response) == ("export.vtt", "東京.vtt")


@pytest.mark.parametrize(
    "title",
    ["Moby Dick.epub", "Moby Dick.HTML", "Moby Dick.htm", "Moby Dick.md"],
)
def test_source_extensions_are_dropped_from_export_names(client, title):
    bid = _book(title=title)

    response = client.get(f"/audiobook/{bid}/export/srt")

    assert _filenames(response) == ("Moby Dick.srt", "Moby Dick.srt")


def test_unknown_extensions_stay_in_export_names():
    assert export.book_title("Notes.rtf", "audiobook") == "Notes.rtf"
    assert export.book_title("Notes.epub", "audiobook") == "Notes"


def test_blank_title_falls_back_to_audiobook(client):
    bid = _book(title="...")

    response = client.get(f"/audiobook/{bid}/export/srt")

    assert _filenames(response)[1] == "audiobook.srt"


def test_empty_book_exports_empty_subtitles(client):
    bid = _book(lines={})

    assert client.get(f"/audiobook/{bid}/export/srt").text == ""
    assert client.get(f"/audiobook/{bid}/export/vtt").text == "WEBVTT\n\n"


@pytest.mark.parametrize(
    "status", ["queued", "extracting", "cleaning", "tts", "needs_cost_approval"]
)
@pytest.mark.parametrize("path", ["export/srt", "export/vtt", "chapters", "export/mp3"])
def test_unfinished_books_are_rejected_with_409(client, status, path):
    bid = _book(status=status, audio_seconds=0.2)

    response = client.get(f"/audiobook/{bid}/{path}")

    assert response.status_code == 409
    assert response.json()["detail"] == "This audiobook is still being generated."


@pytest.mark.parametrize("path", ["export/srt", "export/vtt", "chapters"])
def test_missing_book_transcript_and_bad_ids(client, path):
    no_transcript = _book(transcript=False)

    assert client.get(f"/audiobook/{'a' * 32}/{path}").status_code == 404
    assert client.get(f"/audiobook/{'Z' * 32}/{path}").status_code == 400
    missing = client.get(f"/audiobook/{no_transcript}/{path}")
    assert missing.status_code == 404
    assert missing.json()["detail"] == "Transcript not ready."


def test_corrupt_transcript_is_a_500_without_internals(client):
    bid = _book()
    with open(AudiobookStore.transcript_path(bid), "w") as f:
        f.write("[1, 2")

    response = client.get(f"/audiobook/{bid}/export/srt")

    assert response.status_code == 500
    assert response.json() == {"detail": "The transcript could not be read."}


def test_non_object_transcript_is_a_500(client):
    bid = _book()
    with open(AudiobookStore.transcript_path(bid), "w") as f:
        f.write("[]")

    assert client.get(f"/audiobook/{bid}/chapters").status_code == 500


# ---------- chapters ----------


def test_chapters_endpoint_returns_markers_aligned_to_audio(client):
    sections = [
        {"title": "Front", "start_page": 1, "end_page": 1, "start_time": 0.0},
        {"title": "Chapter 1", "start_page": 2, "end_page": 3, "start_time": 61.25},
    ]
    bid = _book(sections=sections, total=3725.5)

    response = client.get(f"/audiobook/{bid}/chapters")

    assert response.status_code == 200
    assert response.json() == {
        "book_id": bid,
        "total_audio_seconds": 3725.5,
        "chapters": [
            {"title": "Front", "start_seconds": 0.0, "end_seconds": 61.25},
            {"title": "Chapter 1", "start_seconds": 61.25, "end_seconds": 3725.5},
        ],
    }


def test_chapters_for_a_silent_book_are_empty(client):
    bid = _book(lines={}, total=0.0)

    assert client.get(f"/audiobook/{bid}/chapters").json()["chapters"] == []


# ---------- transcript word timings ----------


def test_transcript_default_response_is_unchanged(client):
    bid = _book()

    body = client.get(f"/audiobook/{bid}/transcript").json()

    assert body == _transcript(bid)
    assert all("words" not in line for line in body["lines"]["1"])


def test_transcript_words_flag_adds_word_timings(client):
    bid = _book()

    response = client.get(f"/audiobook/{bid}/transcript?words=true")

    assert response.status_code == 200
    line = response.json()["lines"]["1"][2]
    assert line["text"] == "Then it ended."
    assert line["words"] == [
        {"text": "Then", "start": 2.5, "end": 3.045},
        {"text": "it", "start": 3.045, "end": 3.318},
        {"text": "ended.", "start": 3.318, "end": 4.0},
    ]
    assert response.json()["sections"] == _transcript(bid)["sections"]


def test_transcript_words_flag_errors(client):
    no_transcript = _book(transcript=False)
    corrupt = _book()
    with open(AudiobookStore.transcript_path(corrupt), "w") as f:
        f.write("{")

    assert (
        client.get(f"/audiobook/{no_transcript}/transcript?words=true").status_code
        == 404
    )
    assert client.get(f"/audiobook/{corrupt}/transcript?words=true").status_code == 500
    assert client.get(f"/audiobook/{corrupt}/transcript?words=maybe").status_code == 422


# ---------- audiobook MP3 ----------


def test_audiobook_mp3_export_streams_a_valid_mp3_and_cleans_up(client):
    bid = _book(audio_seconds=2.0)

    response = client.get(f"/audiobook/{bid}/export/mp3")

    assert response.status_code == 200
    assert response.headers["content-type"] == "audio/mpeg"
    assert int(response.headers["content-length"]) == len(response.content)
    assert _filenames(response)[1] == "My Book.mp3"
    assert first_mp3_frame(response.content) == {
        "version": 2,
        "layer3": True,
        "kbps": 96,
        "rate": 24000,
        "mono": True,
    }
    decoded = sf.info(io.BytesIO(response.content))
    assert decoded.duration == pytest.approx(2.0, abs=0.1)
    assert _exports_left() == []


@pytest.mark.parametrize("kbps", [64, 128, 192])
def test_audiobook_mp3_export_honours_bitrate(client, kbps):
    bid = _book(audio_seconds=0.5)

    response = client.get(f"/audiobook/{bid}/export/mp3?bitrate={kbps}")

    assert response.status_code == 200
    assert first_mp3_frame(response.content)["kbps"] == kbps


@pytest.mark.parametrize("kbps", ["32", "63", "100", "193", "320", "abc"])
def test_audiobook_mp3_export_rejects_bad_bitrates(client, kbps):
    bid = _book(audio_seconds=0.5)

    response = client.get(f"/audiobook/{bid}/export/mp3?bitrate={kbps}")

    assert response.status_code == 422


def test_audiobook_mp3_export_needs_audio(client):
    bid = _book()
    tiny = _book()
    with open(AudiobookStore.audio_path(tiny), "wb") as f:
        f.write(b"RIFF")

    assert client.get(f"/audiobook/{bid}/export/mp3").status_code == 404
    assert client.get(f"/audiobook/{tiny}/export/mp3").status_code == 404
    assert client.get(f"/audiobook/{'b' * 32}/export/mp3").status_code == 404


def test_audiobook_mp3_export_with_corrupt_audio_is_a_500(client):
    bid = _book()
    with open(AudiobookStore.audio_path(bid), "wb") as f:
        f.write(b"RIFF" + b"\x00" * 100)

    response = client.get(f"/audiobook/{bid}/export/mp3")

    assert response.status_code == 500
    assert response.json() == {
        "detail": "This audiobook's audio could not be exported."
    }
    assert _exports_left() == []


# ---------- WAV clip conversion ----------


def _convert(client, body: bytes, query: str = "", content_type="audio/wav"):
    return client.post(
        f"/audio/mp3{query}", content=body, headers={"Content-Type": content_type}
    )


def test_wav_clip_converts_to_mp3(client):
    response = _convert(client, _wav_bytes(seconds=1.0), "?name=Greeting")

    assert response.status_code == 200
    assert response.headers["content-type"] == "audio/mpeg"
    assert _filenames(response)[1] == "Greeting.mp3"
    assert first_mp3_frame(response.content)["kbps"] == 96
    assert _exports_left() == []


def test_wav_clip_default_name_and_stereo_float(client):
    body = _wav_bytes(rate=48000, channels=2, subtype="FLOAT")

    response = _convert(
        client, body, "?bitrate=160", content_type="audio/x-wav; codec=1"
    )

    assert response.status_code == 200
    assert _filenames(response)[1] == "clip.mp3"
    header = first_mp3_frame(response.content)
    assert header["kbps"] == 160 and header["rate"] == 48000 and not header["mono"]


def test_wav_clip_rejects_wrong_content_type(client):
    response = _convert(client, _wav_bytes(), content_type="text/plain")

    assert response.status_code == 415


@pytest.mark.parametrize(
    ("body", "detail"),
    [
        (b"", "The uploaded file is empty."),
        (b"ID3\x04" + b"\x00" * 64, "This file is not a valid WAV file."),
        (b"RIFF", "This file is not a valid WAV file."),
        (b"RIFF\x00\x00\x00\x00WAVEjunk", "This file is not a readable WAV file."),
    ],
)
def test_wav_clip_rejects_invalid_bodies(client, body, detail):
    response = _convert(client, body)

    assert response.status_code == 400
    assert response.json()["detail"] == detail
    assert _exports_left() == []


def test_wav_clip_rejects_unsupported_formats(client):
    response = _convert(client, _wav_bytes(subtype="PCM_24"))

    assert response.status_code == 400
    assert response.json()["detail"] == "Use a 16-bit PCM or 32-bit float WAV file."


def test_wav_clip_validates_bitrate_and_name(client):
    assert _convert(client, _wav_bytes(), "?bitrate=100").status_code == 422
    assert _convert(client, _wav_bytes(), f"?name={'n' * 121}").status_code == 422


def test_wav_clip_over_the_streamed_limit_is_rejected(client, monkeypatch):
    monkeypatch.setattr(settings, "MAX_WAV_CONVERT_MB", 1)
    body = b"RIFF\x00\x00\x00\x00WAVE" + b"\x00" * (1024 * 1024 + 512 * 1024)

    response = _convert(client, body)

    assert response.status_code == 413
    assert response.json()["detail"] == "File exceeds 1 MB limit."
    assert _exports_left() == []


def test_wav_clip_declared_oversize_is_rejected_before_reading(client, monkeypatch):
    monkeypatch.setattr(settings, "MAX_WAV_CONVERT_MB", 1)

    response = client.post(
        "/audio/mp3",
        content=b"x",
        headers={
            "Content-Type": "audio/wav",
            "Content-Length": str(2 * 1024 * 1024 + 1),
        },
    )

    assert response.status_code == 413
    assert response.json()["detail"] == "File exceeds 1 MB limit."


def test_wav_route_limit_does_not_change_the_audiobook_upload_limit(monkeypatch):
    monkeypatch.setattr(settings, "MAX_WAV_CONVERT_MB", 500)
    limit = (settings.MAX_AUDIOBOOK_UPLOAD_MB + 1) * 1024 * 1024

    response = TestClient(app).post(
        "/audiobook",
        content=b"x",
        headers={
            "Content-Length": str(limit + 1),
            "Content-Type": "multipart/form-data; boundary=x",
        },
    )

    assert response.status_code == 413


def test_conversion_requires_the_ipc_token():
    response = TestClient(app, headers={"X-Voqora-IPC-Token": "wrong"}).post(
        "/audio/mp3", content=_wav_bytes(), headers={"Content-Type": "audio/wav"}
    )

    assert response.status_code == 401


def test_busy_encoder_returns_429(client):
    assert export._mp3_slot.acquire(blocking=False)
    try:
        response = _convert(client, _wav_bytes())
    finally:
        export._mp3_slot.release()

    assert response.status_code == 429
    assert response.headers["retry-after"] == "5"
    assert _exports_left() == []
    assert _convert(client, _wav_bytes()).status_code == 200


def test_missing_mp3_encoder_returns_503(client, monkeypatch):
    monkeypatch.setattr(
        "app.services.mp3_encoder.sf.available_formats", lambda: {"WAV": "WAV"}
    )

    response = _convert(client, _wav_bytes())

    assert response.status_code == 503
    assert response.json() == {"detail": "MP3 export is not available in this build."}


def test_unexpected_encoder_failure_is_a_generic_500(client, monkeypatch, caplog):
    def explode(source, destination, bitrate, cancel):
        with open(destination, "wb") as f:
            f.write(b"partial")
        raise RuntimeError("/Users/someone/secret path")

    monkeypatch.setattr(export, "encode_wav_to_mp3", explode)

    response = _convert(client, _wav_bytes())

    assert response.status_code == 500
    assert response.json() == {"detail": "MP3 export failed."}
    assert "secret" not in response.text
    assert _exports_left() == []
    assert any(
        getattr(r, "failure_code", None) == "mp3_encode_failed" for r in caplog.records
    )
    assert export._mp3_slot.acquire(blocking=False)
    export._mp3_slot.release()


# ---------- concurrency and cancellation ----------


@pytest.mark.asyncio
async def test_concurrent_encodes_are_limited_to_one(tmp_path, monkeypatch):
    started = threading.Event()
    release = threading.Event()

    def slow(source, destination, bitrate, cancel):
        started.set()
        release.wait(5)

    monkeypatch.setattr(export, "encode_wav_to_mp3", slow)
    source = str(tmp_path / "in.wav")
    with open(source, "wb") as f:
        f.write(_wav_bytes())

    first = asyncio.create_task(export._encode_mp3(source, 96))
    await asyncio.get_running_loop().run_in_executor(None, started.wait, 5)
    with pytest.raises(HTTPException) as busy:
        await export._encode_mp3(source, 96)
    release.set()
    produced = await first

    assert busy.value.status_code == 429
    assert os.path.exists(produced)
    os.remove(produced)


@pytest.mark.asyncio
async def test_cancelled_encode_stops_the_worker_and_removes_its_file(
    tmp_path, monkeypatch
):
    started = threading.Event()
    stopped = threading.Event()
    seen_cancel: list[threading.Event] = []

    def cancellable(source, destination, bitrate, cancel):
        seen_cancel.append(cancel)
        started.set()
        cancel.wait(5)
        stopped.set()

    monkeypatch.setattr(export, "encode_wav_to_mp3", cancellable)
    source = str(tmp_path / "in.wav")
    with open(source, "wb") as f:
        f.write(_wav_bytes())

    task = asyncio.create_task(export._encode_mp3(source, 96))
    await asyncio.get_running_loop().run_in_executor(None, started.wait, 5)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    await asyncio.get_running_loop().run_in_executor(None, stopped.wait, 5)
    for _ in range(50):
        if not _exports_left():
            break
        await asyncio.sleep(0.02)

    assert seen_cancel[0].is_set()
    assert _exports_left() == []
    assert export._mp3_slot.acquire(blocking=False)
    export._mp3_slot.release()


# ---------- end to end over a synthesized book ----------


@pytest.mark.asyncio
async def test_exports_follow_the_pipeline_transcript():
    bid = AudiobookStore.create_book("Pipeline.md")
    meta = AudiobookStore.initial_meta(
        bid, "Pipeline.md", 2, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["sections"] = [
        {"title": "Intro", "start_page": 1, "end_page": 1},
        {"title": "Body", "start_page": 2, "end_page": 2},
    ]
    AudiobookStore.write_meta(bid, meta)
    for n, text in ((1, "Intro\n\nFirst sentence here."), (2, "Last page line.")):
        with open(AudiobookStore.page_clean_path(bid, n), "w", encoding="utf-8") as f:
            f.write(text)

    async def one_second_per_segment(*args, **kwargs):
        yield np.zeros(SAMPLE_RATE, dtype=np.float32)

    with (
        patch(
            "app.services.audiobook_service.EngineManager.ensure_loaded",
            new=AsyncMock(return_value=None),
        ),
        patch("app.services.audiobook_service.EngineManager.touch", return_value=None),
        patch(
            "app.services.audiobook_service.EngineManager.generate",
            side_effect=one_second_per_segment,
        ),
        patch("app.services.audiobook_service.asyncio.sleep", new=AsyncMock()),
    ):
        await AudiobookService._phase_tts(bid, AudiobookStore.read_meta(bid))
    await AudiobookService._phase_concat(bid, AudiobookStore.read_meta(bid))
    await AudiobookStore.update_meta(bid, status="done")
    client = TestClient(app)

    srt = client.get(f"/audiobook/{bid}/export/srt").text
    chapters = client.get(f"/audiobook/{bid}/chapters").json()["chapters"]
    mp3 = client.get(f"/audiobook/{bid}/export/mp3?bitrate=64")

    assert srt == (
        "1\n00:00:00,000 --> 00:00:01,000\nIntro\n\n"
        "2\n00:00:01,000 --> 00:00:02,000\nFirst sentence here.\n\n"
        "3\n00:00:02,000 --> 00:00:03,000\nLast page line.\n\n"
    )
    assert chapters == [
        {"title": "Intro", "start_seconds": 0.0, "end_seconds": 2.0},
        {"title": "Body", "start_seconds": 2.0, "end_seconds": 3.0},
    ]
    assert mp3.status_code == 200
    assert sf.info(io.BytesIO(mp3.content)).duration == pytest.approx(3.0, abs=0.1)


def test_chapters_report_a_malformed_total_as_zero(client):
    bid = _book(total="soon")

    response = client.get(f"/audiobook/{bid}/chapters")

    assert response.status_code == 200
    assert response.json()["total_audio_seconds"] == 0.0
    assert response.json()["chapters"] == []


def test_startup_sweep_removes_exports_left_by_a_killed_process():
    leftover = os.path.join(AudiobookStore.exports_dir(), "export-x.mp3.tmp")
    with open(leftover, "wb") as f:
        f.write(b"partial")

    AudiobookStore.clear_exports()

    assert not os.path.exists(leftover)
    assert _exports_left() == []
