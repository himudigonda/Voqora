"""Podcast Library items: store compatibility, rendering pipeline, /podcast/render."""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import tempfile
import wave
from unittest.mock import AsyncMock, patch

import numpy as np
import pytest
from fastapi.testclient import TestClient

from app.core.config import settings
from app.main import app
from app.services import podcast_library
from app.services.audiobook_service import SAMPLE_RATE, AudiobookService
from app.services.audiobook_store import AudiobookStore
from app.services.import_limits import ImportLimitError
from app.services.podcast_script import PODCAST_KIND, PodcastScript

SPEECH_SECONDS = 0.5


@pytest.fixture(autouse=True)
def isolated_audiobooks_dir(monkeypatch):
    tmp = tempfile.mkdtemp(prefix="ss_podcast_render_test_")

    class _PatchedSettings:
        @property
        def AUDIOBOOKS_DIR(self) -> str:
            return tmp

    monkeypatch.setattr("app.services.audiobook_store.settings", _PatchedSettings())
    AudiobookStore._reset_for_tests()
    yield tmp
    AudiobookStore._reset_for_tests()
    shutil.rmtree(tmp, ignore_errors=True)


@pytest.fixture(autouse=True)
def reset_audiobook_service(monkeypatch):
    monkeypatch.setattr(
        "app.services.audiobook_service._settings.AUDIOBOOK_TTS_SEGMENT_PACING_S", 0.0
    )
    AudiobookService._subscribers.clear()
    AudiobookService._cancel_flags.clear()
    AudiobookService._scheduled_book_ids.clear()
    yield
    AudiobookService._subscribers.clear()
    AudiobookService._cancel_flags.clear()
    AudiobookService._scheduled_book_ids.clear()


def _script(**overrides) -> PodcastScript:
    data = {
        "title": "Tides Explained",
        "speakers": [
            {"id": "host_1", "name": "Ava", "voice": "af_bella"},
            {"id": "host_2", "name": "Sam", "voice": "am_adam"},
        ],
        "turns": [
            {
                "speaker_id": "host_1",
                "text": "Welcome to the show.",
                "section": "Intro",
                "pause_after_seconds": 1.0,
            },
            {"speaker_id": "host_2", "text": "Thanks for having me."},
            {
                "speaker_id": "host_1",
                "text": "Let us talk about the moon.",
                "section": "The Moon",
            },
            {
                "speaker_id": "host_2",
                "text": "It pulls the oceans.",
                "pause_after_seconds": 0,
            },
        ],
    }
    data.update(overrides)
    return PodcastScript.model_validate(data)


class FakeEngine:
    def __init__(self, on_call=None):
        self.calls: list[tuple[str, str]] = []
        self.on_call = on_call

    async def generate(self, text, voice, speed, lang=None, failed_segments=None):
        self.calls.append((text, voice))
        if self.on_call is not None:
            self.on_call(len(self.calls))
        yield np.full(int(SPEECH_SECONDS * SAMPLE_RATE), 0.1, dtype=np.float32)


def _engine_patches(engine: FakeEngine):
    return (
        patch(
            "app.services.audiobook_service.EngineManager.ensure_loaded",
            new=AsyncMock(return_value=None),
        ),
        patch("app.services.audiobook_service.EngineManager.touch", return_value=None),
        patch(
            "app.services.audiobook_service.EngineManager.generate",
            side_effect=engine.generate,
        ),
    )


async def _run(bid: str, engine: FakeEngine) -> list[dict]:
    queue = AudiobookService.subscribe(bid)
    first, second, third = _engine_patches(engine)
    with first, second, third:
        await AudiobookService._run_pipeline(bid)
    events = []
    while not queue.empty():
        events.append(queue.get_nowait())
    AudiobookService.unsubscribe(bid, queue)
    return events


def _frames(path: str) -> int:
    with wave.open(path, "rb") as wf:
        return wf.getnframes()


def _transcript(bid: str) -> dict:
    with open(AudiobookStore.transcript_path(bid), encoding="utf-8") as f:
        return json.load(f)


# ---------- store ----------


