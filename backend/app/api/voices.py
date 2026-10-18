"""Voice blend HTTP surface: named custom voices mixed from built-in voices."""

from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field, field_validator, model_validator

from app.core.logging import get_logger
from app.services.voice_blends import (
    MAX_BLENDS,
    MAX_COMPONENTS,
    MAX_NAME_CHARS,
    MAX_WEIGHT,
    MIN_COMPONENTS,
    MIN_WEIGHT,
    BlendLimitError,
    BlendNotFoundError,
    is_blend_id,
    validate_components,
    validate_name,
    voice_blends,
)

router = APIRouter()
log = get_logger(__name__)


class BlendComponentModel(BaseModel):
    voice: str = Field(min_length=1, max_length=32)
    weight: float = Field(ge=MIN_WEIGHT, le=MAX_WEIGHT)


class BlendRequest(BaseModel):
    name: str = Field(min_length=1, max_length=MAX_NAME_CHARS * 2)
    components: list[BlendComponentModel] = Field(
        min_length=MIN_COMPONENTS, max_length=MAX_COMPONENTS
    )

    @field_validator("name")
    @classmethod
    def require_valid_name(cls, value: str) -> str:
        return validate_name(value)

    @model_validator(mode="after")
    def require_valid_components(self) -> "BlendRequest":
        validate_components(self.pairs())
        return self

    def pairs(self) -> list[tuple[str, float]]:
        return [(c.voice, c.weight) for c in self.components]


def _validate_blend_id(blend_id: str) -> None:
    if not is_blend_id(blend_id):
        raise HTTPException(status_code=400, detail="Invalid blend id.")


def _save_failed(action: str) -> HTTPException:
    log.error(
        "voice_blends.save_failed",
        extra={"action": action, "failure_code": "blend_save_failed"},
        exc_info=True,
    )
    return HTTPException(
        status_code=500, detail="Could not save voice blends. Please try again."
    )


@router.get("/voices/blends")
def list_blends() -> dict[str, Any]:
    """List saved voice blends."""
    return {
        "blends": [blend.to_dict() for blend in voice_blends.list()],
        "max_blends": MAX_BLENDS,
    }


@router.get("/voices/blends/{blend_id}")
def get_blend(blend_id: str) -> dict[str, Any]:
    _validate_blend_id(blend_id)
    blend = voice_blends.get(blend_id)
    if blend is None:
        raise HTTPException(status_code=404, detail="Voice blend not found.")
    return blend.to_dict()


@router.post("/voices/blends", status_code=201)
def create_blend(req: BlendRequest) -> dict[str, Any]:
    """Save a new blend of 2 to 4 built-in voices."""
    try:
        blend = voice_blends.create(req.name, req.pairs())
    except BlendLimitError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except OSError as exc:
        raise _save_failed("create") from exc
    log.info("voice_blends.created", extra={"components": len(blend.components)})
    return blend.to_dict()


@router.put("/voices/blends/{blend_id}")
def update_blend(blend_id: str, req: BlendRequest) -> dict[str, Any]:
    """Replace a blend's name and voices. Its id stays the same."""
    _validate_blend_id(blend_id)
    try:
        blend = voice_blends.update(blend_id, req.name, req.pairs())
    except BlendNotFoundError as exc:
        raise HTTPException(status_code=404, detail="Voice blend not found.") from exc
    except OSError as exc:
        raise _save_failed("update") from exc
    log.info("voice_blends.updated", extra={"version": blend.version})
    return blend.to_dict()


@router.delete("/voices/blends/{blend_id}")
def delete_blend(blend_id: str) -> dict[str, str]:
    _validate_blend_id(blend_id)
    try:
        deleted = voice_blends.delete(blend_id)
    except OSError as exc:
        raise _save_failed("delete") from exc
    if not deleted:
        raise HTTPException(status_code=404, detail="Voice blend not found.")
    log.info("voice_blends.deleted")
    return {"status": "deleted", "id": blend_id}
