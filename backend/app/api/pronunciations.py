"""Pronunciation dictionary HTTP surface."""

from typing import Any

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel, Field, StrictBool, field_validator

from app.core.logging import get_logger
from app.services.audiobook_store import AudiobookStore
from app.services.engine_manager import EngineManager
from app.services.pronunciation import (
    MAX_ENTRIES,
    MAX_MATCH_CHARS,
    MAX_REPLACEMENT_CHARS,
    SCOPE_GLOBAL,
    DuplicatePronunciationError,
    PronunciationLimitError,
    PronunciationNotFoundError,
    is_book_scope,
    is_entry_id,
    pronunciations,
    validate_match,
    validate_replacement,
    validate_scope,
)

router = APIRouter()
log = get_logger(__name__)

_MAX_TEST_TEXT_CHARS = 5_000
_SCOPE_MAX_CHARS = 32


class PronunciationRequest(BaseModel):
    match: str = Field(min_length=1, max_length=MAX_MATCH_CHARS * 2)
    replacement: str = Field(default="", max_length=MAX_REPLACEMENT_CHARS * 2)
    case_sensitive: StrictBool = False
    whole_word: StrictBool = True
    scope: str = Field(default=SCOPE_GLOBAL, max_length=_SCOPE_MAX_CHARS)

    @field_validator("match")
    @classmethod
    def require_valid_match(cls, value: str) -> str:
        return validate_match(value)

    @field_validator("replacement")
    @classmethod
    def require_valid_replacement(cls, value: str) -> str:
        return validate_replacement(value)

    @field_validator("scope")
    @classmethod
    def require_valid_scope(cls, value: str) -> str:
        return validate_scope(value)


class PronunciationTestRequest(BaseModel):
    text: str = Field(min_length=1, max_length=_MAX_TEST_TEXT_CHARS)
    book_id: str | None = Field(default=None, max_length=_SCOPE_MAX_CHARS)

    @field_validator("book_id")
    @classmethod
    def require_valid_book_id(cls, value: str | None) -> str | None:
        if value is not None and not is_book_scope(value):
            raise ValueError("book_id must be a book id")
        return value


def _require_scope_exists(scope: str) -> None:
    if scope != SCOPE_GLOBAL and AudiobookStore.read_meta(scope) is None:
        raise HTTPException(status_code=404, detail="Book not found.")


def _validate_entry_id(entry_id: str) -> None:
    if not is_entry_id(entry_id):
        raise HTTPException(status_code=400, detail="Invalid pronunciation id.")


def _save_failed(action: str) -> HTTPException:
    log.error(
        "pronunciation.save_failed",
        extra={"action": action, "failure_code": "pronunciation_save_failed"},
        exc_info=True,
    )
    return HTTPException(
        status_code=500, detail="Could not save pronunciations. Please try again."
    )


@router.get("/pronunciations")
def list_pronunciations(
    scope: str | None = Query(default=None, max_length=_SCOPE_MAX_CHARS),
) -> dict[str, Any]:
    """List dictionary entries, optionally only one scope."""
    if scope is not None:
        try:
            validate_scope(scope)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail="Invalid scope.") from exc
    return {
        "version": pronunciations.version,
        "max_entries": MAX_ENTRIES,
        "entries": [entry.to_dict() for entry in pronunciations.list(scope)],
    }


@router.post("/pronunciations", status_code=201)
def create_pronunciation(req: PronunciationRequest) -> dict[str, Any]:
    _require_scope_exists(req.scope)
    try:
        entry = pronunciations.create(**req.model_dump())
    except (PronunciationLimitError, DuplicatePronunciationError) as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except OSError as exc:
        raise _save_failed("create") from exc
    log.info("pronunciation.created", extra={"scope_kind": _scope_kind(entry.scope)})
    return entry.to_dict()


@router.put("/pronunciations/{entry_id}")
def update_pronunciation(entry_id: str, req: PronunciationRequest) -> dict[str, Any]:
    _validate_entry_id(entry_id)
    _require_scope_exists(req.scope)
    try:
        entry = pronunciations.update(entry_id, **req.model_dump())
    except PronunciationNotFoundError as exc:
        raise HTTPException(status_code=404, detail="Pronunciation not found.") from exc
    except DuplicatePronunciationError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except OSError as exc:
        raise _save_failed("update") from exc
    log.info("pronunciation.updated", extra={"scope_kind": _scope_kind(entry.scope)})
    return entry.to_dict()


@router.delete("/pronunciations/{entry_id}")
def delete_pronunciation(entry_id: str) -> dict[str, str]:
    _validate_entry_id(entry_id)
    try:
        deleted = pronunciations.delete(entry_id)
    except OSError as exc:
        raise _save_failed("delete") from exc
    if not deleted:
        raise HTTPException(status_code=404, detail="Pronunciation not found.")
    log.info("pronunciation.deleted")
    return {"status": "deleted", "id": entry_id}


@router.post("/pronunciations/test")
def test_pronunciation(req: PronunciationTestRequest) -> dict[str, Any]:
    """Show what the narrator will say for a sample with the saved dictionary."""
    rules = pronunciations.rules_for(req.book_id)
    spoken: list[str] = []
    replacements = 0
    for segment in EngineManager.split_segments(req.text):
        text, count = rules.apply_counted(segment)
        replacements += count
        if text.strip():
            spoken.append(text.strip())
    return {
        "text": req.text,
        "spoken": " ".join(spoken),
        "replacements": replacements,
        "version": rules.version,
    }


def _scope_kind(scope: str) -> str:
    return "global" if scope == SCOPE_GLOBAL else "book"
