from __future__ import annotations

from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass
from typing import Any

import numpy as np
from fastapi import APIRouter
from fastapi.responses import JSONResponse, Response, StreamingResponse
from pydantic import BaseModel, Field, field_validator

from app.api.public_errors import error_response
from app.core.logging import get_logger
from app.services.audio import AudioService
from app.services.public_voices import (
    MAX_VOICE_ID_CHARS,
    OPENAI_VOICE_ALIASES,
    require_voice,
    voice_list,
)
from app.services.speech_relay import (
    RELAY_BUSY_MESSAGE,
    RELAY_UNAVAILABLE_MESSAGE,
    RelayBusyError,
    RelayUnavailableError,
    speech_relay,
)
from app.services.speech_stream import (
    MAX_SPEECH_CHARS,
    clamp_engine_speed,
    open_speech_samples,
    speakable_text,
)

router = APIRouter()
log = get_logger("voqora.local_api")

SPEECH_MODELS = ("kokoro", "tts-1", "tts-1-hd")
_MODEL_CREATED = 1735689600


@dataclass(frozen=True)
class AudioFormat:
    media_type: str
    encode: Callable[[AsyncIterator[np.ndarray]], AsyncIterator[bytes]]


AUDIO_FORMATS: dict[str, AudioFormat] = {
    "wav": AudioFormat(
        "audio/wav", lambda samples: AudioService.stream_samples_to_wav(samples, 1.0)
    ),
    "pcm": AudioFormat("audio/pcm", AudioService.stream_samples_to_pcm),
    "flac": AudioFormat("audio/flac", AudioService.stream_samples_to_flac),
}


class SpeechRequest(BaseModel):
    model: str = Field(min_length=1, max_length=64)
    input: str = Field(min_length=1, max_length=MAX_SPEECH_CHARS)
    voice: str = Field(min_length=1, max_length=MAX_VOICE_ID_CHARS)
    response_format: str = Field(default="wav", min_length=1, max_length=16)
    speed: float = Field(default=1.0, ge=0.25, le=4.0)

    @field_validator("model")
    @classmethod
    def require_known_model(cls, value: str) -> str:
        if value not in SPEECH_MODELS:
            raise ValueError(f"Unknown model. Use one of: {', '.join(SPEECH_MODELS)}.")
        return value

    @field_validator("input")
    @classmethod
    def require_meaningful_input(cls, value: str) -> str:
        return speakable_text(value)

    @field_validator("voice")
    @classmethod
    def require_known_voice(cls, value: str) -> str:
        return require_voice(value)

    @field_validator("response_format")
    @classmethod
    def require_supported_format(cls, value: str) -> str:
        if value not in AUDIO_FORMATS:
            raise ValueError(
                f"Unsupported response_format '{value}'. "
                f"Supported formats: {', '.join(AUDIO_FORMATS)}."
            )
        return value


class RelaySpeakRequest(BaseModel):
    text: str = Field(min_length=1, max_length=MAX_SPEECH_CHARS)
    voice: str | None = Field(default=None, min_length=1, max_length=MAX_VOICE_ID_CHARS)

    @field_validator("text")
    @classmethod
    def require_meaningful_text(cls, value: str) -> str:
        return speakable_text(value)

    @field_validator("voice")
    @classmethod
    def require_known_voice(cls, value: str | None) -> str | None:
        return None if value is None else require_voice(value)


def _model_entry(model_id: str) -> dict[str, Any]:
    return {
        "id": model_id,
        "object": "model",
        "created": _MODEL_CREATED,
        "owned_by": "voqora",
    }


@router.get("/v1/models")
def list_models() -> dict[str, Any]:
    """OpenAI-compatible model list. Every alias uses the local Kokoro model."""
    return {"object": "list", "data": [_model_entry(m) for m in SPEECH_MODELS]}


@router.get("/v1/voices")
def list_voices() -> dict[str, Any]:
    """Built-in and custom voices, plus the OpenAI voice names they map to."""
    return {"object": "list", "data": voice_list(), "aliases": OPENAI_VOICE_ALIASES}


@router.post("/v1/audio/speech")
async def create_speech(req: SpeechRequest) -> Response:
    """OpenAI-compatible speech. Streams 24 kHz mono 16-bit audio."""
    audio_format = AUDIO_FORMATS[req.response_format]
    try:
        samples = await open_speech_samples(
            req.input, req.voice, clamp_engine_speed(req.speed)
        )
    except Exception:
        log.error(
            "local_api.speech_failed",
            extra={
                "failure_code": "speech_request_failed",
                "voice": req.voice,
                "text_len": len(req.input),
            },
            exc_info=True,
        )
        return error_response(
            500, "Speech generation failed. Check that Voqora's voice model is ready."
        )
    return StreamingResponse(
        audio_format.encode(samples), media_type=audio_format.media_type
    )


@router.post("/v1/voqora/speak", status_code=202)
async def relay_speak(req: RelaySpeakRequest) -> JSONResponse:
    """Ask the Voqora app to speak text aloud on this Mac."""
    return _relay(lambda: speech_relay.speak(req.text, req.voice))


@router.post("/v1/voqora/stop", status_code=202)
async def relay_stop() -> JSONResponse:
    """Ask the Voqora app to stop speaking and drop queued speech."""
    return _relay(speech_relay.stop)


def _relay(command: Callable[[], str]) -> JSONResponse:
    try:
        event_id = command()
    except RelayUnavailableError:
        return error_response(503, RELAY_UNAVAILABLE_MESSAGE)
    except RelayBusyError:
        return error_response(429, RELAY_BUSY_MESSAGE, headers={"Retry-After": "1"})
    return JSONResponse({"status": "queued", "id": event_id}, status_code=202)
