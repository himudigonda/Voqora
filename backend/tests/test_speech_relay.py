"""'Speak on this Mac' relay: bounded queue, subscribers, SSE delivery."""

from __future__ import annotations

import asyncio
import json
from collections.abc import Iterator
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient

from app.api import integrations
from app.api.integrations import relay_event_stream
from app.api.public_app import create_public_app
from app.core.config import settings
from app.main import app
from app.services.speech_relay import (
    RelayBusyError,
    RelayUnavailableError,
    SpeechRelay,
    speech_relay,
)

API_KEY = "test-local-api-key-0123456789abcdef"
AUTH = {"Authorization": f"Bearer {API_KEY}"}


@pytest.fixture(autouse=True)
def clean_relay() -> Iterator[None]:
    speech_relay.close_all()
    yield
    speech_relay.close_all()


@pytest.fixture
def public() -> TestClient:
    return TestClient(create_public_app(API_KEY), headers=AUTH)


def _parse_sse(chunk: str) -> dict:
    assert chunk.startswith("data: ") and chunk.endswith("\n\n")
    return json.loads(chunk[len("data: ") :])


def test_speak_without_subscriber_raises() -> None:
    relay = SpeechRelay(queue_size=2, max_subscribers=2)
    with pytest.raises(RelayUnavailableError):
        relay.speak("hello", None)
    with pytest.raises(RelayUnavailableError):
        relay.stop()


def test_speak_delivers_to_every_subscriber() -> None:
    relay = SpeechRelay(queue_size=2, max_subscribers=3)
    first, second = relay.subscribe(), relay.subscribe()
    event_id = relay.speak("hello", "af_bella")
    for queue in (first, second):
        event = queue.get_nowait()
        assert event == {
            "type": "speak",
            "id": event_id,
            "text": "hello",
            "voice": "af_bella",
        }


def test_full_queue_rejects_without_partial_delivery() -> None:
    relay = SpeechRelay(queue_size=1, max_subscribers=2)
    first = relay.subscribe()
    relay.speak("one", None)
    second = relay.subscribe()
    with pytest.raises(RelayBusyError):
        relay.speak("two", None)
    assert second.empty()
    assert first.qsize() == 1


def test_stop_replaces_pending_commands() -> None:
    relay = SpeechRelay(queue_size=2, max_subscribers=1)
    queue = relay.subscribe()
    relay.speak("one", None)
    relay.speak("two", None)
    stop_id = relay.stop()
    assert queue.get_nowait() == {"type": "stop", "id": stop_id}
    assert queue.empty()


def test_stop_always_fits_even_when_full() -> None:
    relay = SpeechRelay(queue_size=1, max_subscribers=1)
    queue = relay.subscribe()
    relay.speak("one", None)
    relay.stop()
    relay.stop()
    assert queue.qsize() == 1


def test_oldest_subscriber_is_evicted_at_cap() -> None:
    relay = SpeechRelay(queue_size=2, max_subscribers=2)
    oldest = relay.subscribe()
    relay.subscribe()
    relay.subscribe()
    assert relay.subscriber_count == 2
    assert oldest.get_nowait() is None


def test_unsubscribe_is_idempotent() -> None:
    relay = SpeechRelay(queue_size=2, max_subscribers=2)
    queue = relay.subscribe()
    relay.unsubscribe(queue)
    relay.unsubscribe(queue)
    assert relay.subscriber_count == 0


def test_close_all_signals_every_subscriber() -> None:
    relay = SpeechRelay(queue_size=1, max_subscribers=2)
    first, second = relay.subscribe(), relay.subscribe()
    relay.speak("pending", None)
    relay.close_all()
    assert relay.subscriber_count == 0
    assert first.get_nowait() is None
    assert second.get_nowait() is None


@pytest.mark.asyncio
async def test_event_stream_delivers_ready_then_events_then_ends() -> None:
    relay = SpeechRelay(queue_size=4, max_subscribers=1)
    stream = relay_event_stream(relay, keepalive_seconds=5)
    assert _parse_sse(await anext(stream)) == {"type": "ready"}
    assert relay.subscriber_count == 1
    relay.speak("hello", None)
    event = _parse_sse(await anext(stream))
    assert event["type"] == "speak" and event["text"] == "hello"
    relay.close_all()
    with pytest.raises(StopAsyncIteration):
        await anext(stream)
    assert relay.subscriber_count == 0


@pytest.mark.asyncio
async def test_event_stream_sends_keepalive() -> None:
    relay = SpeechRelay(queue_size=4, max_subscribers=1)
    stream = relay_event_stream(relay, keepalive_seconds=0.01)
    await anext(stream)
    assert await anext(stream) == ": keep-alive\n\n"
    await stream.aclose()
    assert relay.subscriber_count == 0