def test_rows_without_a_kind_read_back_as_books():
    conn = AudiobookStore._connection()
    legacy = {"book_id": "c" * 32, "title": "Old.pdf", "status": "done"}
    with AudiobookStore._conn_lock:
        AudiobookStore._upsert_row(conn, legacy)
    assert AudiobookStore.read_meta("c" * 32)["kind"] == "book"
    assert [m["kind"] for m in AudiobookStore.list_books()] == ["book"]
    response = TestClient(app).get(f"/audiobook/{'c' * 32}")
    assert response.json()["kind"] == "book"


def test_new_books_record_their_kind():
    bid = AudiobookStore.create_book("New.pdf")
    meta = AudiobookStore.initial_meta(
        bid, "New.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    assert meta["kind"] == "book"
    AudiobookStore.write_meta(bid, meta)
    assert AudiobookStore.read_meta(bid)["kind"] == "book"


def test_create_item_persists_script_pages_and_podcast_meta():
    bid = podcast_library.create_item(_script(), "Tides Explained")
    meta = AudiobookStore.read_meta(bid)
    assert meta["kind"] == PODCAST_KIND
    assert meta["page_count"] == meta["turn_count"] == 4
    assert meta["uses_gemini_cleanup"] is False
    assert meta["voice"] == "af_bella"
    assert [s["name"] for s in meta["speakers"]] == ["Ava", "Sam"]
    assert [(s["title"], s["start_page"], s["end_page"]) for s in meta["sections"]] == [
        ("Intro", 1, 2),
        ("The Moon", 3, 4),
    ]
    assert meta["estimated"]["audio_seconds"] > 0
    with open(AudiobookStore.page_clean_path(bid, 3), encoding="utf-8") as f:
        assert f.read() == "Let us talk about the moon."
    assert podcast_library.load_script(bid) == _script()
    with open(AudiobookStore.source_file_path(bid, "txt"), encoding="utf-8") as f:
        assert "Sam: Thanks for having me." in f.read()
    leftovers = [
        name
        for _, _, names in os.walk(AudiobookStore.book_dir(bid))
        for name in names
        if name.endswith(".tmp")
    ]
    assert leftovers == []


def test_create_item_cleans_up_when_saving_fails(monkeypatch):
    def broken_write(book_id, meta):
        raise OSError("disk gone")

    monkeypatch.setattr(AudiobookStore, "write_meta", broken_write)
    with pytest.raises(OSError):
        podcast_library.create_item(_script(), "Broken")
    assert AudiobookStore.list_books() == []
    assert [
        entry
        for entry in os.listdir(AudiobookStore.root_dir())
        if os.path.isdir(os.path.join(AudiobookStore.root_dir(), entry))
    ] == []


def test_unreadable_script_is_treated_as_missing():
    bid = podcast_library.create_item(_script(), "Tides")
    with open(AudiobookStore.script_path(bid), "w", encoding="utf-8") as f:
        f.write("{not json")
    assert podcast_library.load_script(bid) is None
    assert podcast_library.speaker_labels(bid) == {}
    with pytest.raises(FileNotFoundError):
        podcast_library.turn_plan(bid)


# ---------- pipeline ----------


@pytest.mark.asyncio
async def test_render_uses_each_speakers_voice_and_adds_pauses():
    bid = podcast_library.create_item(_script(), "Tides Explained")
    engine = FakeEngine()
    events = await _run(bid, engine)

    assert [voice for _, voice in engine.calls] == [
        "af_bella",
        "am_adam",
        "af_bella",
        "am_adam",
    ]
    speech = int(SPEECH_SECONDS * SAMPLE_RATE)
    assert _frames(AudiobookStore.page_audio_path(bid, 1)) == speech + SAMPLE_RATE
    assert _frames(AudiobookStore.page_audio_path(bid, 2)) == speech + int(
        0.4 * SAMPLE_RATE
    )
    assert _frames(AudiobookStore.page_audio_path(bid, 4)) == speech

    tts_done = [
        e["page"]
        for e in events
        if e["type"] == "page_done" and e.get("phase") == "tts"
    ]
    assert tts_done == [1, 2, 3, 4]
    assert events[-1]["type"] == "done"
    meta = AudiobookStore.read_meta(bid)
    assert meta["status"] == "done"
    assert meta["phase_progress"] == {"page_done": 4, "page_total": 4}


@pytest.mark.asyncio
async def test_transcript_labels_every_line_with_its_speaker():
    bid = podcast_library.create_item(_script(), "Tides Explained")
    await _run(bid, FakeEngine())
    transcript = _transcript(bid)

    assert transcript["kind"] == PODCAST_KIND
    assert [s["name"] for s in transcript["speakers"]] == ["Ava", "Sam"]
    labels = {
        key: {(line["speaker_id"], line["speaker"]) for line in lines}
        for key, lines in transcript["lines"].items()
    }
    assert labels == {
        "1": {("host_1", "Ava")},
        "2": {("host_2", "Sam")},
        "3": {("host_1", "Ava")},
        "4": {("host_2", "Sam")},
    }
    assert transcript["lines"]["2"][0]["start"] == pytest.approx(1.5)
    sections = transcript["sections"]
    assert [s["title"] for s in sections] == ["Intro", "The Moon"]
    assert sections[1]["start_time"] == pytest.approx(transcript["page_to_time"]["3"])


@pytest.mark.asyncio
async def test_book_transcripts_have_no_speaker_fields():
    bid = AudiobookStore.create_book("Book.txt")
    meta = AudiobookStore.initial_meta(
        bid, "Book.txt", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    AudiobookStore.write_meta(bid, meta)
    with open(AudiobookStore.page_clean_path(bid, 1), "w", encoding="utf-8") as f:
        f.write("Plain narration.")
    first, second, third = _engine_patches(FakeEngine())
    with first, second, third:
        await AudiobookService._phase_tts(bid, AudiobookStore.read_meta(bid))
        await AudiobookService._phase_concat(bid, AudiobookStore.read_meta(bid))
    transcript = _transcript(bid)
    assert "speakers" not in transcript and "kind" not in transcript
    assert "speaker" not in transcript["lines"]["1"][0]


@pytest.mark.asyncio
async def test_cancel_stops_rendering_and_resume_skips_finished_turns():
    bid = podcast_library.create_item(_script(), "Tides Explained")

    def cancel_on_second_turn(count: int) -> None:
        if count == 2:
            AudiobookService.cancel(bid)

    events = await _run(bid, FakeEngine(on_call=cancel_on_second_turn))
    assert events[-1]["type"] == "cancelled"
    assert AudiobookStore.read_meta(bid)["status"] == "cancelled"
    assert os.path.exists(AudiobookStore.page_audio_path(bid, 1))
    assert not os.path.exists(AudiobookStore.page_audio_path(bid, 2))

    resumed = FakeEngine()
    events = await _run(bid, resumed)
    assert [text for text, _ in resumed.calls] == [
        "Thanks for having me.",
        "Let us talk about the moon.",
        "It pulls the oceans.",
    ]
    assert events[-1]["type"] == "done"
    assert set(_transcript(bid)["lines"]) == {"1", "2", "3", "4"}


@pytest.mark.asyncio
async def test_failed_turn_is_marked_and_retry_rebuilds_its_text(monkeypatch):
    bid = podcast_library.create_item(_script(), "Tides Explained")

    class FailingEngine(FakeEngine):
        async def generate(self, text, voice, speed, lang=None, failed_segments=None):
            self.calls.append((text, voice))
            if text.startswith("Thanks"):
                raise RuntimeError("synthesis exploded")
            yield np.zeros(SAMPLE_RATE // 4, dtype=np.float32)

    events = await _run(bid, FailingEngine())
    meta = AudiobookStore.read_meta(bid)
    assert meta["status"] == "done"
    assert meta["failed_pages"] == [2]
    assert meta["page_status"]["2"] == "tts_failed"
    assert any(e["type"] == "page_failed" and e["page"] == 2 for e in events)
    assert "2" not in _transcript(bid)["lines"]

    await AudiobookStore.update_meta(bid, page_status={})
    enqueue = AsyncMock()
    monkeypatch.setattr(AudiobookService, "enqueue", enqueue)
    assert await AudiobookService.retry_failed(bid, None, cleanup=True) == 1
    enqueue.assert_awaited_once_with(bid, None)
    assert not os.path.exists(AudiobookStore.page_clean_path(bid, 2))

    retried = FakeEngine()
    await _run(bid, retried)
    assert [text for text, _ in retried.calls] == ["Thanks for having me."]
    with open(AudiobookStore.page_clean_path(bid, 2), encoding="utf-8") as f:
        assert f.read() == "Thanks for having me."
    assert _transcript(bid)["lines"]["2"][0]["speaker"] == "Sam"


@pytest.mark.asyncio
async def test_render_waits_for_interactive_speech(monkeypatch):
    lock = asyncio.Lock()
    monkeypatch.setattr("app.services.audiobook_service.interactive_tts_lock", lock)
    bid = podcast_library.create_item(_script(), "Tides Explained")
    engine = FakeEngine()
    await lock.acquire()
    task = asyncio.create_task(_run(bid, engine))
    await asyncio.sleep(0.05)
    assert engine.calls == []
    lock.release()
    events = await asyncio.wait_for(task, timeout=5)
    assert len(engine.calls) == 4
    assert events[-1]["type"] == "done"


@pytest.mark.asyncio
async def test_missing_script_fails_the_render_without_leaking_paths():
    bid = podcast_library.create_item(_script(), "Tides Explained")
    os.remove(AudiobookStore.script_path(bid))
    events = await _run(bid, FakeEngine())
    meta = AudiobookStore.read_meta(bid)
    assert meta["status"] == "failed"
    assert meta["error_code"] == "storage_unavailable"
    assert AudiobookStore.root_dir() not in meta["error"]
    assert events[-1]["type"] == "failed"


@pytest.mark.asyncio
async def test_backfilled_transcript_lines_keep_speaker_labels():
    bid = podcast_library.create_item(_script(), "Tides Explained")
    await _run(bid, FakeEngine())
    os.remove(AudiobookStore.page_timing_path(bid, 2))
    transcript = _transcript(bid)
    del transcript["lines"]["2"]
    with open(AudiobookStore.transcript_path(bid), "w", encoding="utf-8") as f:
        json.dump(transcript, f)

    AudiobookService.backfill_transcript_lines(bid)
    lines = _transcript(bid)["lines"]["2"]
    assert lines and all(line["speaker"] == "Sam" for line in lines)


@pytest.mark.asyncio
async def test_interrupted_podcast_renders_resume_without_a_provider(monkeypatch):
    AudiobookService._queue = None
    AudiobookService._worker_task = None
    bid = podcast_library.create_item(_script(), "Tides Explained")
    await AudiobookStore.update_meta(bid, status="tts")
    enqueue = AsyncMock()
    monkeypatch.setattr(AudiobookService, "enqueue", enqueue)
    try:
        await AudiobookService.resume_in_progress()
    finally:
        await AudiobookService.shutdown(grace_seconds=0.5)
    enqueue.assert_awaited_once_with(bid, None)
    assert AudiobookStore.read_meta(bid)["status"] == "tts"


# ---------- POST /podcast/render ----------


def _render_body(**overrides) -> dict:
    body = {"script": _script().model_dump(mode="json")}
    body.update(overrides)
    return body


@pytest.fixture
def started(monkeypatch):
    start = AsyncMock(return_value=True)
    monkeypatch.setattr(AudiobookService, "start", start)
    return start


def test_render_endpoint_creates_and_queues_a_podcast(started):
    client = TestClient(app)
    response = client.post("/podcast/render", json=_render_body(title="  My  Show "))
    assert response.status_code == 200
    body = response.json()
    bid = body["book_id"]
    assert body["status"] == "queued"
    assert body["kind"] == PODCAST_KIND
    assert body["title"] == "My Show"
    assert body["turn_count"] == 4
    assert [s["voice"] for s in body["speakers"]] == ["af_bella", "am_adam"]
    assert body["estimated_audio_seconds"] > 0
    started.assert_awaited_once_with(bid, None, uses_llm_cleanup=False)

    listed = client.get("/audiobook").json()
    assert [(item["book_id"], item["kind"]) for item in listed] == [(bid, "podcast")]
    script = client.get(f"/podcast/{bid}/script").json()
    assert script["title"] == "My Show"
    assert script["turns"][0]["section"] == "Intro"


def test_render_keeps_the_script_title_when_none_is_given(started):
    response = TestClient(app).post("/podcast/render", json=_render_body())
    assert response.json()["title"] == "Tides Explained"


def test_user_written_single_voice_script_renders(started):
    script = {
        "title": "Notes to self",
        "speakers": [{"id": "me", "name": "Me", "voice": "bf_emma"}],
        "turns": [{"speaker_id": "me", "text": "Remember the milk."}],
    }
    response = TestClient(app).post("/podcast/render", json={"script": script})
    assert response.status_code == 200
    assert response.json()["speakers"] == [
        {"id": "me", "name": "Me", "voice": "bf_emma"}
    ]


@pytest.mark.parametrize(
    "mutate",
    [
        lambda s: s["speakers"][0].update(voice="zz_unknown"),
        lambda s: s["turns"].append({"speaker_id": "nobody", "text": "Hi."}),
        lambda s: s["turns"][0].update(text="x" * 2001),
        lambda s: s["turns"][0].update(pause_after_seconds=4),
        lambda s: s.update(turns=[]),
        lambda s: s.update(speakers=s["speakers"] * 3),
    ],
)
def test_render_endpoint_rejects_invalid_scripts(started, mutate):
    body = _render_body()
    mutate(body["script"])
    response = TestClient(app).post("/podcast/render", json=body)
    assert response.status_code == 422
    started.assert_not_awaited()
    assert AudiobookStore.list_books() == []


def test_render_endpoint_rejects_overlong_titles(started):
    response = TestClient(app).post(
        "/podcast/render", json=_render_body(title="t" * 201)
    )
    assert response.status_code == 422


def test_render_endpoint_enforces_the_duration_limit(started, monkeypatch):
    monkeypatch.setattr(settings, "MAX_AUDIOBOOK_DURATION_SECONDS", 1)
    response = TestClient(app).post("/podcast/render", json=_render_body())
    assert response.status_code == 413
    assert AudiobookStore.list_books() == []


def test_render_endpoint_enforces_storage_capacity(started, monkeypatch):
    def full(*args, **kwargs):
        raise ImportLimitError("Your Voqora library is full.")

    monkeypatch.setattr("app.api.podcast.ensure_storage_capacity", full)
    response = TestClient(app).post("/podcast/render", json=_render_body())
    assert response.status_code == 413
    assert "library is full" in response.json()["detail"]


def test_render_endpoint_hides_storage_errors(started, monkeypatch):
    def broken(*args, **kwargs):
        raise OSError("/Users/someone/Library/private")

    monkeypatch.setattr(podcast_library, "create_item", broken)
    response = TestClient(app).post("/podcast/render", json=_render_body())
    assert response.status_code == 500
    assert "/Users" not in response.json()["detail"]
    started.assert_not_awaited()


def test_render_endpoint_reports_a_rejected_start(monkeypatch):
    monkeypatch.setattr(AudiobookService, "start", AsyncMock(return_value=False))
    cover = AsyncMock()
    monkeypatch.setattr("app.api.podcast._render_cover_task", cover)
    response = TestClient(app).post("/podcast/render", json=_render_body())
    assert response.status_code == 409
    assert AudiobookStore.list_books() == []
    cover.assert_not_called()


def test_render_endpoint_removes_the_item_when_start_crashes(monkeypatch):
    monkeypatch.setattr(
        AudiobookService, "start", AsyncMock(side_effect=RuntimeError("queue"))
    )
    client = TestClient(app, raise_server_exceptions=False)
    response = client.post("/podcast/render", json=_render_body())
    assert response.status_code == 500
    assert AudiobookStore.list_books() == []


def test_script_lookup_errors():
    client = TestClient(app)
    assert client.get("/podcast/not-an-id/script").status_code == 400
    assert client.get(f"/podcast/{'d' * 32}/script").status_code == 404
    bid = AudiobookStore.create_book("Book.pdf")
    AudiobookStore.write_meta(
        bid,
        AudiobookStore.initial_meta(
            bid, "Book.pdf", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
        ),
    )
    assert client.get(f"/podcast/{bid}/script").status_code == 404
    podcast = podcast_library.create_item(_script(), "Tides")
    os.remove(AudiobookStore.script_path(podcast))
    assert client.get(f"/podcast/{podcast}/script").status_code == 404


def test_podcast_items_use_audiobook_cancel_and_retry_routes(monkeypatch):
    bid = podcast_library.create_item(_script(), "Tides")
    client = TestClient(app)
    assert client.post(f"/audiobook/{bid}/cancel").json()["status"] == "cancelling"
    AudiobookService._cancel_flags.pop(bid, None)
    asyncio.run(AudiobookStore.update_meta(bid, status="cancelled"))
    enqueue = AsyncMock()
    monkeypatch.setattr(AudiobookService, "enqueue", enqueue)
    response = client.post(f"/audiobook/{bid}/retry")
    assert response.status_code == 200
    enqueue.assert_awaited_once_with(bid, None)
