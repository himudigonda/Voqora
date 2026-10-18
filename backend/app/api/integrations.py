from __future__ import annotations

import asyncio
import json
from collections.abc import AsyncGenerator

from fastapi import APIRouter
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field, model_validator

from app.api.public_app import create_public_app
from app.core.config import settings
from app.services.local_api_server import LocalAPIConfig, LocalAPIServer
from app.services.speech_relay import SpeechRelay, speech_relay

router = APIRouter()

local_api_server = LocalAPIServer(
    create_public_app,
    max_connections=settings.LOCAL_API_MAX_CONNECTIONS,
    start_timeout_s=settings.LOCAL_API_START_TIMEOUT_S,
    stop_timeout_s=settings.LOCAL_API_STOP_TIMEOUT_S,
)

API_KEY_PATTERN = r"^[A-Za-z0-9._~+/=-]+$"
EVENTS_KEEPALIVE_SECONDS = 15.0


class LocalAPISettingsRequest(BaseModel):
    enabled: bool
    port: int | None = Field(default=None, ge=1024, le=65535)
    api_key: str | None = Field(
        default=None, min_length=32, max_length=128, pattern=API_KEY_PATTERN
    )

    @model_validator(mode="after")
    def require_port_and_key_when_enabled(self) -> LocalAPISettingsRequest:
        if self.enabled and (self.port is None or self.api_key is None):
            raise ValueError("port and api_key are required when enabled")
        return self

    def to_config(self) -> LocalAPIConfig | None:
        if self.port is None or self.api_key is None:
            return None
        return LocalAPIConfig(port=self.port, api_key=self.api_key)


@router.get("/integrations/local-api")
def get_local_api() -> dict[str, object]:
    """Current state of the opt-in local API. Never returns the API key."""
    return local_api_server.status().to_dict()


@router.post("/integrations/local-api")
async def set_local_api(req: LocalAPISettingsRequest) -> JSONResponse:
    """Start, restart, or stop the local API. 409 when the port cannot be used."""
    status = await local_api_server.apply(req.enabled, req.to_config())
    code = 409 if status.error_code else 200
    return JSONResponse(status.to_dict(), status_code=code)


@router.get("/integrations/events")
async def integration_events() -> StreamingResponse:
    """Server-sent speak and stop commands from the local API for the app to play."""
    return StreamingResponse(
        relay_event_stream(speech_relay),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache"},
    )


async def relay_event_stream(
    relay: SpeechRelay, keepalive_seconds: float = EVENTS_KEEPALIVE_SECONDS
) -> AsyncGenerator[str, None]:
    queue = relay.subscribe()
    try:
        yield _sse({"type": "ready"})
        while True:
            try:
                event = await asyncio.wait_for(queue.get(), timeout=keepalive_seconds)
            except TimeoutError:
                yield ": keep-alive\n\n"
                continue
            if event is None:
                return
            yield _sse(event)
    finally:
        relay.unsubscribe(queue)


def _sse(payload: dict[str, object]) -> str:
    return f"data: {json.dumps(payload)}\n\n"
