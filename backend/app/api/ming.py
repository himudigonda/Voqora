import asyncio
from typing import Any

from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field, field_validator

from app.core.logging import get_logger
from app.services.engine_errors import EngineNotInstalledError, EngineWorkerError
from app.services.engine_manager import MING, EngineManager
from app.services.ming_catalog import is_ming_voice
from app.services.ming_engine import MingEngine
from app.services.ming_voices import (
    MAX_CLONE_UPLOAD_BYTES,
    MAX_DESCRIPTION_CHARS,
    MAX_TRANSCRIPT_CHARS,
    VoiceLimitError,
    VoiceValidationError,
    default_sample_text,
    is_custom_voice_id,
    ming_voices,
    prepare_clone_audio,
    require_language,
    require_name,
    require_text,
)
from app.services.voice_blends import MAX_NAME_CHARS
from app.services.voices import ming_spec

router = APIRouter()
log = get_logger(__name__)

MAX_SAMPLE_TEXT_CHARS = 500
SAVE_FAILED_MESSAGE = "Could not save that voice. Please try again."


def _checked(check, value, *arguments):
    try:
        return check(value, *arguments)
    except VoiceValidationError as error:
        raise ValueError(str(error)) from None


class DesignRequest(BaseModel):
    name: str = Field(min_length=1, max_length=MAX_NAME_CHARS * 2)
    description: str = Field(min_length=1, max_length=MAX_DESCRIPTION_CHARS * 2)
    language: str = Field(min_length=2, max_length=8)
    sample_text: str | None = Field(default=None, max_length=MAX_SAMPLE_TEXT_CHARS * 2)

    @field_validator("name")
    @classmethod
    def require_valid_name(cls, value: str) -> str:
        return _checked(require_name, value)

    @field_validator("description")
    @classmethod
    def require_valid_description(cls, value: str) -> str:
        return _checked(require_text, value, "description", MAX_DESCRIPTION_CHARS)

    @field_validator("language")
    @classmethod
    def require_supported_language(cls, value: str) -> str:
        return _checked(require_language, value)

    @field_validator("sample_text")
    @classmethod
    def require_valid_sample_text(cls, value: str | None) -> str | None:
        if value is None or not value.strip():
            return None
        return _checked(require_text, value, "sample_text", MAX_SAMPLE_TEXT_CHARS)


def _require_installed() -> None:
    try:
        EngineManager.require_installed(MING)
    except EngineNotInstalledError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error


def _unprocessable(error: VoiceValidationError) -> HTTPException:
    return HTTPException(status_code=422, detail=str(error))


def _worker_failed(error: EngineWorkerError, action: str) -> HTTPException:
    log.error(
        "ming.voice_request_failed",
        extra={"action": action, "failure_code": "ming_voice_request_failed"},
        exc_info=True,
    )
    return HTTPException(status_code=500, detail=str(error))


def _save_failed(action: str) -> HTTPException:
    log.error(
        "ming.voice_save_failed",
        extra={"action": action, "failure_code": "ming_voice_save_failed"},
        exc_info=True,
    )
    return HTTPException(status_code=500, detail=SAVE_FAILED_MESSAGE)


@router.get("/engine/ming/voices")
def list_ming_voices() -> dict[str, Any]:
    _require_installed()
    return {"voices": EngineManager.ming_voice_entries()}


@router.post("/engine/ming/voices/design", status_code=201)
async def design_ming_voice(req: DesignRequest) -> dict[str, Any]:
    _require_installed()
    text = req.sample_text or default_sample_text(req.language)
    try:
        samples = await MingEngine.design_sample(req.description, req.language, text)
    except EngineNotInstalledError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error
    except EngineWorkerError as error:
        raise _worker_failed(error, "design") from error
    try:
        voice = ming_voices.create(
            name=req.name,
            language=req.language,
            kind="designed",
            description=req.description,
            transcript=text,
            samples=samples,
        )
    except VoiceLimitError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error
    except OSError as error:
        raise _save_failed("design") from error
    log.info("ming.voice_designed", extra={"language": req.language})
    return voice.to_entry()


@router.post("/engine/ming/voices/clone", status_code=201)
async def clone_ming_voice(
    name: str = Form(...),
    language: str = Form(...),
    transcript: str = Form(...),
    file: UploadFile = File(...),
) -> dict[str, Any]:
    _require_installed()
    try:
        clean_name = require_name(name)
        clean_language = require_language(language)
        clean_transcript = require_text(transcript, "transcript", MAX_TRANSCRIPT_CHARS)
        data = await file.read(MAX_CLONE_UPLOAD_BYTES + 1)
        samples = await asyncio.to_thread(prepare_clone_audio, data)
    except VoiceValidationError as error:
        raise _unprocessable(error) from error
    try:
        voice = ming_voices.create(
            name=clean_name,
            language=clean_language,
            kind="cloned",
            description="",
            transcript=clean_transcript,
            samples=samples,
        )
    except VoiceLimitError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error
    except OSError as error:
        raise _save_failed("clone") from error
    log.info("ming.voice_cloned", extra={"language": clean_language})
    return voice.to_entry()


@router.delete("/engine/ming/voices/{voice_id}")
def delete_ming_voice(voice_id: str) -> dict[str, str]:
    _require_installed()
    if not is_custom_voice_id(voice_id):
        raise HTTPException(status_code=400, detail="Invalid voice id.")
    try:
        deleted = ming_voices.delete(voice_id)
    except OSError as error:
        raise _save_failed("delete") from error
    if not deleted:
        raise HTTPException(status_code=404, detail="Voice not found.")
    log.info("ming.voice_deleted")
    return {"status": "deleted", "id": voice_id}


@router.get("/engine/ming/voices/{voice_id}/sample")
async def ming_voice_sample(voice_id: str) -> FileResponse:
    _require_installed()
    custom = ming_voices.get(voice_id)
    if custom is not None:
        return FileResponse(ming_voices.wav_path(custom.id), media_type="audio/wav")
    if not is_ming_voice(voice_id):
        raise HTTPException(status_code=404, detail="Voice not found.")
    try:
        reference = await MingEngine.prepare_reference(ming_spec(voice_id))
    except EngineNotInstalledError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error
    except EngineWorkerError as error:
        raise _worker_failed(error, "sample") from error
    return FileResponse(reference.wav_path, media_type="audio/wav")