@pytest.mark.asyncio
async def test_event_stream_unsubscribes_when_cancelled() -> None:
    relay = SpeechRelay(queue_size=4, max_subscribers=1)
    stream = relay_event_stream(relay, keepalive_seconds=5)
    await anext(stream)
    pending = asyncio.ensure_future(anext(stream))
    await asyncio.sleep(0.01)
    pending.cancel()
    with pytest.raises(asyncio.CancelledError):
        await pending
    assert relay.subscriber_count == 0


class _PrefilledRelay(SpeechRelay):
    def subscribe(self):
        queue = super().subscribe()
        queue.put_nowait({"type": "speak", "id": "1", "text": "hi", "voice": None})
        queue.put_nowait(None)
        return queue


def test_events_route_streams_relay_over_private_ipc() -> None:
    relay = _PrefilledRelay(queue_size=4, max_subscribers=1)
    with patch.object(integrations, "speech_relay", relay):
        with TestClient(app).stream("GET", "/integrations/events") as response:
            assert response.status_code == 200
            assert response.headers["content-type"].startswith("text/event-stream")
            assert response.headers["cache-control"] == "no-cache"
            lines = [line for line in response.iter_lines() if line]
    events = [json.loads(line.removeprefix("data: ")) for line in lines]
    assert events == [
        {"type": "ready"},
        {"type": "speak", "id": "1", "text": "hi", "voice": None},
    ]
    assert relay.subscriber_count == 0


def test_events_route_requires_ipc_token() -> None:
    response = TestClient(app, headers={"X-Voqora-IPC-Token": ""}).get(
        "/integrations/events"
    )
    assert response.status_code == 401


def test_relay_speak_returns_503_without_app(public: TestClient) -> None:
    response = public.post("/v1/voqora/speak", json={"text": "hello"})
    assert response.status_code == 503
    assert response.json()["error"]["type"] == "service_unavailable_error"


def test_relay_stop_returns_503_without_app(public: TestClient) -> None:
    assert public.post("/v1/voqora/stop").status_code == 503


def test_relay_speak_queues_for_app(public: TestClient) -> None:
    queue = speech_relay.subscribe()
    response = public.post(
        "/v1/voqora/speak", json={"text": "## Hello *world*", "voice": "echo"}
    )
    assert response.status_code == 202
    body = response.json()
    assert body["status"] == "queued"
    event = queue.get_nowait()
    assert event["id"] == body["id"]
    assert event["text"] == "Hello world"
    assert event["voice"] == "am_michael"


def test_relay_speak_without_voice_lets_app_choose(public: TestClient) -> None:
    queue = speech_relay.subscribe()
    public.post("/v1/voqora/speak", json={"text": "hello"})
    assert queue.get_nowait()["voice"] is None


def test_relay_stop_queues_for_app(public: TestClient) -> None:
    queue = speech_relay.subscribe()
    response = public.post("/v1/voqora/stop")
    assert response.status_code == 202
    assert queue.get_nowait() == {"type": "stop", "id": response.json()["id"]}


@pytest.mark.parametrize(
    ("method", "path", "body"),
    [
        ("speak", "/v1/voqora/speak", {"text": "hello"}),
        ("stop", "/v1/voqora/stop", None),
    ],
)
def test_relay_routes_touch_queues_on_the_event_loop(
    public: TestClient, method: str, path: str, body: dict | None
) -> None:
    def require_event_loop(*_args: object) -> str:
        asyncio.get_running_loop()
        return "event-id"

    with patch.object(speech_relay, method, side_effect=require_event_loop):
        response = public.post(path, json=body)
    assert response.status_code == 202
    assert response.json()["id"] == "event-id"


def test_relay_speak_returns_429_when_queue_full(public: TestClient) -> None:
    speech_relay.subscribe()
    statuses = [
        public.post("/v1/voqora/speak", json={"text": f"n{i}"}).status_code
        for i in range(settings.SPEECH_RELAY_QUEUE_SIZE + 4)
    ]
    assert statuses.count(202) == settings.SPEECH_RELAY_QUEUE_SIZE
    assert statuses[-1] == 429


@pytest.mark.parametrize(
    "body",
    [
        {},
        {"text": ""},
        {"text": "  "},
        {"text": "a" * 50_001},
        {"text": "hi", "voice": "nope"},
        {"text": "hi", "voice": ""},
    ],
)
def test_relay_speak_validates(public: TestClient, body: dict) -> None:
    speech_relay.subscribe()
    response = public.post("/v1/voqora/speak", json=body)
    assert response.status_code == 400
