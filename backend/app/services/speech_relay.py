from __future__ import annotations

import asyncio
import unicodedata
import uuid
from typing import Any

from app.core.config import settings
from app.core.logging import get_logger

log = get_logger(__name__)

RelayEvent = dict[str, Any]
RelayQueue = asyncio.Queue[RelayEvent | None]

RELAY_UNAVAILABLE_MESSAGE = (
    "The Voqora app is not listening. Open Voqora and try again."
)
RELAY_BUSY_MESSAGE = "Too much speech is queued. Try again shortly."
MAX_CLIENT_NAME_CHARS = 64
_INVISIBLE_CATEGORIES = frozenset({"Cc", "Cf"})


class RelayUnavailableError(Exception):
    pass


class RelayBusyError(Exception):
    pass


class SpeechRelay:
    def __init__(self, queue_size: int, max_subscribers: int) -> None:
        self._queue_size = queue_size
        self._max_subscribers = max_subscribers
        self._subscribers: list[RelayQueue] = []

    @property
    def subscriber_count(self) -> int:
        return len(self._subscribers)

    def subscribe(self) -> RelayQueue:
        while len(self._subscribers) >= self._max_subscribers:
            self._close(self._subscribers.pop(0))
            log.info("relay.subscriber_evicted")
        queue: RelayQueue = asyncio.Queue(maxsize=self._queue_size)
        self._subscribers.append(queue)
        return queue

    def unsubscribe(self, queue: RelayQueue) -> None:
        if queue in self._subscribers:
            self._subscribers.remove(queue)

    def speak(self, text: str, voice: str | None, client: str | None = None) -> str:
        self._require_subscriber()
        if any(queue.full() for queue in self._subscribers):
            raise RelayBusyError
        event = _event("speak", text=text, voice=voice, client=client)
        for queue in self._subscribers:
            queue.put_nowait(event)
        log.info("relay.speak_queued", extra={"text_len": len(text)})
        return event["id"]

    def stop(self) -> str:
        self._require_subscriber()
        event = _event("stop")
        for queue in self._subscribers:
            _drain(queue)
            queue.put_nowait(event)
        log.info("relay.stop_queued")
        return event["id"]

    def close_all(self) -> None:
        while self._subscribers:
            self._close(self._subscribers.pop())

    def _require_subscriber(self) -> None:
        if not self._subscribers:
            raise RelayUnavailableError

    @staticmethod
    def _close(queue: RelayQueue) -> None:
        _drain(queue)
        queue.put_nowait(None)


def client_name(raw: Any) -> str | None:
    if not isinstance(raw, str):
        return None
    printable = "".join(
        " " if unicodedata.category(ch) in _INVISIBLE_CATEGORIES else ch for ch in raw
    )
    return " ".join(printable.split())[:MAX_CLIENT_NAME_CHARS].strip() or None


def _event(kind: str, **fields: Any) -> RelayEvent:
    return {"type": kind, "id": uuid.uuid4().hex, **fields}


def _drain(queue: RelayQueue) -> None:
    while not queue.empty():
        queue.get_nowait()


speech_relay = SpeechRelay(
    queue_size=settings.SPEECH_RELAY_QUEUE_SIZE,
    max_subscribers=settings.SPEECH_RELAY_MAX_SUBSCRIBERS,
)
